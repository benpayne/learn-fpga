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
//    completion/errors/perf counters back to acc_regs;
//  - the activation BRAM (quantized activation vector, data-model.md
//    entity 3, written by the CPU before each operation) and the result
//    BRAM (data-model.md entity 6, mapped at 0x100000 in this profile per
//    research R8, written only by this module, read by ordinary CPU loads);
//  - address generation for the three modes (MODE_MATMUL / MODE_ATT_SCORE /
//    MODE_ATT_SUM, contracts/accelerator-interface.md) -- same datapath,
//    different address pattern per operand (DESIGN.md section 7). Modes 1
//    and 2 are added in T064; this skeleton carries the mode field through
//    so the interface does not change shape later.
//
// Does NOT own: SDRAM arbitration priority (that is a 3-line reorder plus a
// starvation counter inside muchtoremember_burst.v itself, DESIGN.md sec
// 9a/6.2, wired at integration time in femtosoc.v, not here).
//
// TODO(T034): instantiate acc_regs, acc_weight_fetch, acc_mac; wire the
// control FSM (IDLE -> RUNNING -> DONE -> IDLE, data-model.md entity 4
// "State transitions"); implement descriptor validation and error codes;
// implement the activation/result BRAMs and their CPU-facing ports;
// implement PERF_CYCLES/PERF_STALL accumulation. No logic yet per T001.

module acc_top #(
    parameter LANES         = 4,    // int8 MAC lanes, passed to acc_mac (DESIGN.md sec 3.4/4.2)
    parameter ELEM_WIDTH    = 8,    // element width, passed to acc_mac (FR-011: parameterised for a
                                     // 16-bit fallback)
    parameter BURST_LEN     = 64,   // SDRAM burst length in words, passed to acc_weight_fetch
                                     // (data-model.md sec 7)
    parameter FIFO_DEPTH    = 256,  // weight FIFO depth, passed to acc_weight_fetch
    parameter QUEUE_DEPTH   = 16,   // descriptor queue depth, passed to acc_regs
    parameter ADDR_WIDTH    = 26,   // SDRAM word address width throughout
    parameter MAX_N         = 4096, // largest supported inner dimension
    parameter MAX_D         = 4096, // largest supported output row count
    parameter ACT_AWIDTH    = 12,   // activation BRAM address width (slot index + element offset)
    parameter RESULT_AWIDTH = 12    // result BRAM address width (slot index + element offset);
                                     // RESULT_AWIDTH words MUST cover at least max_d fp32 values
                                     // per slot (data-model.md entity 6: "2 KB covers the d=512
                                     // classifier")
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
    input  wire                     res_sel,       // chip select from femtosoc.v's address decode
    input  wire                     res_rstrb,      // read strobe
    input  wire [RESULT_AWIDTH-1:0] res_addr,       // word address within the result BRAM
    output wire [31:0]              res_rdata,

    // Activation BRAM -- CPU-facing write port. The CPU quantizes and writes
    // the activation vector here before issuing an operation (data-model.md
    // entity 3: "Produced by the CPU before each operation"). Also
    // address-decoded in femtosoc.v.
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

    // TODO(T034): internal wires between acc_regs <-> control FSM <->
    // acc_weight_fetch <-> acc_mac <-> activation/result BRAMs. Instantiate:
    //   acc_regs #(...) u_regs (...);
    //   acc_weight_fetch #(...) u_fetch (...);
    //   acc_mac #(...) u_mac (...);
    // plus the activation and result BRAM arrays and the control FSM that
    // sequences them per descriptor. No logic yet per T001.

endmodule
