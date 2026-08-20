// acc_top.v -- assembles acc_regs, acc_weight_fetch and acc_mac into the
// complete int8 matmul accelerator, and exposes its three external
// interfaces: the FemtoRV IO bus, the SDRAM burst port, and the CPU-facing
// activation/result BRAMs.
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 3.2 (block diagram) and section
// 9a ("Reusing the existing video/SDRAM path", "What is NOT there: a write
// path"). Instantiated at the site `video_fetch_engine` occupies in the LLM
// minimal profile (DESIGN.md sec 9a: "there is no GPU to replace -- it is
// already gone from this profile"; tasks.md T048).
//
// Owns:
//  - the control FSM: pops descriptors from acc_regs, validates them
//    (FR-009: n%gs==0, gs a supported power of two, n/d within configured
//    maxima, d*4 fits the result slot -- data-model.md entity 4
//    "Validation rules"), drives acc_weight_fetch and acc_mac, and reports
//    completion/errors/perf counters back to acc_regs. n%gs and gs-power-
//    of-two are ALREADY rejected by acc_regs at enqueue time (see that
//    file's header comment); this FSM checks the two codes acc_regs
//    structurally cannot -- ERR_RANGE (n/d vs MAX_N/MAX_D) and ERR_SLOT
//    (result AND activation slot capacity, and slot-index range);
//  - the activation BRAM (quantized activation vector, data-model.md
//    entity 3, written by the CPU before each operation) and the result
//    BRAM (data-model.md entity 6, mapped at 0x100000 in this profile per
//    research R8, written only by this module, read by ordinary CPU loads);
//  - the weight FIFO and the per-operation scale BRAM that sit between
//    acc_weight_fetch and acc_mac (block diagram sec 3.2: both are drawn
//    outside acc_weight_fetch, which only exposes wdata/wen/room-or-full
//    handshakes to them -- this is where they actually live);
//  - address generation for the three modes (MODE_MATMUL / MODE_ATT_SCORE /
//    MODE_ATT_SUM, contracts/accelerator-interface.md) -- same datapath,
//    different address pattern per operand (DESIGN.md section 7).
//
// SCOPE NOTE: only MODE_MATMUL is implemented in this pass. Modes 1/2
// (attention) are T064's job. desc_mode is accepted but not currently
// validated or branched on -- every popped descriptor runs the matmul
// address pattern regardless of its mode field. There is no ERR_MODE code
// in acc_bits.vh to reject a non-matmul descriptor with, and inventing one
// unilaterally would let this module's encoding drift from acc_regs' the
// same way the original ERR_* duplication did. Flagged to the team lead
// rather than worked around silently -- see the T034 report.
//
// Does NOT own: SDRAM arbitration priority (that is a 3-line reorder plus a
// starvation counter inside muchtoremember_burst.v itself, DESIGN.md sec
// 9a/6.2, wired at integration time in femtosoc.v, not here).
//
// -----------------------------------------------------------------------
// Pipeline design: one uniform 1-cycle "address phase / data phase" stage
// -----------------------------------------------------------------------
// acc_mac requires w_scale/x_scale valid by the cycle group_done pulses,
// and group_start/row_start to coincide with in_valid on a group/row's
// first element chunk. The smallest legal group (gs == LANES, ACC_GS_MIN=4
// with the default LANES=4) leaves ZERO slack between "group starts" and
// "group completes" -- a combinational read would work but forces large
// distributed-RAM arrays (this project already learned that lesson on the
// SDRAM cache: see cache.v's history, ~256 entries blew timing at 25 MHz),
// and a naively-added synchronous read would arrive one cycle too late for
// that single-cycle-group case.
//
// The fix used throughout this module: every one of the four memories
// (weight FIFO, activation xq, activation xs/scale, weight scale) is read
// SYNCHRONOUSLY (yosys-inferrable BRAM, 1-cycle latency), all four
// addressed from the SAME combinational "address phase" decision each
// cycle, and all four outputs -- together with registered copies of
// in_valid/group_start/row_start computed from that same decision -- land
// on acc_mac's inputs on the SAME following cycle ("data phase"). Because
// the scale addresses only change on a group's LAST address-phase word
// (not its first), the value in flight during a group's own first cycle is
// still last group's address for one more cycle, which is exactly the
// group that's completing -- see the walk-through in the design doc
// comment block above the `group_count_q`/`act_group_idx_q` update below
// for the cycle-by-cycle reasoning. This keeps every memory here a genuine
// synchronous-read BRAM with no combinational-read timing risk, at the
// cost of a fixed, well-understood 1-cycle pipeline stage.
//
`include "acc_bits.vh"

module acc_top #(
    parameter LANES         = 4,    // int8 MAC lanes, passed to acc_mac (DESIGN.md sec 3.4/4.2).
                                     // ASSUMPTION: LANES == 32/ELEM_WIDTH (one 32-bit FIFO/BRAM word
                                     // supplies exactly one MAC lane-chunk) and LANES is a power of
                                     // two -- both true for the default (LANES=4, ELEM_WIDTH=8).
                                     // ALSO ASSUMES ACC_GS_MIN (acc_bits.vh) >= LANES, so every
                                     // legal group is at least one full lane-chunk wide; holds for
                                     // ACC_GS_MIN=4 against the default LANES=4.
    parameter ELEM_WIDTH    = 8,    // element width, passed to acc_mac (FR-011: parameterised for a
                                     // 16-bit fallback)
    parameter BURST_LEN     = 128,  // SDRAM burst length in words, passed to acc_weight_fetch. NOT
                                     // hardcoded despite the concrete default: a burst-efficiency
                                     // sweep found 64 sustains only 85.7% with the CPU idle (below
                                     // SC-006's 90% floor) while 128 measured 91.4%, so 128 is the
                                     // expected value pending that sweep's final confirmation --
                                     // override freely, everything below scales off this parameter.
    parameter FIFO_DEPTH    = 4*BURST_LEN, // weight FIFO depth, EXPRESSED relative to BURST_LEN
                                     // (not an independent literal) so overriding BURST_LEN alone
                                     // can't silently shrink the burst-to-depth margin -- the same
                                     // relationship acc_weight_fetch.v uses for its own default.
                                     // acc_weight_fetch itself no longer needs FIFO_DEPTH for
                                     // safety (it gates on fifo_room_for_burst, computed here), but
                                     // the 4x margin is still the right default for this module's
                                     // OWN FIFO storage sizing.
    parameter QUEUE_DEPTH   = 16,   // descriptor queue depth, passed to acc_regs
    parameter ADDR_WIDTH    = 26,   // SDRAM word address width throughout
    parameter MAX_N         = 4096, // largest inner dimension this module's generic ERR_RANGE check
                                     // allows. NOTE: this is independent of the physical activation/
                                     // result slot capacity below (ACT_XQ_WORDS/RESULT_SLOT_WORDS) --
                                     // a descriptor can pass this generic check and still be
                                     // rejected with ERR_SLOT if it would overflow the BRAM this
                                     // module actually built. Both checks run; neither alone is
                                     // sufficient at every possible parameterisation.
    parameter MAX_D         = 4096, // largest supported output row count (see MAX_N note)
    parameter ACT_AWIDTH    = 12,   // activation BRAM address width (slot index + element offset)
    parameter RESULT_AWIDTH = 12,   // result BRAM address width (slot index + element offset);
                                     // RESULT_AWIDTH words MUST cover at least max_d fp32 values
                                     // per slot (data-model.md entity 6: "2 KB covers the d=512
                                     // classifier")
    parameter NUM_SLOTS     = 8,    // NEW (not in the T001 skeleton's parameter list, added here):
                                     // number of independent activation/result slots actually
                                     // implemented. x_slot/out_slot are 8-bit descriptor fields
                                     // (256 possible values) but there is no way to fit 256 slots
                                     // each sized for MAX_N/MAX_D inside a 12-bit address space --
                                     // that tension is inherent to the T001 defaults, not
                                     // introduced here. NUM_SLOTS MUST evenly divide both
                                     // 2**ACT_AWIDTH and 2**RESULT_AWIDTH. Default 8 makes each
                                     // result slot exactly 512 words (2 KB), matching the "2 KB
                                     // covers d=512" example in the RESULT_AWIDTH comment above --
                                     // that match is what validates this choice, not a coincidence.
    parameter ACT_XS_WORDS  = 32     // NEW: words reserved at the END of each activation slot for
                                     // the fp32 per-group activation scales (xs, data-model.md
                                     // entity 3). The remainder of the slot (ACT_SLOT_WORDS -
                                     // ACT_XS_WORDS) holds the packed int8 xq stream, 4 elements/
                                     // word. 32 words covers up to 32 groups per operation (n/gs
                                     // <= 32), comfortably above this model's actual n/gs (<=3 at
                                     // n<=192, gs=64) with headroom for larger models later.
) (
    input  wire                     clk,
    input  wire                     resetn,        // active-low, synchronous. femtosoc.v's IO bus
                                                     // uses an active-high `reset` (see
                                                     // gpu_femtorv_wrapper.v) -- integration (T048)
                                                     // is responsible for inverting it at this
                                                     // boundary.

    // FemtoRV IO bus -- two one-hot chip selects into acc_regs
    // (HardwareConfig_bits.v IO_ACC_IDX_bit / IO_ACC_DAT_bit, allocated in T003)
    input  wire [31:0]              io_wdata,
    output wire [31:0]              io_rdata,
    input  wire                     io_wstrb,
    input  wire                     io_rstrb,
    input  wire                     io_sel_idx,
    input  wire                     io_sel_dat,

    // Result BRAM -- CPU-facing read-only memory-mapped port, address-decoded
    // in femtosoc.v (data-model.md entity 6: "mapped at 0x100000", ordinary
    // CPU loads, not IO reads). Written only internally by this module.
    // res_rdata is a REGISTERED (synchronous BRAM) read: valid one cycle
    // after res_sel && res_rstrb, not combinational -- femtosoc.v's memory
    // bus wait-state handling for this region (T048) must account for that,
    // the same way it already does for BRAM/SDRAM.
    input  wire                     res_sel,       // chip select from femtosoc.v's address decode
    input  wire                     res_rstrb,      // read strobe
    input  wire [RESULT_AWIDTH-1:0] res_addr,       // word address within the result BRAM
    output reg  [31:0]              res_rdata,

    // Activation BRAM -- CPU-facing write port. The CPU quantizes and writes
    // the activation vector here before issuing an operation (data-model.md
    // entity 3: "Produced by the CPU before each operation"). Also
    // address-decoded in femtosoc.v. Layout convention (this module's own
    // choice -- see ACT_XS_WORDS above and the act_mem section below):
    // within slot S (base = S*ACT_SLOT_WORDS), words [0 .. n/LANES-1] are
    // packed int8 xq (LANES elements/word, same packing as the weight q
    // block), and words [ACT_SLOT_WORDS-ACT_XS_WORDS .. ACT_SLOT_WORDS-
    // ACT_XS_WORDS+n/gs-1] are fp32 xs (1 scale/word). Firmware writing an
    // activation slot MUST follow this split.
    input  wire                     act_sel,
    input  wire [3:0]               act_wmask,
    input  wire [ACT_AWIDTH-1:0]    act_addr,
    input  wire [31:0]              act_wdata,

    // SDRAM burst read port -- FemtoRV/RTL/SDRAM/muchtoremember_burst.v,
    // passed through to the internal acc_weight_fetch instance unchanged.
    output wire                     burst_rd,
    output wire [ADDR_WIDTH-1:0]    burst_addr,
    output wire [8:0]               burst_len,
    input  wire [31:0]              burst_dout,
    input  wire                     burst_valid,
    input  wire                     burst_done,
    input  wire                     burst_busy
);

    localparam SCALE_AWIDTH = 12; // MUST match acc_weight_fetch's own SCALE_AWIDTH default -- see
                                   // the instantiation below, which passes it explicitly so the two
                                   // can't silently drift apart.

    // =======================================================================
    // Slot geometry (see NUM_SLOTS/ACT_XS_WORDS parameter comments above)
    // =======================================================================
    localparam SLOT_IDX_BITS     = $clog2(NUM_SLOTS);
    localparam RESULT_SLOT_WORDS = (1 << RESULT_AWIDTH) / NUM_SLOTS;
    localparam ACT_SLOT_WORDS    = (1 << ACT_AWIDTH) / NUM_SLOTS;
    localparam ACT_XQ_WORDS      = ACT_SLOT_WORDS - ACT_XS_WORDS;

    localparam LANES_SHIFT = $clog2(LANES); // elaboration-time constant; see the LANES parameter
                                             // comment for the power-of-two/32-bit-word assumption.

    // =======================================================================
    // log2 of a runtime power-of-two value. Duplicated from
    // acc_weight_fetch.v deliberately: it is a small pure function, and
    // sharing it would mean putting function definitions (not just
    // constants) in acc_bits.vh, which is scoped to encoding constants both
    // modules must agree on -- this has no cross-module agreement to break.
    // =======================================================================
    function [4:0] log2_of_pow2;
        input [15:0] value;
        integer i;
        begin
            log2_of_pow2 = 5'd0;
            for (i = 0; i < 16; i = i + 1)
                if (value[i]) log2_of_pow2 = i[4:0];
        end
    endfunction

    // =======================================================================
    // acc_regs -- CSRs + descriptor queue
    // =======================================================================
    wire                       desc_valid;
    wire [ADDR_WIDTH-1:0]      desc_w_q_base, desc_w_s_base;
    wire [7:0]                 desc_x_slot, desc_out_slot;
    wire [15:0]                desc_n, desc_d, desc_gs;
    wire [1:0]                 desc_mode;
    reg                        desc_ack;

    wire                       regs_op_abort;

    reg                        op_busy_r;
    reg                        op_done_r;
    reg                        op_error_r;
    reg  [3:0]                 op_error_code_r;
    reg  [31:0]                op_perf_cycles_r;
    reg  [31:0]                op_perf_stall_r;

    acc_regs #(
        .QUEUE_DEPTH (QUEUE_DEPTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .SLOT_WIDTH  (8),
        .DIM_WIDTH   (16),
        .ERR_WIDTH   (4)
    ) u_regs (
        .clk            (clk),
        .resetn         (resetn),
        .wdata          (io_wdata),
        .rdata          (io_rdata),
        .wstrb          (io_wstrb),
        .rstrb          (io_rstrb),
        .sel_idx        (io_sel_idx),
        .sel_dat        (io_sel_dat),
        .desc_valid     (desc_valid),
        .desc_w_q_base  (desc_w_q_base),
        .desc_w_s_base  (desc_w_s_base),
        .desc_x_slot    (desc_x_slot),
        .desc_out_slot  (desc_out_slot),
        .desc_n         (desc_n),
        .desc_d         (desc_d),
        .desc_gs        (desc_gs),
        .desc_mode      (desc_mode),
        .desc_ack       (desc_ack),
        .op_abort       (regs_op_abort),
        .op_busy        (op_busy_r),
        .op_done        (op_done_r),
        .op_error       (op_error_r),
        .op_error_code  (op_error_code_r),
        .op_perf_cycles (op_perf_cycles_r),
        .op_perf_stall  (op_perf_stall_r)
    );

    // =======================================================================
    // acc_weight_fetch -- burst-read orchestrator
    // =======================================================================
    reg                       wf_start;
    reg                       wf_abort;
    wire                      wf_busy;
    wire                      wf_done;

    wire [31:0]                fifo_wdata_in;
    wire                        fifo_wen_in;
    reg                         fifo_room_for_burst;

    wire [31:0]                 scale_wdata_in;
    wire                        scale_wen_in;
    wire [SCALE_AWIDTH-1:0]     scale_waddr_in;

    reg [ADDR_WIDTH-1:0]        op_w_q_base, op_w_s_base;
    reg [15:0]                  op_n, op_d, op_gs;

    acc_weight_fetch #(
        .BURST_LEN    (BURST_LEN),
        .FIFO_DEPTH   (FIFO_DEPTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .MAX_N        (MAX_N),
        .MAX_D        (MAX_D),
        .SCALE_AWIDTH (SCALE_AWIDTH)
    ) u_fetch (
        .clk                 (clk),
        .resetn              (resetn),
        .w_q_base            (op_w_q_base),
        .w_s_base            (op_w_s_base),
        .n                   (op_n),
        .d                   (op_d),
        .gs                  (op_gs),
        .start               (wf_start),
        .abort               (wf_abort),
        .busy                (wf_busy),
        .done                (wf_done),
        .burst_rd            (burst_rd),
        .burst_addr          (burst_addr),
        .burst_len           (burst_len),
        .burst_dout          (burst_dout),
        .burst_valid         (burst_valid),
        .burst_done          (burst_done),
        .burst_busy          (burst_busy),
        .fifo_wdata          (fifo_wdata_in),
        .fifo_wen            (fifo_wen_in),
        .fifo_room_for_burst (fifo_room_for_burst),
        .scale_wdata         (scale_wdata_in),
        .scale_wen           (scale_wen_in),
        .scale_waddr         (scale_waddr_in)
    );

    // =======================================================================
    // Weight FIFO -- owned here (acc_weight_fetch only sees the handshake).
    // Synchronous read (see the pipeline design note at the top of this
    // file): fed by acc_weight_fetch's writes, drained one word per
    // `issue_read_c` cycle into acc_mac's w_data.
    // =======================================================================
    localparam FIFO_PTR_WIDTH = $clog2(FIFO_DEPTH);
    localparam FIFO_CNT_WIDTH = $clog2(FIFO_DEPTH + 1);

    reg [31:0] weight_fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_WIDTH-1:0] fifo_wr_ptr, fifo_rd_ptr;
    reg [FIFO_CNT_WIDTH-1:0] fifo_count;

    wire fifo_empty = (fifo_count == {FIFO_CNT_WIDTH{1'b0}});
    // "Room for BURST_LEN more entries" -- this is what makes overflow
    // structurally impossible regardless of when a burst happens to land
    // (T032/T033 finding: a single `full` bit only proves room for one more
    // word, not a whole atomic burst).
    wire fifo_has_room_for_burst = (fifo_count <= (FIFO_DEPTH - BURST_LEN));

    always @(posedge clk) begin
        if (!resetn) begin
            fifo_wr_ptr         <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_rd_ptr         <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_count          <= {FIFO_CNT_WIDTH{1'b0}};
            fifo_room_for_burst <= 1'b0;
        end else begin
            fifo_room_for_burst <= fifo_has_room_for_burst;

            if (fifo_wen_in) begin
                weight_fifo_mem[fifo_wr_ptr] <= fifo_wdata_in;
                fifo_wr_ptr <= (fifo_wr_ptr == FIFO_DEPTH-1) ? {FIFO_PTR_WIDTH{1'b0}} : fifo_wr_ptr + 1'b1;
            end

            if (issue_read_c) begin
                fifo_rd_ptr <= (fifo_rd_ptr == FIFO_DEPTH-1) ? {FIFO_PTR_WIDTH{1'b0}} : fifo_rd_ptr + 1'b1;
            end

            // Simultaneous push+pop handled as a single signed delta, same
            // technique as acc_regs.v's descriptor queue_count.
            fifo_count <= fifo_count + fifo_wen_in - issue_read_c;

            // Abort: acc_weight_fetch guarantees no more fifo_wen pulses
            // once it has seen `abort` (its S_ABORT_WAIT state gates
            // fifo_wen off structurally), so it is safe to drop everything
            // already buffered immediately -- this IS the "acc_top owns
            // FIFO flush on abort" requirement.
            if (op_abort_now) begin
                fifo_wr_ptr <= {FIFO_PTR_WIDTH{1'b0}};
                fifo_rd_ptr <= {FIFO_PTR_WIDTH{1'b0}};
                fifo_count  <= {FIFO_CNT_WIDTH{1'b0}};
            end
        end
    end

    reg [31:0] w_data_q; // registered FIFO read output -> acc_mac.w_data

    always @(posedge clk) begin
        if (issue_read_c) w_data_q <= weight_fifo_mem[fifo_rd_ptr];
    end

    // =======================================================================
    // Scale BRAM (weight side) -- prefetched by acc_weight_fetch, read here
    // once per group. Sized to match acc_weight_fetch's SCALE_AWIDTH
    // exactly (the localparam above), not independently.
    // =======================================================================
    reg [31:0] weight_scale_mem [0:(1<<SCALE_AWIDTH)-1];

    always @(posedge clk) begin
        if (scale_wen_in) weight_scale_mem[scale_waddr_in] <= scale_wdata_in;
    end

    reg [SCALE_AWIDTH-1:0] group_count_q; // monotonic group index for the WHOLE operation (weight
                                           // scale block is d*n/gs entries total, row-major, never
                                           // repeats -- unlike the activation scale below)
    reg [31:0] w_scale_q;

    always @(posedge clk) begin
        if (issue_read_c) w_scale_q <= weight_scale_mem[group_count_q];
    end

    // =======================================================================
    // Activation BRAM -- one CPU write port (byte-enabled), two internal
    // synchronous read ports (xq stream, xs scale). Verilog behavioural
    // arrays support multiple independent read blocks on one declared
    // array; yosys is expected to replicate the underlying BRAM as needed
    // (standard for 1-write/N-read memories on ECP5's true-dual-port
    // primitive, which is natively 1-read+1-write or 2-read per physical
    // block).
    // =======================================================================
    reg [31:0] act_mem [0:(1<<ACT_AWIDTH)-1];

    always @(posedge clk) begin
        if (act_sel) begin
            if (act_wmask[0]) act_mem[act_addr][7:0]   <= act_wdata[7:0];
            if (act_wmask[1]) act_mem[act_addr][15:8]  <= act_wdata[15:8];
            if (act_wmask[2]) act_mem[act_addr][23:16] <= act_wdata[23:16];
            if (act_wmask[3]) act_mem[act_addr][31:24] <= act_wdata[31:24];
        end
    end

    reg [ACT_AWIDTH-1:0] act_slot_xq_base_q, act_slot_xs_base_q; // latched at op accept
    reg [15:0]            word_in_row_q;   // also used directly as the xq offset within the slot
    reg [ACT_AWIDTH-1:0]  act_group_idx_q; // xs offset within the slot, WRAPS per row (x is reused
                                            // across all d rows, unlike the weight scale above)

    wire [ACT_AWIDTH-1:0] act_xq_addr_c = act_slot_xq_base_q + word_in_row_q[ACT_AWIDTH-1:0];
    wire [ACT_AWIDTH-1:0] act_xs_addr_c = act_slot_xs_base_q + act_group_idx_q;

    reg [31:0] x_data_q, x_scale_q;

    always @(posedge clk) begin
        if (issue_read_c) begin
            x_data_q  <= act_mem[act_xq_addr_c];
            x_scale_q <= act_mem[act_xs_addr_c];
        end
    end

    // =======================================================================
    // Result BRAM -- one internal write port (row commits from acc_mac),
    // one CPU-facing synchronous read port.
    // =======================================================================
    reg [31:0] result_mem [0:(1<<RESULT_AWIDTH)-1];

    always @(posedge clk) begin
        if (res_sel && res_rstrb) res_rdata <= result_mem[res_addr];
    end

    // =======================================================================
    // acc_mac
    // =======================================================================
    wire                        mac_group_done;
    wire signed [31:0]          mac_group_acc; // unused here (perf/debug only, not wired further)
    wire                        mac_row_valid;
    wire [31:0]                 mac_row_result;

    reg                         in_valid_q, group_start_q, row_start_q;

    acc_mac #(
        .LANES      (LANES),
        .ELEM_WIDTH (ELEM_WIDTH),
        .ACC_WIDTH  (32),
        .GS_WIDTH   (16)
    ) u_mac (
        .clk         (clk),
        .resetn      (resetn),
        .in_valid    (in_valid_q),
        .w_data      (w_data_q),
        .x_data      (x_data_q),
        .gs          (op_gs),
        .group_start (group_start_q),
        .row_start   (row_start_q),
        .w_scale     (w_scale_q),
        .x_scale     (x_scale_q),
        .group_done  (mac_group_done),
        .group_acc   (mac_group_acc),
        .row_valid   (mac_row_valid),
        .row_result  (mac_row_result)
    );

    // =======================================================================
    // Control FSM
    // =======================================================================
    localparam S_IDLE     = 2'd0;
    localparam S_RUNNING  = 2'd1;
    localparam S_ABORTING = 2'd2;

    reg [1:0] state;

    reg [15:0] words_per_group_q, words_per_row_q, groups_per_row_q;
    reg [31:0] q_words_total_q, words_fed_q;
    reg [RESULT_AWIDTH-1:0] out_slot_base_q; // sized to RESULT_AWIDTH, not ACT_AWIDTH -- this
                                              // indexes result_mem. The two parameters default
                                              // equal (12/12) but are independent; don't let a
                                              // coincidence stand in for the right width.
    reg [15:0] out_row_idx_q;
    reg [15:0] commit_groups_in_row_q;

    // ---- Address-phase decision (combinational) --------------------------
    wire running       = (state == S_RUNNING);
    wire issue_read_c  = running && !fifo_empty && (words_fed_q < q_words_total_q);
    // is_group_first / is_row_first: whether THIS address-phase cycle is
    // reading the first word of a group / row, from the word-in-group /
    // word-in-row counters (declared below; Verilog module scope makes the
    // forward reference here fine).
    wire is_word_group_first_c = (word_in_group_q == 16'd0);
    wire is_word_row_first_c   = (word_in_row_q   == 16'd0);
    wire is_group_last_c       = issue_read_c && (word_in_group_q == words_per_group_q - 16'd1);
    wire is_row_last_word_c    = (word_in_row_q == words_per_row_q - 16'd1);

    reg [15:0] word_in_group_q; // word_in_row_q is declared earlier, next to the activation BRAM
                                 // read logic that also consumes it directly as an address offset

    // ---- Descriptor accept-time validation (combinational) ---------------
    wire [4:0]  accept_gs_shift_c  = log2_of_pow2(desc_gs);
    wire [15:0] accept_groups_per_row_c = desc_n >> accept_gs_shift_c;
    wire [15:0] accept_words_per_row_c  = desc_n >> LANES_SHIFT[4:0];
    wire [15:0] accept_words_per_group_c = desc_gs >> LANES_SHIFT[4:0];
    wire [31:0] accept_scale_total_c = {16'b0, accept_groups_per_row_c} * {16'b0, desc_d};

    wire accept_range_bad = (desc_n > MAX_N[15:0]) || (desc_d > MAX_D[15:0]) ||
                             (accept_scale_total_c > (32'd1 << SCALE_AWIDTH));
    wire accept_slot_bad  = (desc_out_slot >= NUM_SLOTS[7:0]) ||
                             (desc_x_slot   >= NUM_SLOTS[7:0]) ||
                             (desc_d > RESULT_SLOT_WORDS[15:0]) ||
                             (accept_words_per_row_c > ACT_XQ_WORDS[15:0]) ||
                             (accept_groups_per_row_c > ACT_XS_WORDS[15:0]);

    wire op_abort_now = (state == S_RUNNING) && regs_op_abort;

    always @(posedge clk) begin
        if (!resetn) begin
            state                   <= S_IDLE;
            desc_ack                <= 1'b0;
            wf_start                <= 1'b0;
            wf_abort                <= 1'b0;
            op_busy_r               <= 1'b0;
            op_done_r               <= 1'b0;
            op_error_r              <= 1'b0;
            op_error_code_r         <= `ACC_ERR_NONE;
            op_perf_cycles_r        <= 32'd0;
            op_perf_stall_r         <= 32'd0;
            op_w_q_base <= {ADDR_WIDTH{1'b0}};
            op_w_s_base <= {ADDR_WIDTH{1'b0}};
            op_n <= 16'd0; op_d <= 16'd0; op_gs <= 16'd0;
            words_per_group_q <= 16'd0;
            words_per_row_q   <= 16'd0;
            groups_per_row_q  <= 16'd0;
            q_words_total_q   <= 32'd0;
            words_fed_q       <= 32'd0;
            word_in_group_q   <= 16'd0;
            word_in_row_q     <= 16'd0;
            group_count_q     <= {SCALE_AWIDTH{1'b0}};
            act_group_idx_q   <= {ACT_AWIDTH{1'b0}};
            act_slot_xq_base_q <= {ACT_AWIDTH{1'b0}};
            act_slot_xs_base_q <= {ACT_AWIDTH{1'b0}};
            out_slot_base_q   <= {RESULT_AWIDTH{1'b0}};
            out_row_idx_q     <= 16'd0;
            commit_groups_in_row_q <= 16'd0;
            in_valid_q <= 1'b0; group_start_q <= 1'b0; row_start_q <= 1'b0;
        end else begin
            desc_ack   <= 1'b0; // defaults: pulses
            wf_start   <= 1'b0;
            op_done_r  <= 1'b0;
            op_error_r <= 1'b0;

            // Registered copies feeding acc_mac -- the "data phase" side of
            // the address/data pipeline described at the top of this file.
            in_valid_q    <= issue_read_c;
            group_start_q <= issue_read_c && is_word_group_first_c;
            row_start_q   <= issue_read_c && is_word_row_first_c;

            case (state)

                S_IDLE: begin
                    op_busy_r <= 1'b0;
                    if (desc_valid) begin
                        desc_ack <= 1'b1;
                        if (accept_range_bad || accept_slot_bad) begin
                            op_error_r      <= 1'b1;
                            op_error_code_r <= accept_range_bad ? `ACC_ERR_RANGE : `ACC_ERR_SLOT;
                            // stays in S_IDLE -- rejected descriptor never starts (contract)
                        end else begin
                            op_w_q_base <= desc_w_q_base;
                            op_w_s_base <= desc_w_s_base;
                            op_n        <= desc_n;
                            op_d        <= desc_d;
                            op_gs       <= desc_gs;

                            words_per_group_q <= accept_words_per_group_c;
                            words_per_row_q   <= accept_words_per_row_c;
                            groups_per_row_q  <= accept_groups_per_row_c;
                            q_words_total_q   <= ({16'b0, desc_n} * {16'b0, desc_d}) >> LANES_SHIFT;
                            words_fed_q       <= 32'd0;
                            word_in_group_q   <= 16'd0;
                            word_in_row_q     <= 16'd0;
                            group_count_q     <= {SCALE_AWIDTH{1'b0}};
                            act_group_idx_q   <= {ACT_AWIDTH{1'b0}};

                            act_slot_xq_base_q <= desc_x_slot[SLOT_IDX_BITS-1:0] * ACT_SLOT_WORDS[ACT_AWIDTH-1:0];
                            act_slot_xs_base_q <= desc_x_slot[SLOT_IDX_BITS-1:0] * ACT_SLOT_WORDS[ACT_AWIDTH-1:0]
                                                   + ACT_XQ_WORDS[ACT_AWIDTH-1:0];
                            out_slot_base_q     <= desc_out_slot[SLOT_IDX_BITS-1:0] * RESULT_SLOT_WORDS[RESULT_AWIDTH-1:0];
                            out_row_idx_q          <= 16'd0;
                            commit_groups_in_row_q  <= 16'd0;

                            op_busy_r <= 1'b1;
                            op_perf_cycles_r <= 32'd0;
                            op_perf_stall_r  <= 32'd0;
                            wf_start  <= 1'b1;
                            state     <= S_RUNNING;
                        end
                    end
                end

                S_RUNNING: begin
                    op_busy_r <= 1'b1;
                    op_perf_cycles_r <= op_perf_cycles_r + 32'd1;
                    // Stalled on memory: still work to feed, but the FIFO is
                    // empty this cycle -- this is the bandwidth-vs-control
                    // diagnostic the whole feature depends on (contract:
                    // "PERF_STALL ... primary diagnostic").
                    if ((words_fed_q < q_words_total_q) && fifo_empty)
                        op_perf_stall_r <= op_perf_stall_r + 32'd1;

                    if (issue_read_c) begin
                        word_in_group_q <= (word_in_group_q == words_per_group_q - 16'd1) ? 16'd0 : word_in_group_q + 16'd1;
                        word_in_row_q   <= (word_in_row_q   == words_per_row_q   - 16'd1) ? 16'd0 : word_in_row_q   + 16'd1;
                        words_fed_q     <= words_fed_q + 32'd1;

                        if (is_group_last_c) begin
                            group_count_q   <= group_count_q + 1'b1;
                            act_group_idx_q <= is_row_last_word_c ? {ACT_AWIDTH{1'b0}} : act_group_idx_q + 1'b1;
                        end
                    end

                    // Result commit: one row_valid pulse per GROUP (acc_mac
                    // header note 2) -- only the pulse coinciding with the
                    // row's last group is the row's final value.
                    if (mac_row_valid) begin
                        if (commit_groups_in_row_q == groups_per_row_q - 16'd1) begin
                            result_mem[out_slot_base_q + out_row_idx_q[RESULT_AWIDTH-1:0]] <= mac_row_result;
                            commit_groups_in_row_q <= 16'd0;
                            if (out_row_idx_q + 16'd1 == op_d) begin
                                op_done_r <= 1'b1;
                                op_busy_r <= 1'b0;
                                state     <= S_IDLE;
                            end else begin
                                out_row_idx_q <= out_row_idx_q + 16'd1;
                            end
                        end else begin
                            commit_groups_in_row_q <= commit_groups_in_row_q + 16'd1;
                        end
                    end

                    if (regs_op_abort) begin
                        wf_abort  <= 1'b1;
                        in_valid_q <= 1'b0; group_start_q <= 1'b0; row_start_q <= 1'b0;
                        state     <= S_ABORTING;
                    end
                end

                S_ABORTING: begin
                    op_busy_r <= 1'b1; // still winding down -- not idle yet
                    wf_abort  <= 1'b0; // one-cycle pulse into acc_weight_fetch, already sent
                    in_valid_q <= 1'b0; group_start_q <= 1'b0; row_start_q <= 1'b0;
                    // Do not accept a new descriptor (and do not re-pulse
                    // wf_start) until acc_weight_fetch has actually
                    // returned to ITS OWN idle: it only samples `start`
                    // from that state, so starting early here would be
                    // silently dropped and this module would then wait
                    // forever for a `done` that never arrives.
                    if (!wf_busy) begin
                        op_busy_r <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
