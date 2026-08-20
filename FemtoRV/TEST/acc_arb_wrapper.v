// Test wrapper for the CPU_PRIORITY / anti-starvation arbitration scheme in
// muchtoremember_burst (FemtoRV/RTL/ACCEL/DESIGN.md sec 6.2, tasks T040/T041).
//
// Same bidirectional-bus-splitting pattern as sdram_burst_wrapper.v, plus:
//  - CPU_PRIORITY/STARVE_LIMIT/STARVE_CNT_WIDTH exposed as wrapper parameters
//    so a cocotb run can build once with the accelerator-sharing scheme
//    enabled (CPU_PRIORITY=1) without disturbing the legacy-default
//    sdram_burst_tb.py build, which instantiates muchtoremember_burst
//    directly via sdram_burst_wrapper.v and never touches these parameters.
//  - starve_guard_fired routed out for the testbench to sample directly
//    (FR-017: the anti-starvation guard's fire count must be observable).
//
// Defaults here are the accelerator-profile values under test, NOT the
// controller's own defaults (which stay legacy/burst-first, see
// muchtoremember_burst.v header comment).

module acc_arb_wrapper #(
    parameter CPU_PRIORITY     = 1,   // this testbench exists to exercise CPU-first mode
    parameter STARVE_LIMIT     = 16,  // matches the controller's own default
    parameter STARVE_CNT_WIDTH = 16   // wide enough not to saturate mid-sweep
) (
    input         clk,
    input         resetn,

    // SDRAM command signals (directly from controller)
    output [12:0] sd_addr,
    output [1:0]  sd_ba,
    output [3:0]  sd_dqm,
    output        sd_cs,
    output        sd_we,
    output        sd_ras,
    output        sd_cas,

    // Separated data bus for testing
    output [31:0] sd_d_out,      // Data FROM controller (for writes, unused here)
    output        sd_d_drive,    // Controller is driving the bus
    input  [31:0] sd_d_in,       // Data TO controller (SDRAM read data)

    // Port A: Single-word (synthetic CPU traffic generator)
    input  [3:0]  wmask,
    input         rd,
    input  [25:0] addr,
    input  [31:0] din,
    output [31:0] dout,
    output        busy,

    // Port B: Burst read (synthetic accelerator, driven continuously)
    input         burst_rd,
    input  [25:0] burst_addr,
    input  [8:0]  burst_len,
    output [31:0] burst_dout,
    output        burst_valid,
    output        burst_done,
    output        burst_busy,

    // Anti-starvation guard observation (FR-017)
    output [STARVE_CNT_WIDTH-1:0] starve_guard_fired
);

    // Bidirectional bus simulation — identical trick to sdram_burst_wrapper.v
    wire [31:0] sd_d;
    wire [31:0] sd_data_out_internal;

    assign sd_d = sd_d_drive ? sd_data_out_internal : sd_d_in;

    muchtoremember_burst #(
        .CPU_PRIORITY    (CPU_PRIORITY),
        .STARVE_LIMIT    (STARVE_LIMIT),
        .STARVE_CNT_WIDTH(STARVE_CNT_WIDTH)
    ) uut (
        .sd_clk   (),
        .sd_d     (sd_d),
        .sd_addr  (sd_addr),
        .sd_ba    (sd_ba),
        .sd_dqm   (sd_dqm),
        .sd_cs    (sd_cs),
        .sd_we    (sd_we),
        .sd_ras   (sd_ras),
        .sd_cas   (sd_cas),

        .clk      (clk),
        .resetn   (resetn),

        .wmask    (wmask),
        .rd       (rd),
        .addr     (addr),
        .din      (din),
        .dout     (dout),
        .busy     (busy),

        .burst_rd   (burst_rd),
        .burst_addr (burst_addr),
        .burst_len  (burst_len),
        .burst_dout (burst_dout),
        .burst_valid(burst_valid),
        .burst_done (burst_done),
        .burst_busy (burst_busy),

        .starve_guard_fired(starve_guard_fired),

        .sd_data_in_out()
    );

    assign sd_d_out = uut.sd_data_out;
    assign sd_d_drive = uut.sd_data_drive;

endmodule
