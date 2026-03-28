//==============================================================================
// character_renderer.v - Character Rendering Pipeline for Text Display
//==============================================================================
// Project: RetroCPU - DVI Character Display GPU
// Description: Converts character codes to pixel data for display output
//
// Features:
//   - Dual mode operation: 40-column and 80-column text display
//   - Scanline-based rendering (processes one horizontal line at a time)
//   - Pipelined architecture for efficient operation
//   - 8x16 pixel character cells
//   - Configurable foreground/background colors (3-bit RGB)
//
// Display Modes:
//   40-Column Mode (mode_80col = 0):
//     - 40 characters per row × 30 rows = 1200 characters
//     - Each character: 16 pixels wide (8 font pixels doubled horizontally)
//     - Screen width: 40 × 16 = 640 pixels
//
//   80-Column Mode (mode_80col = 1):
//     - 80 characters per row × 30 rows = 2400 characters
//     - Each character: 8 pixels wide (native font pixel width)
//     - Screen width: 80 × 8 = 640 pixels
//
// Character Cell:
//   - Width: 8 pixels (font data), displayed as 8 or 16 pixels depending on mode
//   - Height: 16 pixels (scanlines)
//   - Screen height: 30 × 16 = 480 pixels
//
// Color Format:
//   - Input: 3-bit RGB (1 bit each for R, G, B)
//   - Output: 24-bit RGB (8 bits per channel)
//   - Color expansion: 0 → 0x00, 1 → 0xFF
//
// Pipeline Stages:
//   Stage 1: Calculate character position and address from h_count/v_count
//   Stage 2: Read character code from character buffer (1 cycle delay)
//   Stage 3: Read font pixels from font ROM (1 cycle delay)
//   Stage 4: Extract pixel, apply color, output RGB
//
// Timing:
//   - Total pipeline depth: 3 cycles
//   - Requires pre-fetching characters ahead of current display position
//   - Blank pixels output during video blanking (video_active = 0)
//
//==============================================================================

