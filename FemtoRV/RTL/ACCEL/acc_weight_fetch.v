// acc_weight_fetch.v -- burst-read orchestrator feeding acc_mac's FIFO
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 3.2 (block diagram), section 3.3
// (why a FIFO), and section 9a ("Reusing the existing video/SDRAM path").
// Modelled directly on FemtoRV/RTL/SDRAM/video_fetch_engine.v, which already
// does burst-request + FIFO-feed correctly and is proven in hardware; this
// module is that structure with a weight-matrix address pattern instead of
// a scanline one.
//
// Q8_0 stores weights and scales as TWO SEPARATE CONTIGUOUS BLOCKS, not
// interleaved (data-model.md entity 1/2, research R1). So this module takes
// two independent base addresses and runs two phases per operation:
//   1. Scale prefetch: read the small `s` block (d*n/gs fp32 values) into
//      the scale BRAM. Small -- 1.5% of the data at GS=64 (data-model.md
//      entity 2).
//   2. Weight stream: read the dense `q` block (d*n int8 values, 4/word)
//      into the weight FIFO at full burst rate, decoupling SDRAM bursts
//      (with gaps) from acc_mac's one-word/cycle appetite.
// The two streams MUST NOT be interleaved so the inner loop stays
// single-source at full lane rate (data-model.md entity 2, "Rules").
//
// Drives FemtoRV/RTL/SDRAM/muchtoremember_burst.v's burst read port
// unchanged (DESIGN.md sec 9a: "Use it unchanged"). Read-only -- there is
// no burst write port; results go to the result BRAM instead (acc_top).
//
// TODO(T032): implement the two-phase FSM (scale prefetch, then row-major
// q streaming), burst issue/FIFO-fill logic, and abort/flush handling.
// No logic yet per T001 -- port list and parameters only.

module acc_weight_fetch #(
    parameter BURST_LEN   = 64,   // words requested per burst (data-model.md sec 7: 64 words,
                                   // 91.4% efficiency vs 70-cycle CPU worst-case stall). Parameter,
                                   // not a constant -- FR-020 requires it be chosen from measurement.
    parameter FIFO_DEPTH  = 256,  // weight FIFO depth in 32-bit words (DESIGN.md sec 3.2: "~256 x 32b")
    parameter ADDR_WIDTH  = 26,   // SDRAM word address width, matches muchtoremember_burst.v's burst_addr
    parameter MAX_N       = 4096, // largest supported inner dimension (elements per row)
    parameter MAX_D       = 4096, // largest supported output row count
    parameter SCALE_AWIDTH = 12   // address width of the per-operation scale BRAM (max_n*max_d/min_gs)
) (
    input  wire                    clk,
    input  wire                    resetn,        // active-low, synchronous

    // Descriptor fields for the operation being fetched, latched by acc_top
    // at operation start (data-model.md entity 4 "Operation Descriptor").
    input  wire [ADDR_WIDTH-1:0]   w_q_base,      // base address of the dense int8 `q` block
    input  wire [ADDR_WIDTH-1:0]   w_s_base,      // base address of the fp32 `s` (scale) block,
                                                   // contiguous and AFTER the q block (research R1)
    input  wire [15:0]             n,             // inner dimension (elements per row)
    input  wire [15:0]             d,             // number of output rows
    input  wire [15:0]             gs,            // group size (elements per scale), runtime value

    // Control / status
    input  wire                    start,         // pulse: begin fetching for a new operation
    input  wire                    abort,         // pulse: abandon in-flight fetch, flush FIFO, -> IDLE
    output wire                    busy,          // high across both scale-prefetch and q-stream phases
    output wire                    done,          // pulse: all q words for this operation are in the FIFO

    // SDRAM burst read port -- FemtoRV/RTL/SDRAM/muchtoremember_burst.v, unmodified interface
    // (DESIGN.md sec 9a: "Nothing here is about video ... Use it unchanged.")
    output reg                     burst_rd,      // pulse to start a burst
    output reg  [ADDR_WIDTH-1:0]   burst_addr,    // burst start address
    output reg  [8:0]              burst_len,     // words requested (1-256)
    input  wire [31:0]             burst_dout,    // burst data output
    input  wire                    burst_valid,   // burst_dout valid this cycle
    input  wire                    burst_done,    // burst complete pulse
    input  wire                    burst_busy,    // high while a burst is in flight

    // Weight FIFO feed (dense int8 `q` stream, 4 elements packed per 32-bit word)
    output wire [31:0]             fifo_wdata,
    output wire                    fifo_wen,
    input  wire                    fifo_full,

    // Scale BRAM feed -- prefetched once per operation, before q streaming begins
    output wire [31:0]             scale_wdata,   // one fp32 scale value
    output wire                    scale_wen,
    output wire [SCALE_AWIDTH-1:0] scale_waddr    // index into this operation's scale buffer,
                                                   // 0 .. (n*d/gs)-1
);

    // TODO(T032): scale-prefetch phase (issue bursts across w_s_base for
    // n*d/gs words, write into scale BRAM), then q-stream phase (issue
    // bursts across w_q_base for n*d/4 words, feed weight FIFO, backpressure
    // on fifo_full), `done` on last q word accepted, `abort` flush of both
    // phases. No logic yet per T001.

endmodule
