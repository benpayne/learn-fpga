//==============================================================================
// gpu_core.v - DVI Character Display GPU Core Integration Module
//==============================================================================
// Project: RetroCPU - DVI Character Display GPU
// Description: Top-level GPU module integrating all video subsystems
//
// Author: RetroCPU Project
// License: MIT
// Created: 2025-12-28
//
// Features:
//   - 640x480@60Hz VGA/DVI output
//   - 40-column and 80-column text modes
//   - 8x16 pixel character cells (30 rows x 40/80 columns)
//   - Memory-mapped register interface for CPU control
//   - Dual-port character buffer with clock domain crossing
//   - 8-bit RGB output (3-3-2 format) expandable to 24-bit
//
// Integrated Modules:
//   1. vga_timing_generator - VGA timing and sync generation
//   2. character_buffer - Dual-port RAM for character storage
//   3. font_rom - 8x16 pixel font bitmap storage
//   4. character_renderer - Character-to-pixel rendering pipeline
//   5. gpu_registers - CPU register interface and control logic
//
// Clock Domains:
//   - clk_cpu: CPU/system clock domain (for register access and CPU writes)
//   - clk_pixel: Pixel clock domain (25 MHz for VGA timing and video output)
//   - Clock domain crossing is handled by dual-port RAM in character_buffer
//
// CPU Bus Interface:
//   - Address range: 0xC010-0xC016 (7 registers)
//   - 8-bit data bus
//   - Write enable (we) and read enable (re) control signals
//   - See gpu_registers.v for detailed register map
//
// Video Output:
//   - RGB: 8 bits per channel (24-bit color)
//   - HSYNC/VSYNC: Standard VGA sync signals (active low)
//   - video_active: High during visible region (optional debug signal)
//
// Memory Map (Base 0xC010):
//   0xC010: CHAR_DATA   - Write character at cursor position
//   0xC011: CURSOR_ROW  - Cursor row (0-29)
//   0xC012: CURSOR_COL  - Cursor column (0-39 or 0-79)
//   0xC013: CONTROL     - Mode control (clear, 40/80-col, cursor enable)
//   0xC014: FG_COLOR    - Foreground color (3-bit RGB)
//   0xC015: BG_COLOR    - Background color (3-bit RGB)
//   0xC016: STATUS      - GPU status (ready, vsync)
//
//==============================================================================

