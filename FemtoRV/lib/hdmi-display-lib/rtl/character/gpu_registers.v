//
// gpu_registers.v - Memory-Mapped Register Interface for DVI Character Display GPU
//
// Implements CPU-accessible control and status registers for the text mode GPU
//
// Author: RetroCPU Project
// License: MIT
//
// Features:
// - 7 memory-mapped registers (0xC010-0xC016) for GPU control
// - Character output with automatic cursor advance, line wrap, and scroll
// - Cursor position control (row/column)
// - Display mode control (40-column / 80-column)
// - Foreground and background color control (3-bit RGB)
// - Screen clear command
// - Status register (GPU ready, VSYNC)
// - Direct interface to character buffer for fast writes
//
// Register Map (Base Address: 0xC010-0xC016):
//   0xC010 (offset 0x0): CHAR_DATA (WO) - Write character at cursor, auto-advance
//   0xC011 (offset 0x1): CURSOR_ROW (RW) - Cursor row position (0-29)
//   0xC012 (offset 0x2): CURSOR_COL (RW) - Cursor column position (0-39 or 0-79)
//   0xC013 (offset 0x3): CONTROL (WO) - bit[0]=CLEAR, bit[1]=MODE, bit[2]=CURSOR_EN
//   0xC014 (offset 0x4): FG_COLOR (RW) - Foreground color (3-bit RGB)
//   0xC015 (offset 0x5): BG_COLOR (RW) - Background color (3-bit RGB)
//   0xC016 (offset 0x6): STATUS (RO) - bit[0]=READY, bit[1]=VSYNC
//
// Reset Values:
//   CURSOR_ROW: 0x00, CURSOR_COL: 0x00
//   CONTROL: 0x04 (40-column mode, cursor enabled)
//   FG_COLOR: 0x07 (white), BG_COLOR: 0x00 (black)
//
// Cursor Auto-Advance Behavior:
//   1. Character write increments column
//   2. At end of line (col == max_col), wrap to start of next line
//   3. At last row (row == 29) and end of line, trigger scroll and stay at row 29
//
// Mode Switching:
//   Changing MODE bit (bit 1 of CONTROL) triggers automatic screen clear
//   and cursor reset to (0,0)
//
// Reference: specs/003-hdmi-character-display/contracts/register_map.md
//

