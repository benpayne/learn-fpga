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
// Holds: the descriptor queue (data-model.md entity 4), CTRL/STATUS,
// PERF_CYCLES/PERF_STALL (data-model.md entity 5 -- "not optional", FR-008).
// Descriptor field validation (FR-009: n%gs==0, gs a supported power of
// two, n/d within configured maxima, d*4 fits the result slot) and error
// code assignment are the control FSM's job in acc_top; this module carries
// the resulting op_error/op_error_code back into STATUS.
//
// TODO(T033): implement register decode, the descriptor FIFO (BRAM,
// QUEUE_DEPTH entries), CTRL.START enqueue / CTRL.ABORT, STATUS assembly,
// and PERF_CYCLES/PERF_STALL capture. No logic yet per T001.

module acc_regs #(
    parameter QUEUE_DEPTH   = 16,  // descriptor FIFO depth (DESIGN.md sec 5.3: "a small FIFO (8-16
                                    // entries)" so the CPU can enqueue a whole layer and move on)
    parameter ADDR_WIDTH    = 26,  // w_q_base/w_s_base width, matches muchtoremember_burst.v addressing
    parameter SLOT_WIDTH    = 8,   // x_slot/out_slot index width (data-model.md entity 4)
    parameter DIM_WIDTH     = 16,  // n/d/gs field width (data-model.md entity 4)
    parameter ERR_WIDTH     = 4    // op_error_code width (contracts doc: ERR_DIM/ERR_GS/ERR_RANGE/
                                    // ERR_SLOT/ERR_FULL)
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

    // TODO(T033): register file (W_Q_BASE, W_S_BASE, X_SLOT, OUT_SLOT, N, D,
    // GS, MODE, CTRL, STATUS, PERF_CYCLES, PERF_STALL), index-select latch on
    // sel_idx write, read/write mux on sel_dat, descriptor FIFO push on
    // CTRL.START (with ERR_FULL if the queue is full and BUSY), FIFO pop
    // exposed as desc_valid/desc_* to acc_top. No logic yet per T001.

endmodule
