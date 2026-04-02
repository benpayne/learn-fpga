// sdram_arbiter.v — Two-master arbiter for SDRAM controller
//
// Port 0 (Video): Burst read requests — gets priority
// Port 1 (CPU):   Single-word read/write — pass-through when no burst
//
// When video issues a burst, CPU is stalled (busy held high).
// When no burst is active, CPU requests pass through combinatorially
// with zero added latency — preserving the cache's timing expectations.

module sdram_arbiter (
    input  wire        clk,
    input  wire        resetn,

    // ---- Video port (burst reads only) ----
    input  wire        vid_burst_rd,
    input  wire [25:0] vid_burst_addr,
    input  wire [8:0]  vid_burst_len,
    output wire [31:0] vid_burst_dout,
    output wire        vid_burst_valid,
    output wire        vid_burst_busy,

    // ---- CPU port (single-word read/write, from sdram_cache) ----
    input  wire [3:0]  cpu_wmask,
    input  wire        cpu_rd,
    input  wire [25:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    output wire        cpu_busy,

    // ---- SDRAM controller (muchtoremember_burst) ----
    output wire [3:0]  ctrl_wmask,
    output wire        ctrl_rd,
    output wire [25:0] ctrl_addr,
    output wire [31:0] ctrl_din,
    input  wire [31:0] ctrl_dout,
    input  wire        ctrl_busy,

    output wire        ctrl_burst_rd,
    output wire [25:0] ctrl_burst_addr,
    output wire [8:0]  ctrl_burst_len,
    input  wire [31:0] ctrl_burst_dout,
    input  wire        ctrl_burst_valid,
    input  wire        ctrl_burst_done,
    input  wire        ctrl_burst_busy
);

    // Video burst: pass straight through
    assign ctrl_burst_rd   = vid_burst_rd;
    assign ctrl_burst_addr = vid_burst_addr;
    assign ctrl_burst_len  = vid_burst_len;
    assign vid_burst_dout  = ctrl_burst_dout;
    assign vid_burst_valid = ctrl_burst_valid;
    assign vid_burst_busy  = ctrl_burst_busy;

    // CPU read data: pass straight through
    assign cpu_dout = ctrl_dout;

    // CPU requests: pass through when no burst active
    // When burst is active, block CPU requests (drive zeros)
    wire burst_active = ctrl_burst_busy;

    assign ctrl_wmask = burst_active ? 4'b0000 : cpu_wmask;
    assign ctrl_rd    = burst_active ? 1'b0    : cpu_rd;
    assign ctrl_addr  = cpu_addr;
    assign ctrl_din   = cpu_din;

    // CPU busy: either SDRAM controller is busy OR a burst is in progress
    assign cpu_busy = ctrl_busy | burst_active;

endmodule