module character_renderer(
    input  wire        clk,             // Pixel clock (25 MHz)
    input  wire        rst_n,           // Active-low reset

    // Video timing inputs
    input  wire [9:0]  h_count,         // Horizontal pixel position (0-639)
    input  wire [9:0]  v_count,         // Vertical pixel position (0-479)
    input  wire        video_active,    // High during visible region

    // Mode configuration
    input  wire        mode_80col,      // 0=40-column, 1=80-column
    input  wire [4:0]  top_line,        // Circular buffer: physical line at screen row 0

    // Cursor configuration
    input  wire        cursor_enable,   // Cursor visibility enable
    input  wire [4:0]  cursor_row,      // Cursor row position (0-29)
    input  wire [6:0]  cursor_col,      // Cursor column position (0-39/79)
    input  wire        vsync,           // Vertical sync (for cursor blink timing)

    // Character buffer interface
    output wire [11:0] char_addr,       // Address to character buffer
    input  wire [15:0] char_data,       // {bg[3:0], fg[3:0], char[7:0]} from buffer

    // Font ROM interface
    output wire [7:0]  font_char,       // Character code to font ROM
    output wire [3:0]  font_scanline,   // Scanline (0-15)
    input  wire [7:0]  font_pixels,     // 8 pixels from font ROM

    // Pixel output (to DVI encoder)
    output reg  [7:0]  red,             // Red channel (8-bit)
    output reg  [7:0]  green,           // Green channel (8-bit)
    output reg  [7:0]  blue             // Blue channel (8-bit)
);

    //==========================================================================
    // Pipeline Stage 1: Calculate Character Position and Address
    //==========================================================================

    // Pipeline delay compensation:
    // - Character buffer read: 1 cycle
    // - Font ROM read: 1 cycle
    // - h_count_d2 delay: 2 cycles
    // Both data and position align after 2 cycles, so no prefetch offset needed
    wire [9:0] h_fetch = h_count;

    // Calculate character column based on display mode
    // 40-col: Each character is 16 pixels wide (char_col = h_fetch / 16)
    // 80-col: Each character is 8 pixels wide (char_col = h_fetch / 8)
    wire [5:0] char_col_40 = h_fetch[9:4];  // Divide by 16 (shift right 4 bits)
    wire [6:0] char_col_80 = h_fetch[9:3];  // Divide by 8 (shift right 3 bits)

    // Select character column based on mode
    wire [6:0] char_col = mode_80col ? char_col_80 : {1'b0, char_col_40};

    // Calculate character row (same for both modes)
    // Each character is 16 pixels tall (screen_row = v_count / 16)
    wire [4:0] screen_row = v_count[9:4];  // Divide by 16 (shift right 4 bits)

    // Calculate physical row in circular buffer
    // physical_row = (screen_row + top_line) % 30
    wire [5:0] row_sum = {1'b0, screen_row} + {1'b0, top_line};  // 6-bit to handle overflow
    wire [4:0] physical_row = (row_sum >= 6'd25) ? (row_sum - 6'd25) : row_sum[4:0];

    // Calculate character buffer address using physical row
    // 40-col: address = row * 40 + col = row * 32 + row * 8 + col
    // 80-col: address = row * 80 + col = row * 64 + row * 16 + col
    wire [11:0] char_addr_40 = {physical_row, 5'b0} + {physical_row, 3'b0} + {5'b0, char_col_40};
    wire [11:0] char_addr_80 = {physical_row, 6'b0} + {physical_row, 4'b0} + {4'b0, char_col_80};

    // Select character address based on mode
    assign char_addr = mode_80col ? char_addr_80 : char_addr_40;

    // Calculate scanline within character (0-15)
    wire [3:0] char_scanline = v_count[3:0];  // Lower 4 bits of v_count

    //==========================================================================
    // Pipeline Stage 2: Character Buffer Read (Registered)
    //==========================================================================

    // Pipeline registers for stage 2
    reg [9:0]  h_count_d1;
    reg [9:0]  v_count_d1;
    reg        video_active_d1;
    reg        mode_80col_d1;
    reg [3:0]  char_scanline_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count_d1      <= 0;
            v_count_d1      <= 0;
            video_active_d1 <= 0;
            mode_80col_d1   <= 0;
            char_scanline_d1 <= 0;
        end else begin
            h_count_d1      <= h_count;
            v_count_d1      <= v_count;
            video_active_d1 <= video_active;
            mode_80col_d1   <= mode_80col;
            char_scanline_d1 <= char_scanline;
        end
    end

    // Extract fields from 16-bit cell data
    wire [7:0] cell_char = char_data[7:0];
    wire [3:0] cell_fg   = char_data[11:8];
    wire [3:0] cell_bg   = char_data[15:12];

    // Font ROM inputs: character code comes from buffer (1 cycle delayed)
    assign font_char = cell_char;
    assign font_scanline = char_scanline_d1;

    //==========================================================================
    // Pipeline Stage 3: Font ROM Read (Registered)
    //==========================================================================

    // Pipeline registers for stage 3
    reg [9:0]  h_count_d2;
    reg [9:0]  v_count_d2;
    reg        video_active_d2;
    reg        mode_80col_d2;
    reg [3:0]  cell_fg_d2;
    reg [3:0]  cell_bg_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count_d2      <= 0;
            v_count_d2      <= 0;
            video_active_d2 <= 0;
            mode_80col_d2   <= 0;
            cell_fg_d2      <= 0;
            cell_bg_d2      <= 0;
        end else begin
            h_count_d2      <= h_count_d1;
            v_count_d2      <= v_count_d1;
            video_active_d2 <= video_active_d1;
            mode_80col_d2   <= mode_80col_d1;
            cell_fg_d2      <= cell_fg;     // Per-cell fg from buffer
            cell_bg_d2      <= cell_bg;     // Per-cell bg from buffer
        end
    end

    //==========================================================================
    // Pipeline Stage 4: Pixel Extraction and Color Application
    //==========================================================================

    // Calculate pixel position within character
    // 40-col: Each font pixel is displayed as 2 screen pixels (doubled horizontally)
    //         pixel_x = (h_count % 16) / 2 = h_count[3:1]
    // 80-col: Font pixels are displayed at native width
    //         pixel_x = h_count % 8 = h_count[2:0]

    wire [2:0] pixel_x_40 = h_count_d2[3:1];  // Divide by 2 for doubled pixels
    wire [2:0] pixel_x_80 = h_count_d2[2:0];  // Native pixel position
    wire [2:0] pixel_x = mode_80col_d2 ? pixel_x_80 : pixel_x_40;

    // Extract the specific pixel bit from font_pixels
    // Font data is MSB first: pixel 0 = bit 7, pixel 7 = bit 0
    wire [2:0] pixel_bit_index = 3'd7 - pixel_x;
    wire pixel_on = font_pixels[pixel_bit_index];

    //==========================================================================
    // Cursor Blink Logic
    //==========================================================================

    // Cursor blink counter: Blink every 30 frames @ 60 Hz = 2 Hz blink rate
    reg [5:0] cursor_blink_counter;  // 0-59 (counts frames)
    reg       cursor_blink_state;    // 0=off, 1=on
    reg       vsync_d1;               // Delayed vsync for edge detection

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cursor_blink_counter <= 6'd0;
            cursor_blink_state   <= 1'b1;  // Start visible
            vsync_d1             <= 1'b0;
        end else begin
            vsync_d1 <= vsync;

            // Detect rising edge of vsync (start of new frame)
            if (vsync && !vsync_d1) begin
                if (cursor_blink_counter >= 6'd29) begin
                    // Toggle blink state every 30 frames
                    cursor_blink_state   <= ~cursor_blink_state;
                    cursor_blink_counter <= 6'd0;
                end else begin
                    cursor_blink_counter <= cursor_blink_counter + 6'd1;
                end
            end
        end
    end

    //==========================================================================
    // Cursor Position Detection (Stage 2 - propagate to Stage 3)
    //==========================================================================

    // Check if current position matches cursor position
    // Need to compare screen row/col (not physical row)
    wire at_cursor_position = cursor_enable &&
                              (screen_row == cursor_row) &&
                              (char_col == cursor_col);

    // Register cursor match for pipeline Stage 3
    reg at_cursor_d1;
    reg at_cursor_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            at_cursor_d1 <= 1'b0;
            at_cursor_d2 <= 1'b0;
        end else begin
            at_cursor_d1 <= at_cursor_position;
            at_cursor_d2 <= at_cursor_d1;
        end
    end

    // Cursor is visible when enabled, blinking, and at cursor position
    wire cursor_visible = at_cursor_d2 && cursor_blink_state;

    // 4-bit IRGB to 8-bit color expansion (CGA-style 16 colors)
    // bit[3]=intensity, bit[2]=R, bit[1]=G, bit[0]=B
    // intensity=0: component = bit ? 0xAA : 0x00 (dark colors)
    // intensity=1: component = bit ? 0xFF : 0x55 (bright colors)
    wire [7:0] fg_r = cell_fg_d2[3] ? (cell_fg_d2[2] ? 8'hFF : 8'h55) : (cell_fg_d2[2] ? 8'hAA : 8'h00);
    wire [7:0] fg_g = cell_fg_d2[3] ? (cell_fg_d2[1] ? 8'hFF : 8'h55) : (cell_fg_d2[1] ? 8'hAA : 8'h00);
    wire [7:0] fg_b = cell_fg_d2[3] ? (cell_fg_d2[0] ? 8'hFF : 8'h55) : (cell_fg_d2[0] ? 8'hAA : 8'h00);

    wire [7:0] bg_r = cell_bg_d2[3] ? (cell_bg_d2[2] ? 8'hFF : 8'h55) : (cell_bg_d2[2] ? 8'hAA : 8'h00);
    wire [7:0] bg_g = cell_bg_d2[3] ? (cell_bg_d2[1] ? 8'hFF : 8'h55) : (cell_bg_d2[1] ? 8'hAA : 8'h00);
    wire [7:0] bg_b = cell_bg_d2[3] ? (cell_bg_d2[0] ? 8'hFF : 8'h55) : (cell_bg_d2[0] ? 8'hAA : 8'h00);

    // Select foreground or background color based on pixel value
    // When cursor is visible, invert the colors (swap FG/BG)
    wire [7:0] pixel_r = cursor_visible ? (pixel_on ? bg_r : fg_r) : (pixel_on ? fg_r : bg_r);
    wire [7:0] pixel_g = cursor_visible ? (pixel_on ? bg_g : fg_g) : (pixel_on ? fg_g : bg_g);
    wire [7:0] pixel_b = cursor_visible ? (pixel_on ? bg_b : fg_b) : (pixel_on ? fg_b : bg_b);

    // Output pixel color (black during blanking)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            red   <= 8'h00;
            green <= 8'h00;
            blue  <= 8'h00;
        end else begin
            if (video_active_d2) begin
                // Character rendering
                red   <= pixel_r;
                green <= pixel_g;
                blue  <= pixel_b;
            end else begin
                // Output black during blanking period
                red   <= 8'h00;
                green <= 8'h00;
                blue  <= 8'h00;
            end
        end
    end

endmodule
