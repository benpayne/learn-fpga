// sdram_arbiter.v — Pin multiplexer between original SDRAM controller and burst reader
//
// When burst reader is idle:  original controller drives SDRAM pins, CPU runs normally
// When burst reader is active: burst reader drives SDRAM pins, CPU is stalled
//
// The original muchtoremember controller is NOT modified — its busy signal
// timing is preserved exactly. During bursts, the arbiter blocks CPU requests
// to the original controller (rd=0, wmask=0) and overrides the SDRAM pins.

module sdram_arbiter (
    input  wire        clk,
    input  wire        resetn,

    // ---- Video burst interface (from fetch engine) ----
    input  wire        vid_burst_rd,
    input  wire [25:0] vid_burst_addr,
    input  wire [8:0]  vid_burst_len,
    output wire [31:0] vid_burst_dout,
    output wire        vid_burst_valid,
    output wire        vid_burst_done,
    output wire        vid_burst_busy,

    // ---- CPU cache <-> original controller signals ----
    // These go BETWEEN the cache and the original muchtoremember
    input  wire [3:0]  cpu_wmask,       // From cache
    input  wire        cpu_rd,          // From cache
    input  wire [25:0] cpu_addr,        // From cache
    input  wire [31:0] cpu_din,         // From cache
    output wire [31:0] cpu_dout,        // To cache
    output wire        cpu_busy,        // To cache

    // ---- Original controller ports ----
    output wire [3:0]  ctrl_wmask,      // To muchtoremember
    output wire        ctrl_rd,         // To muchtoremember
    output wire [25:0] ctrl_addr,       // To muchtoremember
    output wire [31:0] ctrl_din,        // To muchtoremember
    input  wire [31:0] ctrl_dout,       // From muchtoremember
    input  wire        ctrl_busy,       // From muchtoremember

    // ---- Original controller SDRAM pin outputs ----
    input  wire [12:0] ctrl_sd_addr,
    input  wire [1:0]  ctrl_sd_ba,
    input  wire [3:0]  ctrl_sd_dqm,
    input  wire        ctrl_sd_cs,
    input  wire        ctrl_sd_we,
    input  wire        ctrl_sd_ras,
    input  wire        ctrl_sd_cas,

    // ---- Burst reader SDRAM pin outputs ----
    input  wire [12:0] burst_sd_addr,
    input  wire [1:0]  burst_sd_ba,
    input  wire [3:0]  burst_sd_dqm,
    input  wire        burst_sd_cs,
    input  wire        burst_sd_we,
    input  wire        burst_sd_ras,
    input  wire        burst_sd_cas,
    input  wire        burst_active,    // Burst reader is driving pins

    // ---- Muxed SDRAM pin outputs (to actual SDRAM chip) ----
    output wire [12:0] sd_addr,
    output wire [1:0]  sd_ba,
    output wire [3:0]  sd_dqm,
    output wire        sd_cs,
    output wire        sd_we,
    output wire        sd_ras,
    output wire        sd_cas
);

    // ---- SDRAM pin mux: burst reader overrides when active ----
    assign sd_addr = burst_active ? burst_sd_addr : ctrl_sd_addr;
    assign sd_ba   = burst_active ? burst_sd_ba   : ctrl_sd_ba;
    assign sd_dqm  = burst_active ? burst_sd_dqm  : ctrl_sd_dqm;
    assign sd_cs   = burst_active ? burst_sd_cs   : ctrl_sd_cs;
    assign sd_we   = burst_active ? burst_sd_we   : ctrl_sd_we;
    assign sd_ras  = burst_active ? burst_sd_ras  : ctrl_sd_ras;
    assign sd_cas  = burst_active ? burst_sd_cas  : ctrl_sd_cas;

    // ---- CPU port: block requests during burst ----
    assign ctrl_wmask = burst_active ? 4'b0000 : cpu_wmask;
    assign ctrl_rd    = burst_active ? 1'b0    : cpu_rd;
    assign ctrl_addr  = cpu_addr;
    assign ctrl_din   = cpu_din;

    // ---- CPU responses: pass through from original controller ----
    assign cpu_dout = ctrl_dout;
    assign cpu_busy = ctrl_busy | burst_active;

endmodule
