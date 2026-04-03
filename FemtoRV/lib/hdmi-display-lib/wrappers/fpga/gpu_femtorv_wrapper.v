//==============================================================================
// gpu_femtorv_wrapper.v - FemtoRV 32-bit Bus Adapter for HDMI Display Library
//==============================================================================
// Adapts the 8-bit register interface of gpu_top to FemtoRV's 32-bit
// memory-mapped I/O bus using a SINGLE 1-hot IO address.
//
// FemtoRV uses 1-hot IO addressing where each device gets one bit in the
// io_word_address. Multiple address bits cannot be combined as register
// offsets because they'd select other devices simultaneously.
//
// Solution: Pack the GPU register index into wdata alongside the value:
//
//   Write: IO_OUT(IO_GPU, (reg << 8) | value)
//     wdata[7:0]   = 8-bit value to write to GPU register
//     wdata[12:8]  = 5-bit GPU register address (0x00-0x1F)
//
//   Read:  First write register index, then read back:
//     IO_OUT(IO_GPU, reg << 8)     -- select register (value ignored)
//     data = IO_IN(IO_GPU)          -- read selected register
//     Result in bits [7:0], upper bits zero.
//
// GPU register map (addr[4:0]):
//   0x00-0x0F: Graphics GPU registers
//   0x10-0x1F: Character GPU registers
//     0x10: CHAR_DATA, 0x11: CURSOR_ROW, 0x12: CURSOR_COL
//     0x13: CONTROL, 0x14: FG_COLOR, 0x15: BG_COLOR, 0x16: STATUS
//
// Author: Ben Payne
// License: MIT
//==============================================================================

module gpu_femtorv_wrapper(
    // FemtoRV bus interface
    input  wire        clk,            // System clock (= clk_cpu)
    input  wire        reset,          // Active-high reset (1=running, FemtoRV convention)
    input  wire [31:0] wdata,          // Write data from CPU
    output wire [31:0] rdata,          // Read data to CPU
    input  wire        wstrb,          // Write strobe
    input  wire        rstrb,          // Read strobe
    input  wire        sel,            // Chip select (1-hot decoded)

    // Clock inputs (from PLL)
    input  wire        clk_pixel,      // 25 MHz pixel clock
    input  wire        clk_tmds,       // 125 MHz TMDS clock

    // TMDS parallel output (2-bit DDR for ODDRX1F primitives)
    output wire [1:0]  tmds_clk_out,   // TMDS clock channel
    output wire [1:0]  tmds_red_out,   // TMDS red channel
    output wire [1:0]  tmds_green_out, // TMDS green channel
    output wire [1:0]  tmds_blue_out,  // TMDS blue channel

    // Optional: VBlank interrupt output
    output wire        gpu_irq,
    output wire        scanline_irq,

    // Video timing pulses for framebuffer fetch engine
    output wire        hsync_start,    // 1-cycle pulse at start of HBlank
    output wire        vsync_start,    // 1-cycle pulse at start of VBlank

    // Framebuffer pixel input (from video FIFO)
    input  wire [31:0] fb_pixel_data,  // 2x RGB565 pixels from FIFO
    input  wire        fb_pixel_valid, // FIFO has data
    output wire        fb_pixel_rd,    // Request next word from FIFO

    // Display mode and timing outputs
    output wire [1:0]  display_mode_out,
    output wire [9:0]  v_count_out,       // Current display line (from VGA timing)
    output wire [9:0]  h_count_out        // Current pixel position
);

    //==========================================================================
    // Bus Signal Adaptation
    //==========================================================================

    wire rst_n = reset;

    // Extract GPU register address and data from wdata
    wire [4:0] gpu_addr_from_wdata = wdata[12:8];
    wire [7:0] gpu_data_in = wdata[7:0];

    // Latched register address for reads
    // (write sets the address, subsequent read returns that register's data)
    reg [4:0] gpu_addr_reg;
    always @(posedge clk) begin
        if (!rst_n)
            gpu_addr_reg <= 5'h10;  // Default to CHAR_DATA
        else if (sel & wstrb)
            gpu_addr_reg <= gpu_addr_from_wdata;
    end

    // Use latched address for reads, wdata address for writes
    wire [4:0] gpu_addr = (sel & wstrb) ? gpu_addr_from_wdata : gpu_addr_reg;

    // Gate write/read enables with chip select
    wire gpu_we = sel & wstrb;
    wire gpu_re = sel & rstrb;

    // GPU 8-bit read data
    wire [7:0] gpu_data_out;

    // Zero-extend and gate with sel for OR'd io_rdata bus
    assign rdata = sel ? {24'b0, gpu_data_out} : 32'b0;

    //==========================================================================
    // GPU Top Instance
    //==========================================================================

    wire [1:0] debug_display_mode;
    wire debug_gfx_gpu_cs;
    wire debug_char_gpu_cs;
    wire debug_vsync;

    gpu_top gpu_inst(
        // Clock and reset
        .clk_cpu       (clk),
        .clk_pixel     (clk_pixel),
        .clk_tmds      (clk_tmds),
        .rst_n         (rst_n),

        // CPU bus interface
        .addr          ({3'b0, gpu_addr}),
        .data_in       (gpu_data_in),
        .data_out      (gpu_data_out),
        .we            (gpu_we),
        .re            (gpu_re),

        // TMDS output
        .tmds_clk_out  (tmds_clk_out),
        .tmds_red_out  (tmds_red_out),
        .tmds_green_out(tmds_green_out),
        .tmds_blue_out (tmds_blue_out),

        // Debug outputs
        .debug_display_mode(debug_display_mode),
        .debug_gfx_gpu_cs  (debug_gfx_gpu_cs),
        .debug_char_gpu_cs (debug_char_gpu_cs),
        .debug_vsync       (debug_vsync),
        .scanline_hblank_irq(scanline_irq),

        // Timing counters for video fetch
        .out_h_count   (gpu_h_count),
        .out_v_count   (gpu_v_count),

        // Framebuffer pixel input
        .fb_pixel_data (fb_pixel_data),
        .fb_pixel_valid(fb_pixel_valid),
        .fb_pixel_rd   (fb_pixel_rd)
    );

    // VBlank interrupt
    assign gpu_irq = debug_vsync;

    // ---- Video timing pulses for framebuffer fetch engine ----
    wire [9:0] gpu_h_count;
    wire [9:0] gpu_v_count;

    // Generate 1-cycle pulses at the start of HBlank and VBlank
    // HBlank starts when h_count transitions from 639 to 640
    // VBlank starts when v_count transitions from 399 to 400
    reg [9:0] h_count_prev, v_count_prev;
    always @(posedge clk_pixel) begin
        h_count_prev <= gpu_h_count;
        v_count_prev <= gpu_v_count;
    end
    assign hsync_start = (gpu_h_count == 10'd640) && (h_count_prev == 10'd639);
    assign vsync_start = (gpu_v_count == 10'd400) && (v_count_prev == 10'd399);
    assign display_mode_out = debug_display_mode;

    assign v_count_out = gpu_v_count;
    assign h_count_out = gpu_h_count;

endmodule
