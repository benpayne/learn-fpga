// Test wrapper for muchtoremember_burst
// Separates the bidirectional sd_d bus into sd_d_out (from controller)
// and sd_d_in (to controller) for clean cocotb testing.

module sdram_burst_wrapper (
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
    output [31:0] sd_d_out,      // Data FROM controller (for writes)
    output        sd_d_drive,    // Controller is driving the bus
    input  [31:0] sd_d_in,       // Data TO controller (SDRAM read data)

    // Port A: Single-word (CPU)
    input  [3:0]  wmask,
    input         rd,
    input  [25:0] addr,
    input  [31:0] din,
    output [31:0] dout,
    output        busy,

    // Port B: Burst read (Video)
    input         burst_rd,
    input  [25:0] burst_addr,
    input  [8:0]  burst_len,
    output [31:0] burst_dout,
    output        burst_valid,
    output        burst_done,
    output        burst_busy
);

    // Bidirectional bus simulation
    wire [31:0] sd_d;
    wire [31:0] sd_data_out_internal;

    // The wrapper drives sd_d when the controller wants to write
    // and reads from sd_d_in when the controller reads
    assign sd_d = sd_d_drive ? sd_data_out_internal : sd_d_in;

    muchtoremember_burst uut (
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
        .burst_busy (burst_busy)
    );

    // Extract internal signals for test visibility
    assign sd_d_out = uut.sd_data_out;
    assign sd_d_drive = uut.sd_data_drive;

endmodule
