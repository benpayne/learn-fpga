// acc_regs.v -- CSRs + descriptor queue
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 5 (CPU interface, register map,
// descriptor queue) and specs/004-int8-matmul-accel/data-model.md entities
// 4 (Operation Descriptor) and 5 (Register Interface). Error codes and the
// blocking driver contract are in
// specs/004-int8-matmul-accel/contracts/accelerator-interface.md.
//
// FemtoRV's IO bus is 1-hot addressed, so one 32-bit write cannot carry
// both a register selector and a full 32-bit SDRAM address (research R7).
// This module is therefore reached through TWO one-hot IO bits, allocated
// in FemtoRV/RTL/DEVICES/HardwareConfig_bits.v (T003) as
// IO_ACC_IDX_bit = 10 and IO_ACC_DAT_bit = 11 (reusing the slots
// IO_FGA_CNTL_bit/IO_GPU_bit and IO_FGA_DAT_bit/IO_SYNTH_bit already share,
// since the 20-bit IO space is full):
//   IO_OUT(IO_ACC_IDX, reg_index)   -- select the target register
//   IO_OUT(IO_ACC_DAT, value)       -- write the selected register
//   value = IO_IN(IO_ACC_DAT)       -- read the selected register
// This differs from the GPU/synth convention of packing a small register
// index into upper wdata bits (gpu_femtorv_wrapper.v, fm_synth_registers.v)
// because accelerator registers carry full 32-bit SDRAM addresses, which
// leaves no room for an index in the same word.
//
// Register index map (written via IO_ACC_IDX, read back for debug on
// IO_ACC_DAT except CTRL which is write-only):
//   0 W_Q_BASE   1 W_S_BASE   2 X_SLOT   3 OUT_SLOT
//   4 N          5 D          6 GS       7 MODE
//   8 CTRL (W)   9 STATUS (R) 10 PERF_CYCLES (R) 11 PERF_STALL (R)
// Fields 0-7 stage the next descriptor; writing CTRL.START (bit0) attempts
// to enqueue the currently staged fields as one descriptor. CTRL.ABORT
// (bit1) pulses `op_abort` to acc_top's control FSM.
//
// Holds: the descriptor queue (data-model.md entity 4), CTRL/STATUS,
// PERF_CYCLES/PERF_STALL (data-model.md entity 5 -- "not optional", FR-008).
//
// Validation split (deliberate, see below): `n`/`d` range-vs-configured-
// maxima (ERR_RANGE) and `d*4`-fits-result-slot (ERR_SLOT) need MAX_N/
// MAX_D/RESULT_AWIDTH, which are acc_top/acc_weight_fetch parameters this
// module does not have -- those two codes are the control FSM's job in
// acc_top, exactly as this file's original header said, and arrive here as
// the op_error/op_error_code feedback inputs. ERR_DIM (n%gs==0) and ERR_GS
// (gs a supported power of two) need only `n`/`gs`, which ARE already
// staged here -- and per the team lead's brief ("ERR_DIM deserves
// particular care... the most important validation in the block", after
// runq.c's silent-truncation incident, research R16), this module checks
// both AT ENQUEUE TIME, before a bad descriptor ever reaches the queue or
// acc_top. ERR_FULL (queue has no room) is entirely local. Any check acc_top
// also performs on these two is then simply dead code that never fires --
// harmless defense in depth, not a conflict.
//
// Register indices, CTRL/STATUS bit positions, ERR_* codes, MODE encoding
// and the GS_MIN/GS_MAX bounds are all in the shared acc_bits.vh (created
// after this file originally defined them locally, precisely so acc_top
// cannot drift from the encoding used here).

`include "acc_bits.vh"

module acc_regs #(
    parameter QUEUE_DEPTH   = 16,  // descriptor FIFO depth (DESIGN.md sec 5.3: "a small FIFO (8-16
                                    // entries)" so the CPU can enqueue a whole layer and move on)
    parameter ADDR_WIDTH    = 26,  // w_q_base/w_s_base width, matches muchtoremember_burst.v addressing
    parameter SLOT_WIDTH    = 8,   // x_slot/out_slot index width (data-model.md entity 4)
    parameter DIM_WIDTH     = 16,  // n/d/gs field width (data-model.md entity 4)
    parameter ERR_WIDTH     = 4    // op_error_code width (contracts doc: `ACC_ERR_DIM/`ACC_ERR_GS/`ACC_ERR_RANGE/
                                    // `ACC_ERR_SLOT/`ACC_ERR_FULL)
) (
    input  wire                     clk,
    input  wire                     resetn,       // active-low, synchronous

    // FemtoRV IO bus -- two one-hot chip selects, see header comment above.
    input  wire [31:0]              wdata,        // write data (register index on sel_idx, value on sel_dat)
    output reg  [31:0]              rdata,        // read data, valid when sel_dat & rstrb
    input  wire                     wstrb,        // write strobe
    input  wire                     rstrb,        // read strobe
    input  wire                     sel_idx,      // chip select: IO_ACC_IDX (selects target register)
    input  wire                     sel_dat,      // chip select: IO_ACC_DAT (reads/writes selected register)

    // Popped descriptor, presented to acc_top's control FSM. Held stable
    // while desc_valid is high; acc_top pulses desc_ack to pop the next one.
    output wire                             desc_valid,
    output wire [ADDR_WIDTH-1:0]            desc_w_q_base, // data-model.md entity 4: quantized weight block addr
    output wire [ADDR_WIDTH-1:0]            desc_w_s_base, // scale block address
    output wire [SLOT_WIDTH-1:0]            desc_x_slot,   // activation BRAM slot
    output wire [SLOT_WIDTH-1:0]            desc_out_slot, // result BRAM slot
    output wire [DIM_WIDTH-1:0]             desc_n,        // inner dimension
    output wire [DIM_WIDTH-1:0]             desc_d,        // output row count
    output wire [DIM_WIDTH-1:0]             desc_gs,       // group size (from model header, runtime)
    output wire [1:0]                       desc_mode,     // 0=matmul, 1=att_score, 2=att_sum
    input  wire                             desc_ack,      // pulse: descriptor accepted, pop the queue

    // CTRL.ABORT, level or pulse per acc_top's convention: contract requires
    // "MUST return the accelerator to IDLE from any state within a bounded
    // time, flush the weight FIFO, leave the result buffer undefined but
    // its structure intact."
    output wire                             op_abort,

    // Status/perf feedback from acc_top's control FSM, latched into
    // STATUS/PERF_CYCLES/PERF_STALL for CPU readback.
    input  wire                             op_busy,       // STATUS.BUSY
    input  wire                             op_done,       // pulse -> STATUS.DONE (cleared on read, FR/contract)
    input  wire                             op_error,      // pulse -> STATUS.ERR
    input  wire [ERR_WIDTH-1:0]             op_error_code, // STATUS bits [7:4]
    input  wire [31:0]                      op_perf_cycles,// PERF_CYCLES: cycles op was active
    input  wire [31:0]                      op_perf_stall  // PERF_STALL: of which, cycles stalled on memory
);

    // Register index map, error codes, GS bounds: see acc_bits.vh
    // (ACC_REG_*, ACC_ERR_*, ACC_GS_MIN/MAX). `ACC_ERR_DIM/`ACC_ERR_GS/`ACC_ERR_FULL are
    // assigned locally in this file; `ACC_ERR_RANGE/`ACC_ERR_SLOT arrive via
    // op_error_code from acc_top, using the same shared encoding.

    localparam QPTR_WIDTH = $clog2(QUEUE_DEPTH);
    localparam QCNT_WIDTH = $clog2(QUEUE_DEPTH + 1);

    // ---------------------------------------------------------------------
    // Register-index select latch (IO_ACC_IDX)
    // ---------------------------------------------------------------------
    reg [3:0] reg_index;

    always @(posedge clk) begin
        if (!resetn)
            reg_index <= 4'd0;
        else if (sel_idx && wstrb)
            reg_index <= wdata[3:0];
    end

    // ---------------------------------------------------------------------
    // Staged descriptor fields (IO_ACC_DAT writes while reg_index selects
    // one of 0-7). CTRL.START enqueues whatever is currently staged here.
    // ---------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] stg_w_q_base, stg_w_s_base;
    reg [SLOT_WIDTH-1:0] stg_x_slot,   stg_out_slot;
    reg [DIM_WIDTH-1:0]  stg_n, stg_d, stg_gs;
    reg [1:0]             stg_mode;

    always @(posedge clk) begin
        if (!resetn) begin
            stg_w_q_base <= {ADDR_WIDTH{1'b0}};
            stg_w_s_base <= {ADDR_WIDTH{1'b0}};
            stg_x_slot   <= {SLOT_WIDTH{1'b0}};
            stg_out_slot <= {SLOT_WIDTH{1'b0}};
            stg_n        <= {DIM_WIDTH{1'b0}};
            stg_d        <= {DIM_WIDTH{1'b0}};
            stg_gs       <= {DIM_WIDTH{1'b0}};
            stg_mode     <= 2'd0;
        end else if (sel_dat && wstrb) begin
            case (reg_index)
                `ACC_REG_W_Q_BASE: stg_w_q_base <= wdata[ADDR_WIDTH-1:0];
                `ACC_REG_W_S_BASE: stg_w_s_base <= wdata[ADDR_WIDTH-1:0];
                `ACC_REG_X_SLOT:   stg_x_slot   <= wdata[SLOT_WIDTH-1:0];
                `ACC_REG_OUT_SLOT: stg_out_slot <= wdata[SLOT_WIDTH-1:0];
                `ACC_REG_N:        stg_n        <= wdata[DIM_WIDTH-1:0];
                `ACC_REG_D:        stg_d        <= wdata[DIM_WIDTH-1:0];
                `ACC_REG_GS:       stg_gs       <= wdata[DIM_WIDTH-1:0];
                `ACC_REG_MODE:     stg_mode     <= wdata[1:0];
                default: ; // `ACC_REG_CTRL and read-only regs handled elsewhere
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Enqueue-time validation (combinational, evaluated against the
    // currently-staged fields whenever CTRL.START is written).
    // ---------------------------------------------------------------------
    wire start_req = sel_dat && wstrb && (reg_index == `ACC_REG_CTRL) && wdata[0];
    wire abort_req = sel_dat && wstrb && (reg_index == `ACC_REG_CTRL) && wdata[1];

    wire is_pow2_gs = (stg_gs != {DIM_WIDTH{1'b0}}) && ((stg_gs & (stg_gs - 1'b1)) == {DIM_WIDTH{1'b0}});
    wire gs_bad      = !is_pow2_gs || (stg_gs < `ACC_GS_MIN) || (stg_gs > `ACC_GS_MAX);
    // Only meaningful once gs is known to be a valid power of two -- then
    // n % gs == 0 reduces to a cheap bitmask test instead of a divider.
    wire dim_bad      = !gs_bad && ((stg_n & (stg_gs - 1'b1)) != {DIM_WIDTH{1'b0}});

    // ---------------------------------------------------------------------
    // Descriptor queue -- QUEUE_DEPTH-entry circular buffer of register
    // arrays (Constitution "Portability and inference": behavioural, let
    // yosys choose BRAM vs. flip-flops for this depth).
    // ---------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] fifo_w_q_base [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] fifo_w_s_base [0:QUEUE_DEPTH-1];
    reg [SLOT_WIDTH-1:0] fifo_x_slot   [0:QUEUE_DEPTH-1];
    reg [SLOT_WIDTH-1:0] fifo_out_slot [0:QUEUE_DEPTH-1];
    reg [DIM_WIDTH-1:0]  fifo_n        [0:QUEUE_DEPTH-1];
    reg [DIM_WIDTH-1:0]  fifo_d        [0:QUEUE_DEPTH-1];
    reg [DIM_WIDTH-1:0]  fifo_gs       [0:QUEUE_DEPTH-1];
    reg [1:0]            fifo_mode     [0:QUEUE_DEPTH-1];

    reg [QPTR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [QCNT_WIDTH-1:0] queue_count;

    wire queue_full = (queue_count == QUEUE_DEPTH[QCNT_WIDTH-1:0]);
    wire queue_empty = (queue_count == {QCNT_WIDTH{1'b0}});

    // Reject reasons, mutually exclusive and priority-ordered: a bad group
    // size is reported as `ACC_ERR_GS even if the (meaningless, since gs is
    // invalid) dimension check would also fail; `ACC_ERR_FULL only applies once
    // the descriptor itself is otherwise valid, so back-pressure is never
    // reported for a descriptor that was going to be rejected anyway.
    wire reject_gs   = start_req && gs_bad;
    wire reject_dim  = start_req && !gs_bad && dim_bad;
    wire reject_full = start_req && !gs_bad && !dim_bad && queue_full;
    wire push_ok      = start_req && !gs_bad && !dim_bad && !queue_full;
    wire pop_ok        = desc_ack && !queue_empty;

    always @(posedge clk) begin
        if (!resetn) begin
            wr_ptr      <= {QPTR_WIDTH{1'b0}};
            rd_ptr      <= {QPTR_WIDTH{1'b0}};
            queue_count <= {QCNT_WIDTH{1'b0}};
        end else begin
            queue_count <= queue_count + push_ok - pop_ok;

            if (push_ok) begin
                fifo_w_q_base[wr_ptr] <= stg_w_q_base;
                fifo_w_s_base[wr_ptr] <= stg_w_s_base;
                fifo_x_slot[wr_ptr]   <= stg_x_slot;
                fifo_out_slot[wr_ptr] <= stg_out_slot;
                fifo_n[wr_ptr]        <= stg_n;
                fifo_d[wr_ptr]        <= stg_d;
                fifo_gs[wr_ptr]       <= stg_gs;
                fifo_mode[wr_ptr]     <= stg_mode;
                wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop_ok)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign desc_valid    = !queue_empty;
    assign desc_w_q_base = fifo_w_q_base[rd_ptr];
    assign desc_w_s_base = fifo_w_s_base[rd_ptr];
    assign desc_x_slot   = fifo_x_slot[rd_ptr];
    assign desc_out_slot = fifo_out_slot[rd_ptr];
    assign desc_n        = fifo_n[rd_ptr];
    assign desc_d        = fifo_d[rd_ptr];
    assign desc_gs       = fifo_gs[rd_ptr];
    assign desc_mode     = fifo_mode[rd_ptr];

    // ---------------------------------------------------------------------
    // CTRL.ABORT -> one-cycle pulse to acc_top
    // ---------------------------------------------------------------------
    reg op_abort_r;
    always @(posedge clk) begin
        if (!resetn)
            op_abort_r <= 1'b0;
        else
            op_abort_r <= abort_req;
    end
    assign op_abort = op_abort_r;

    // ---------------------------------------------------------------------
    // STATUS: BUSY / DONE / ERR / error code / queue depth
    // ---------------------------------------------------------------------
    reg                   done_latched;
    reg                   err_latched;
    reg [ERR_WIDTH-1:0]   err_code_latched;

    wire status_read = sel_dat && rstrb && (reg_index == `ACC_REG_STATUS);

    always @(posedge clk) begin
        if (!resetn) begin
            done_latched     <= 1'b0;
            err_latched      <= 1'b0;
            err_code_latched <= `ACC_ERR_NONE;
        end else begin
            // Error/done latch. Priority: acc_top's own runtime feedback
            // first (covers `ACC_ERR_RANGE/`ACC_ERR_SLOT and successful completion),
            // then the local enqueue-time rejects, then a freshly-accepted
            // descriptor clears any stale error. Reading STATUS clears
            // DONE only (data-model.md entity 5 "Rules": "MUST NOT have
            // side effects other than the documented DONE clear") -- ERR is
            // untouched by a read, on purpose.
            if (op_error) begin
                err_latched      <= 1'b1;
                err_code_latched <= op_error_code;
            end else if (reject_gs) begin
                err_latched      <= 1'b1;
                err_code_latched <= `ACC_ERR_GS;
            end else if (reject_dim) begin
                err_latched      <= 1'b1;
                err_code_latched <= `ACC_ERR_DIM;
            end else if (reject_full) begin
                err_latched      <= 1'b1;
                err_code_latched <= `ACC_ERR_FULL;
            end else if (push_ok) begin
                err_latched      <= 1'b0;
                err_code_latched <= `ACC_ERR_NONE;
            end

            if (op_done)
                done_latched <= 1'b1;
            else if (status_read)
                done_latched <= 1'b0;
        end
    end

    // Bit layout (data-model.md entity 5 / DESIGN.md sec 5.2):
    //   0 BUSY, 1 DONE, 2 ERR, 3 reserved, 7:4 error code, 15:8 queue depth,
    //   31:16 reserved.
    wire [7:0] queue_depth_field = {{(8-QCNT_WIDTH){1'b0}}, queue_count};
    wire [31:0] status_word = {16'b0, queue_depth_field, err_code_latched,
                                1'b0, err_latched, done_latched, op_busy};

    // ---------------------------------------------------------------------
    // Read mux (combinational; same-cycle read, matching this codebase's
    // other simple memory-mapped IO peripherals -- e.g. InterruptController,
    // PS2Decoder).
    // ---------------------------------------------------------------------
    always @(*) begin
        rdata = 32'b0;
        if (sel_dat) begin
            case (reg_index)
                `ACC_REG_W_Q_BASE:    rdata = {{(32-ADDR_WIDTH){1'b0}}, stg_w_q_base};
                `ACC_REG_W_S_BASE:    rdata = {{(32-ADDR_WIDTH){1'b0}}, stg_w_s_base};
                `ACC_REG_X_SLOT:      rdata = {{(32-SLOT_WIDTH){1'b0}}, stg_x_slot};
                `ACC_REG_OUT_SLOT:    rdata = {{(32-SLOT_WIDTH){1'b0}}, stg_out_slot};
                `ACC_REG_N:           rdata = {{(32-DIM_WIDTH){1'b0}}, stg_n};
                `ACC_REG_D:           rdata = {{(32-DIM_WIDTH){1'b0}}, stg_d};
                `ACC_REG_GS:          rdata = {{(32-DIM_WIDTH){1'b0}}, stg_gs};
                `ACC_REG_MODE:        rdata = {30'b0, stg_mode};
                `ACC_REG_STATUS:      rdata = status_word;
                `ACC_REG_PERF_CYC: rdata = op_perf_cycles;
                `ACC_REG_PERF_STALL:  rdata = op_perf_stall;
                default:         rdata = 32'b0;
            endcase
        end
    end

endmodule
