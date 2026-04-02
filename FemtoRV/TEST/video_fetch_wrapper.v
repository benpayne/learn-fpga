// Test wrapper for the complete video fetch pipeline
// Instantiates: video_fetch_engine + sdram_arbiter + muchtoremember_burst + video_line_fifo
// Exposes separated SDRAM data bus for cocotb testing

module video_fetch_wrapper (
    input         clk,
    input         resetn,

    // SDRAM command signals
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

    // VGA timing inputs
    input         hsync_start,
    input         vsync_start,
    input  [25:0] fb_base,

    // CPU port (directly to arbiter)
    input  [3:0]  cpu_wmask,
    input         cpu_rd,
    input  [25:0] cpu_addr,
    input  [31:0] cpu_din,
    output [31:0] cpu_dout,
    output        cpu_busy,

    // FIFO read port (pixel side)
    input         fifo_rd_en,
    output [31:0] fifo_rd_data,
    output        fifo_empty,

    // Status
    output [9:0]  fetch_line_num
);

    // ---- Bidirectional SDRAM bus ----
    wire [31:0] sd_d;
    assign sd_d = sd_d_drive ? sd_d_out : sd_d_in;

    // ---- SDRAM controller ----
    wire [31:0] ctrl_dout;
    wire        ctrl_busy;
    wire [31:0] ctrl_burst_dout;
    wire        ctrl_burst_valid;
    wire        ctrl_burst_done;
    wire        ctrl_burst_busy;

    wire [3:0]  ctrl_wmask;
    wire        ctrl_rd;
    wire [25:0] ctrl_addr;
    wire [31:0] ctrl_din;
    wire        ctrl_burst_rd;
    wire [25:0] ctrl_burst_addr;
    wire [8:0]  ctrl_burst_len;

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

        .wmask    (ctrl_wmask),
        .rd       (ctrl_rd),
        .addr     (ctrl_addr),
        .din      (ctrl_din),
        .dout     (ctrl_dout),
        .busy     (ctrl_busy),

        .burst_rd   (ctrl_burst_rd),
        .burst_addr (ctrl_burst_addr),
        .burst_len  (ctrl_burst_len),
        .burst_dout (ctrl_burst_dout),
        .burst_valid(ctrl_burst_valid),
        .burst_done (ctrl_burst_done),
        .burst_busy (ctrl_burst_busy)
    );

    assign sd_d_out = sdram_ctrl.sd_data_out;
    assign sd_d_drive = sdram_ctrl.sd_data_drive;

    // ---- Arbiter ----
    wire        vid_burst_rd;
    wire [25:0] vid_burst_addr;
    wire [8:0]  vid_burst_len;
    wire [31:0] vid_burst_dout;
    wire        vid_burst_valid;
    wire        vid_burst_busy;

    sdram_arbiter arbiter (
        .clk     (clk),
        .resetn  (resetn),

        .vid_burst_rd    (vid_burst_rd),
        .vid_burst_addr  (vid_burst_addr),
        .vid_burst_len   (vid_burst_len),
        .vid_burst_dout  (vid_burst_dout),
        .vid_burst_valid (vid_burst_valid),
        .vid_burst_busy  (vid_burst_busy),

        .cpu_wmask (cpu_wmask),
        .cpu_rd    (cpu_rd),
        .cpu_addr  (cpu_addr),
        .cpu_din   (cpu_din),
        .cpu_dout  (cpu_dout),
        .cpu_busy  (cpu_busy),

        .ctrl_wmask      (ctrl_wmask),
        .ctrl_rd         (ctrl_rd),
        .ctrl_addr       (ctrl_addr),
        .ctrl_din        (ctrl_din),
        .ctrl_dout       (ctrl_dout),
        .ctrl_busy       (ctrl_busy),

        .ctrl_burst_rd   (ctrl_burst_rd),
        .ctrl_burst_addr (ctrl_burst_addr),
        .ctrl_burst_len  (ctrl_burst_len),
        .ctrl_burst_dout (ctrl_burst_dout),
        .ctrl_burst_valid(ctrl_burst_valid),
        .ctrl_burst_busy (ctrl_burst_busy)
    );

    // ---- FIFO ----
    wire [31:0] fifo_wdata;
    wire        fifo_wen;
    wire        fifo_full;

    video_line_fifo fifo (
        .clk_w    (clk),
        .rst_w    (!resetn),
        .wr_data  (fifo_wdata),
        .wr_en    (fifo_wen),
        .full     (fifo_full),
        .almost_full (),

        .clk_r    (clk),       // Same clock for testing
        .rst_r    (!resetn),
        .rd_data  (fifo_rd_data),
        .rd_en    (fifo_rd_en),
        .empty    (fifo_empty),
        .almost_empty (),
        .wr_fill  ()
    );

    // ---- Video fetch engine ----
    video_fetch_engine #(
        .H_ACTIVE(640),
        .V_ACTIVE(400),
        .STRIDE_WORDS(320),      // Tight packing: 320 words per line, no padding
        .FB_BASE_PARAM(26'h0)
    ) fetch (
        .clk        (clk),
        .resetn     (resetn),
        .hsync_start(hsync_start),
        .vsync_start(vsync_start),
        .fb_base    (fb_base),

        .burst_rd   (vid_burst_rd),
        .burst_addr (vid_burst_addr),
        .burst_len  (vid_burst_len),
        .burst_dout (vid_burst_dout),
        .burst_valid(vid_burst_valid),
        .burst_busy (vid_burst_busy),

        .fifo_wdata (fifo_wdata),
        .fifo_wen   (fifo_wen),
        .fifo_full  (fifo_full),

        .line_num   (fetch_line_num)
    );

endmodule
