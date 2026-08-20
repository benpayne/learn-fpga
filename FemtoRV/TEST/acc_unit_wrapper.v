// Test wrapper for the complete int8 MatMul accelerator (T035/T036).
// Instantiates: acc_top (acc_regs + acc_weight_fetch + acc_mac + weight
// FIFO + scale/activation/result BRAMs) + muchtoremember_burst (real SDRAM
// controller model, driven by cocotb exactly as sdram_burst_tb.py drives
// it).
//
// Modelled on FemtoRV/TEST/sdram_burst_wrapper.v (bidirectional SDRAM data
// bus split into sd_d_out/sd_d_drive/sd_d_in for cocotb) and
// FemtoRV/TEST/video_fetch_wrapper.v (a burst-only consumer of
// muchtoremember_burst with the CPU single-word port simply tied off,
// since acc_top -- like the video fetch engine -- never issues single-word
// SDRAM accesses; it only drives the burst port).
//
// BURST_LEN is a parameter (not hardcoded) per the team lead's brief: the
// arbitration sweep moved the default from 64 to 128, and this wrapper
// must not silently pin either value -- it forwards BURST_LEN straight to
// acc_top, which forwards it to acc_weight_fetch, which sizes its FIFO
// request threshold off it. FIFO_DEPTH is likewise NOT re-derived here;
// acc_top's own default (4*BURST_LEN) is left to apply so the FIFO_DEPTH
// >= BURST_LEN relationship the design docs call out can't drift between
// this wrapper and the real integration site in femtosoc.v.

module acc_unit_wrapper #(
    parameter BURST_LEN = 128
) (
    input         clk,
    input         resetn,

    // ---- SDRAM command signals + separated data bus (cocotb-facing) ----
    output [12:0] sd_addr,
    output [1:0]  sd_ba,
    output [3:0]  sd_dqm,
    output        sd_cs,
    output        sd_we,
    output        sd_ras,
    output        sd_cas,
    output [31:0] sd_d_out,
    output        sd_d_drive,
    input  [31:0] sd_d_in,

    // ---- FemtoRV IO bus -- two one-hot chip selects into acc_regs ----
    input  [31:0] io_wdata,
    output [31:0] io_rdata,
    input         io_wstrb,
    input         io_rstrb,
    input         io_sel_idx,
    input         io_sel_dat,

    // ---- Result BRAM -- CPU-facing synchronous read port ----
    input         res_sel,
    input         res_rstrb,
    input  [11:0] res_addr,
    output [31:0] res_rdata,

    // ---- Activation BRAM -- CPU-facing write port ----
    input         act_sel,
    input  [3:0]  act_wmask,
    input  [11:0] act_addr,
    input  [31:0] act_wdata
);

    // ---- Bidirectional SDRAM bus ----
    wire [31:0] sd_d;
    assign sd_d = sd_d_drive ? sd_d_out : sd_d_in;

    wire [31:0] burst_dout;
    wire        burst_valid, burst_done, burst_busy;
    wire        burst_rd;
    wire [25:0] burst_addr;
    wire [8:0]  burst_len;

    muchtoremember_burst sdram_ctrl (
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

        // Single-word (CPU) port: acc_top never uses it -- tied off, same
        // pattern as video_fetch_wrapper.v.
        .wmask    (4'b0),
        .rd       (1'b0),
        .addr     (26'b0),
        .din      (32'b0),
        .dout     (),
        .busy     (),

        .burst_rd   (burst_rd),
        .burst_addr (burst_addr),
        .burst_len  (burst_len),
        .burst_dout (burst_dout),
        .burst_valid(burst_valid),
        .burst_done (burst_done),
        .burst_busy (burst_busy)
    );

    assign sd_d_out   = sdram_ctrl.sd_data_out;
    assign sd_d_drive = sdram_ctrl.sd_data_drive;

    acc_top #(
        .BURST_LEN (BURST_LEN)
        // Every other acc_top parameter (LANES, ELEM_WIDTH, FIFO_DEPTH,
        // QUEUE_DEPTH, ADDR_WIDTH, MAX_N, MAX_D, ACT_AWIDTH, RESULT_AWIDTH,
        // NUM_SLOTS, ACT_XS_WORDS) is left at its default -- this test
        // exercises the shipped configuration, not a synthetic one.
    ) dut (
        .clk       (clk),
        .resetn    (resetn),

        .io_wdata  (io_wdata),
        .io_rdata  (io_rdata),
        .io_wstrb  (io_wstrb),
        .io_rstrb  (io_rstrb),
        .io_sel_idx(io_sel_idx),
        .io_sel_dat(io_sel_dat),

        .res_sel   (res_sel),
        .res_rstrb (res_rstrb),
        .res_addr  (res_addr),
        .res_rdata (res_rdata),

        .act_sel   (act_sel),
        .act_wmask (act_wmask),
        .act_addr  (act_addr),
        .act_wdata (act_wdata),

        .burst_rd   (burst_rd),
        .burst_addr (burst_addr),
        .burst_len  (burst_len),
        .burst_dout (burst_dout),
        .burst_valid(burst_valid),
        .burst_done (burst_done),
        .burst_busy (burst_busy)
    );

endmodule