module gpu_registers(
    input  wire        clk,             // System clock (CPU clock domain)
    input  wire        rst_n,           // Active-low reset

    // CPU bus interface
    input  wire [3:0]  addr,            // Register offset (0x0-0xF)
    input  wire [7:0]  data_in,         // Data from CPU
    output reg  [7:0]  data_out,        // Data to CPU
    input  wire        we,              // Write enable
    input  wire        re,              // Read enable

    // Control outputs (to GPU core)
    output reg  [4:0]  cursor_row,      // 0-29 (5 bits)
    output reg  [6:0]  cursor_col,      // 0-39 or 0-79 (7 bits)
    output reg         mode_80col,      // 0=40-column, 1=80-column
    output reg         cursor_enable,   // Cursor visibility
    output reg  [3:0]  fg_color,        // Foreground color (4-bit IRGB)
    output reg  [3:0]  bg_color,        // Background color (4-bit IRGB)
    output reg         clear_screen,    // Pulse when clear requested
    output reg         scroll_screen,   // Pulse when scroll requested
    output reg  [4:0]  top_line,        // Circular buffer: which physical line is at screen row 0

    // Status inputs (from GPU core)
    input  wire        gpu_ready,       // GPU ready for commands
    input  wire        vsync,           // Vertical sync signal

    // Character buffer write interface
    output reg  [11:0] char_buf_addr,   // Address to write in character buffer
    output reg  [15:0] char_buf_data,   // {bg[3:0], fg[3:0], char[7:0]}
    output reg         char_buf_we      // Write enable to character buffer
);

    // Register addresses
    localparam ADDR_CHAR_DATA   = 4'h0;
    localparam ADDR_CURSOR_ROW  = 4'h1;
    localparam ADDR_CURSOR_COL  = 4'h2;
    localparam ADDR_CONTROL     = 4'h3;
    localparam ADDR_FG_COLOR    = 4'h4;
    localparam ADDR_BG_COLOR    = 4'h5;
    localparam ADDR_STATUS      = 4'h6;

    // Control register bits
    localparam CTRL_CLEAR       = 0;
    localparam CTRL_MODE        = 1;
    localparam CTRL_CURSOR_EN   = 2;

    // Internal registers
    reg        mode_80col_prev;         // Previous mode for change detection

    // State machine for scroll and clear operations
    localparam STATE_IDLE          = 2'b00;
    localparam STATE_CLEARING_LINE = 2'b01;  // Clearing one line after scroll
    localparam STATE_CLEARING_ALL  = 2'b10;  // Clearing entire screen
    reg [1:0]  state;
    reg [11:0] clear_counter;           // Counter for clearing (0-2399)

    // Maximum column based on current mode
    wire [6:0] max_col = mode_80col ? 7'd79 : 7'd39;

    // Maximum buffer address based on mode (for full clear)
    wire [11:0] max_addr = mode_80col ? 12'd1999 : 12'd999;  // 25 rows

    // Calculate physical row in circular buffer from cursor screen row
    // physical_row = (cursor_row + top_line) % 30
    wire [5:0] cursor_row_sum = {1'b0, cursor_row} + {1'b0, top_line};
    wire [4:0] cursor_physical_row = (cursor_row_sum >= 6'd25) ? (cursor_row_sum - 6'd25) : cursor_row_sum[4:0];

    // Calculate character buffer address from cursor position
    // Address = physical_row * columns + col
    wire [11:0] cursor_buffer_addr = mode_80col ?
                                     ({7'b0, cursor_physical_row} * 12'd80) + {5'b0, cursor_col} :
                                     ({7'b0, cursor_physical_row} * 12'd40) + {5'b0, cursor_col};

    // Bottom line in circular buffer = (top_line - 1 + 30) % 30
    wire [4:0] bottom_line = (top_line >= 5'd1) ? (top_line - 5'd1) : 5'd24;

    // Address for clearing one line (after scroll) or entire screen
    wire [11:0] line_clear_addr = mode_80col ?
                                  ({7'b0, bottom_line} * 12'd80) + {5'b0, clear_counter[6:0]} :
                                  ({7'b0, bottom_line} * 12'd40) + {5'b0, clear_counter[6:0]};

    // Reset and register write logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all registers to default values
            cursor_row      <= 5'd0;
            cursor_col      <= 7'd0;
            mode_80col      <= 1'b0;        // 40-column mode
            cursor_enable   <= 1'b1;        // Cursor enabled
            fg_color        <= 4'b1111;     // Bright white (IRGB=1111)
            bg_color        <= 4'b0000;     // Black (IRGB=0000)
            clear_screen    <= 1'b0;
            scroll_screen   <= 1'b0;
            top_line        <= 5'd0;        // Start at physical line 0
            char_buf_we     <= 1'b0;
            char_buf_addr   <= 12'd0;
            char_buf_data   <= 16'd0;
            mode_80col_prev <= 1'b0;
            state           <= STATE_IDLE;
            clear_counter   <= 12'd0;
        end else begin
            // Default: clear one-shot signals
            clear_screen    <= 1'b0;
            scroll_screen   <= 1'b0;
            char_buf_we     <= 1'b0;

            // Track mode changes
            mode_80col_prev <= mode_80col;

            // State machine - handles scroll and clear operations
            case (state)
                STATE_IDLE: begin
                    // Wait for scroll or clear trigger
                    if (clear_screen) begin
                        // Start clearing entire screen
                        clear_counter <= 12'd0;
                        top_line <= 5'd0;  // Reset circular buffer
                        state <= STATE_CLEARING_ALL;
                    end else if (scroll_screen) begin
                        // Increment top_line with wraparound
                        top_line <= (top_line == 5'd24) ? 5'd0 : top_line + 5'd1;
                        // Start clearing the new bottom line
                        clear_counter <= 12'd0;
                        state <= STATE_CLEARING_LINE;
                    end
                end

                STATE_CLEARING_LINE: begin
                    // Clear one line (after scroll) with current colors
                    char_buf_addr <= line_clear_addr;
                    char_buf_data <= {bg_color, fg_color, 8'h20};
                    char_buf_we   <= 1'b1;

                    // Increment counter
                    clear_counter <= clear_counter + 12'd1;

                    // Check if done clearing line
                    if (clear_counter[6:0] >= max_col) begin
                        state <= STATE_IDLE;
                    end
                end

                STATE_CLEARING_ALL: begin
                    // Clear entire screen with current colors
                    char_buf_addr <= clear_counter;
                    char_buf_data <= {bg_color, fg_color, 8'h20};
                    char_buf_we   <= 1'b1;

                    // Increment counter
                    clear_counter <= clear_counter + 12'd1;

                    // Check if done clearing all
                    if (clear_counter >= max_addr) begin
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase

            // Handle CPU register writes
            if (we && state == STATE_IDLE) begin  // Only allow writes when not busy
                case (addr)
                    // 0xC010: CHAR_DATA - Write character and auto-advance cursor
                    ADDR_CHAR_DATA: begin
                        // Handle control characters
                        if (data_in == 8'h0D) begin
                            // CR (Carriage Return): Move cursor to column 0
                            cursor_col <= 7'd0;
                            char_buf_we <= 1'b0;  // Don't write CR to buffer
                        end else if (data_in == 8'h0A) begin
                            // LF (Line Feed): Move to next row
                            if (cursor_row < 5'd24) begin
                                cursor_row <= cursor_row + 5'd1;
                            end else begin
                                // At last row: trigger scroll and stay at row 29
                                scroll_screen <= 1'b1;
                                cursor_row <= 5'd24;
                            end
                            char_buf_we <= 1'b0;  // Don't write LF to buffer
                        end else begin
                            // Normal printable character: Write to buffer and auto-advance
                            char_buf_addr <= cursor_buffer_addr;
                            char_buf_data <= {bg_color, fg_color, data_in};
                            char_buf_we   <= 1'b1;

                            // Auto-advance cursor
                            if (cursor_col < max_col) begin
                                // Normal advance: increment column
                                cursor_col <= cursor_col + 7'd1;
                            end else begin
                                // End of line: wrap to start of next line
                                cursor_col <= 7'd0;
                                if (cursor_row < 5'd24) begin
                                    // Not at last row: advance to next row
                                    cursor_row <= cursor_row + 5'd1;
                                end else begin
                                    // At last row: trigger scroll and stay at row 29
                                    scroll_screen <= 1'b1;
                                    cursor_row <= 5'd24;
                                end
                            end
                        end
                    end

                    // 0xC011: CURSOR_ROW - Set cursor row (clamp to 0-29)
                    ADDR_CURSOR_ROW: begin
                        if (data_in[4:0] <= 5'd24)
                            cursor_row <= data_in[4:0];
                        else
                            cursor_row <= 5'd24;  // Clamp to max row
                    end

                    // 0xC012: CURSOR_COL - Set cursor column (clamp based on mode)
                    ADDR_CURSOR_COL: begin
                        if (data_in[6:0] <= max_col)
                            cursor_col <= data_in[6:0];
                        else
                            cursor_col <= max_col;  // Clamp to max column
                    end

                    // 0xC013: CONTROL - Display mode, clear, cursor enable
                    ADDR_CONTROL: begin
                        // Bit 0: CLEAR - Trigger screen clear (self-clearing pulse)
                        if (data_in[CTRL_CLEAR]) begin
                            clear_screen <= 1'b1;
                            cursor_row   <= 5'd0;
                            cursor_col   <= 7'd0;
                        end

                        // Bit 1: MODE - Set display mode (40-col / 80-col)
                        // Mode change triggers automatic clear and cursor reset
                        if (data_in[CTRL_MODE] != mode_80col) begin
                            mode_80col   <= data_in[CTRL_MODE];
                            clear_screen <= 1'b1;
                            cursor_row   <= 5'd0;
                            cursor_col   <= 7'd0;
                        end

                        // Bit 2: CURSOR_EN - Cursor visibility
                        cursor_enable <= data_in[CTRL_CURSOR_EN];
                    end

                    // 0xC014: FG_COLOR - Foreground color (mask to 3 bits)
                    ADDR_FG_COLOR: begin
                        fg_color <= data_in[3:0];
                    end

                    // 0xC015: BG_COLOR - Background color (mask to 4 bits)
                    ADDR_BG_COLOR: begin
                        bg_color <= data_in[3:0];
                    end

                    // Other addresses: write ignored
                    default: begin
                        // No action
                    end
                endcase
            end
        end
    end

    // Register read logic
    always @(*) begin
        if (re) begin
            case (addr)
                // 0xC011: CURSOR_ROW - Read cursor row (bits 4:0)
                ADDR_CURSOR_ROW: begin
                    data_out = {3'b000, cursor_row};
                end

                // 0xC012: CURSOR_COL - Read cursor column (bits 6:0)
                ADDR_CURSOR_COL: begin
                    data_out = {1'b0, cursor_col};
                end

                // 0xC014: FG_COLOR - Read foreground color (bits 2:0)
                ADDR_FG_COLOR: begin
                    data_out = {4'b0000, fg_color};
                end

                // 0xC015: BG_COLOR - Read background color (bits 3:0)
                ADDR_BG_COLOR: begin
                    data_out = {4'b0000, bg_color};
                end

                // 0xC016: STATUS - Read GPU status
                ADDR_STATUS: begin
                    data_out = {6'b000000, vsync, gpu_ready};
                end

                // Other addresses: read as 0x00
                default: begin
                    data_out = 8'h00;
                end
            endcase
        end else begin
            data_out = 8'h00;
        end
    end

endmodule