module gpu_core(
    // Clock and reset
    input  wire        clk_cpu,         // CPU/system clock domain
    input  wire        clk_pixel,       // Pixel clock (25 MHz for 640x480@60Hz)
    input  wire        rst_n,           // Active-low reset (async, both domains)

    // CPU bus interface (clk_cpu domain)
    input  wire [3:0]  addr,            // Register address offset (0x0-0xF)
    input  wire [7:0]  data_in,         // Data from CPU (for writes)
    output wire [7:0]  data_out,        // Data to CPU (for reads)
    input  wire        we,              // Write enable
    input  wire        re,              // Read enable

    // Video output (clk_pixel domain)
    output wire [7:0]  red,             // Red channel (8-bit)
    output wire [7:0]  green,           // Green channel (8-bit)
    output wire [7:0]  blue,            // Blue channel (8-bit)
    output wire        hsync,           // Horizontal sync (active low)
    output wire        vsync,           // Vertical sync (active low)
    output wire        video_active,    // High during visible region (optional)
    output wire [9:0]  h_count,         // Horizontal counter (for graphics GPU)
    output wire [9:0]  v_count          // Vertical counter (for graphics GPU)
);

    //==========================================================================
    // Internal Signals - VGA Timing Generator
    //==========================================================================

    wire [9:0] h_count;                 // Horizontal pixel counter (0-799)
    wire [9:0] v_count;                 // Vertical line counter (0-524)
    wire       frame_start;             // Pulse at start of new frame

    //==========================================================================
    // Internal Signals - GPU Registers to Control Logic
    //==========================================================================

    wire [4:0] cursor_row;              // Cursor row position (0-29)
    wire [6:0] cursor_col;              // Cursor column position (0-39/79)
    wire       mode_80col;              // Display mode: 0=40-col, 1=80-col
    wire       cursor_enable;           // Cursor visibility enable
    wire [3:0] fg_color;                // Foreground color (4-bit IRGB)
    wire [3:0] bg_color;                // Background color (4-bit IRGB)
    wire       clear_screen;            // Screen clear command pulse
    wire       scroll_screen;           // Screen scroll command pulse
    wire [4:0] top_line;                // Circular buffer: which physical line is at screen row 0

    // GPU status signals (to registers)
    wire       gpu_ready;               // GPU ready for commands (always 1)
    wire       vsync_status;            // VSYNC signal for status register

    //==========================================================================
    // Internal Signals - Character Buffer Interface
    //==========================================================================

    // CPU write port (from gpu_registers, clk_cpu domain)
    wire [11:0] char_buf_wr_addr;       // Write address (0-2399)
    wire [15:0] char_buf_wr_data;       // Write data {bg[3:0], fg[3:0], char[7:0]}
    wire        char_buf_we;            // Write enable

    // Video read port (from character_renderer, clk_pixel domain)
    wire [11:0] char_buf_rd_addr;       // Read address (0-2399)
    wire [15:0] char_buf_rd_data;       // Read data {bg[3:0], fg[3:0], char[7:0]}

    //==========================================================================
    // Internal Signals - Font ROM Interface
    //==========================================================================

    wire [7:0]  font_char_code;         // Character code to font ROM
    wire [3:0]  font_scanline;          // Scanline within character (0-15)
    wire [7:0]  font_pixel_row;         // 8-bit pixel row from font ROM

    //==========================================================================
    // Status Signal Generation
    //==========================================================================

    // GPU is always ready (no buffering or latency in current design)
    assign gpu_ready = 1'b1;

    // VSYNC status for register reads (synchronized to CPU clock domain)
    // For simplicity, we use the vsync signal directly. In a production design,
    // this should be synchronized using a dual-flop synchronizer.
    assign vsync_status = vsync;

    //==========================================================================
    // Module Instantiation
    //==========================================================================

    //--------------------------------------------------------------------------
    // 1. VGA Timing Generator
    //    Generates horizontal and vertical timing for 640x480@60Hz
    //--------------------------------------------------------------------------
    vga_timing_generator vga_timing_inst(
        .clk           (clk_pixel),      // Pixel clock (25 MHz)
        .rst_n         (rst_n),          // Active-low reset

        .h_count       (h_count),        // Horizontal counter (0-799)
        .v_count       (v_count),        // Vertical counter (0-524)
        .hsync         (hsync),          // Horizontal sync (active low)
        .vsync         (vsync),          // Vertical sync (active low)
        .video_active  (video_active),   // High during visible region
        .frame_start   (frame_start)     // Pulse at frame start
    );

    //--------------------------------------------------------------------------
    // 2. GPU Registers
    //    Memory-mapped register interface for CPU control
    //--------------------------------------------------------------------------
    gpu_registers gpu_registers_inst(
        .clk           (clk_cpu),        // CPU clock domain
        .rst_n         (rst_n),          // Active-low reset

        // CPU bus interface
        .addr          (addr),           // Register address (4-bit offset)
        .data_in       (data_in),        // Data from CPU
        .data_out      (data_out),       // Data to CPU
        .we            (we),             // Write enable
        .re            (re),             // Read enable

        // Control outputs
        .cursor_row    (cursor_row),     // Cursor row (0-29)
        .cursor_col    (cursor_col),     // Cursor column (0-39/79)
        .mode_80col    (mode_80col),     // Display mode
        .cursor_enable (cursor_enable),  // Cursor visibility
        .fg_color      (fg_color),       // Foreground color
        .bg_color      (bg_color),       // Background color
        .clear_screen  (clear_screen),   // Clear screen command
        .scroll_screen (scroll_screen),  // Scroll screen command
        .top_line      (top_line),       // Circular buffer top line

        // Status inputs
        .gpu_ready     (gpu_ready),      // GPU ready status
        .vsync         (vsync_status),   // VSYNC status

        // Character buffer write interface
        .char_buf_addr (char_buf_wr_addr), // Write address
        .char_buf_data (char_buf_wr_data), // Write data
        .char_buf_we   (char_buf_we)       // Write enable
    );

    //--------------------------------------------------------------------------
    // 3. Character Buffer
    //    Dual-port RAM for character storage with clock domain crossing
    //--------------------------------------------------------------------------
    character_buffer character_buffer_inst(
        // CPU write port (clk_cpu domain)
        .clk_cpu       (clk_cpu),        // CPU clock
        .addr_write    (char_buf_wr_addr), // Write address
        .data_write    (char_buf_wr_data), // Write data
        .we            (char_buf_we),      // Write enable

        // Video read port (clk_pixel domain)
        .clk_video     (clk_pixel),      // Pixel clock
        .addr_read     (char_buf_rd_addr), // Read address
        .data_read     (char_buf_rd_data)  // Read data (registered)
    );

    //--------------------------------------------------------------------------
    // 4. Font ROM
    //    Stores 8x16 pixel font bitmaps for ASCII characters
    //--------------------------------------------------------------------------
    font_rom font_rom_inst(
        .clk           (clk_pixel),      // Pixel clock
        .char_code     (font_char_code), // Character code (0-255)
        .scanline      (font_scanline),  // Scanline within char (0-15)
        .pixel_row     (font_pixel_row)  // 8-bit pixel row output
    );

    //--------------------------------------------------------------------------
    // 5. Character Renderer
    //    Converts character codes to RGB pixel output
    //--------------------------------------------------------------------------
    character_renderer character_renderer_inst(
        .clk           (clk_pixel),      // Pixel clock
        .rst_n         (rst_n),          // Active-low reset

        // Video timing inputs
        .h_count       (h_count),        // Horizontal position (0-639)
        .v_count       (v_count),        // Vertical position (0-479)
        .video_active  (video_active),   // Visible region flag

        // Mode and color configuration
        .mode_80col    (mode_80col),     // Display mode
        .top_line      (top_line),       // Circular buffer top line offset

        // Cursor configuration
        .cursor_enable (cursor_enable),  // Cursor visibility enable
        .cursor_row    (cursor_row),     // Cursor row position (0-29)
        .cursor_col    (cursor_col),     // Cursor column position (0-39/79)
        .vsync         (vsync),          // Vertical sync (for cursor blink)

        // Character buffer interface (read port)
        .char_addr     (char_buf_rd_addr), // Address to character buffer
        .char_data     (char_buf_rd_data), // Character code from buffer

        // Font ROM interface
        .font_char     (font_char_code),   // Character code to font ROM
        .font_scanline (font_scanline),    // Scanline to font ROM
        .font_pixels   (font_pixel_row),   // Pixel row from font ROM

        // RGB pixel output
        .red           (red),            // Red channel (8-bit)
        .green         (green),          // Green channel (8-bit)
        .blue          (blue)            // Blue channel (8-bit)
    );

    //==========================================================================
    // Notes on Clear Screen and Scroll Operations
    //==========================================================================
    //
    // The current design does not implement hardware-accelerated clear/scroll
    // operations. These are handled by the CPU writing to the character buffer:
    //
    // Clear Screen:
    //   CPU writes 0x20 (space) to all 1200 (40-col) or 2400 (80-col) locations
    //
    // Scroll Screen:
    //   CPU copies line N+1 to line N for all rows, then clears last row
    //
    // Future Enhancement:
    //   Add hardware logic to handle clear_screen and scroll_screen pulses
    //   for faster operation without CPU intervention.
    //
    //==========================================================================

    //==========================================================================
    // Notes on Clock Domain Crossing
    //==========================================================================
    //
    // This design has two clock domains:
    //   1. clk_cpu: System/CPU clock for register access and writes
    //   2. clk_pixel: 25 MHz pixel clock for video timing and rendering
    //
    // Clock Domain Crossing Handled By:
    //   - character_buffer: Dual-port RAM with separate clocks (safe by design)
    //   - Control signals (mode_80col, fg_color, bg_color): Quasi-static,
    //     change infrequently, so no synchronization needed in practice
    //
    // Potential Improvement:
    //   - Add dual-flop synchronizers for control signals if timing is critical
    //   - Synchronize vsync signal when crossing to CPU clock domain
    //
    //==========================================================================

endmodule
