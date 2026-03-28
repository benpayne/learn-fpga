//
// character_buffer.v - Dual-Port Character RAM for Text Display
//
// Implements character storage for 80x30 text mode display
//
// Author: RetroCPU Project
// License: MIT
//
// Features:
// - True dual-port block RAM with independent clock domains
// - CPU write port: Synchronous writes on system clock (clk_cpu)
// - Video read port: Synchronous reads on pixel clock (clk_video)
// - Supports 40x30 mode (1200 bytes) and 80x30 mode (2400 bytes)
// - Stores 8-bit ASCII character codes
// - Initialized to 0x20 (space) for blank screen on startup
// - Infers ECP5 EBR (Embedded Block RAM) for efficient implementation
//
// Memory Organization:
//   Address 0-1199: 40-column mode (40 columns x 30 rows)
//   Address 0-2399: 80-column mode (80 columns x 30 rows)
//   Each location: 8-bit ASCII character code
//
// Clock Domain Crossing:
//   This module handles two independent clock domains:
//   - clk_cpu: System clock for CPU writes (e.g., 25 MHz)
//   - clk_video: Pixel clock for video reads (e.g., 25.175 MHz for 640x480)
//   The dual-port RAM handles synchronization naturally through block RAM.
//

module character_buffer(
    // CPU write port (system clock domain)
    input  wire        clk_cpu,
    input  wire [11:0] addr_write,      // Address 0-1199 (40-col) or 0-2399 (80-col)
    input  wire [15:0] data_write,      // {bg[3:0], fg[3:0], char[7:0]}
    input  wire        we,              // Write enable

    // Video read port (pixel clock domain)
    input  wire        clk_video,
    input  wire [11:0] addr_read,       // Read address
    output reg  [15:0] data_read        // {bg[3:0], fg[3:0], char[7:0]}
);

    // Character buffer memory - 2400 bytes to support 80x30 mode
    // Synthesis directive to ensure block RAM inference
    (* ram_style = "block" *)
    reg [15:0] char_mem [0:2399];

    // CPU write port - synchronous write on clk_cpu
    always @(posedge clk_cpu) begin
        if (we) begin
            char_mem[addr_write] <= data_write;
        end
    end

    // Video read port - synchronous read on clk_video
    always @(posedge clk_video) begin
        data_read <= char_mem[addr_read];
    end

    // Initialize memory to spaces (0x20) for blank screen on startup
    // Also add "HELLO WORLD" test message at top-left
    integer i;
    initial begin
        for (i = 0; i < 2400; i = i + 1) begin
            char_mem[i] = 16'h0F20;  // White on black, space
        end
        // "HELLO WORLD" at row 0, column 0
        char_mem[0]  = 16'h0F48;  // 'H' bright white on black
        char_mem[1]  = 16'h0F45;  // 'E'
        char_mem[2]  = 16'h0F4C;  // 'L'
        char_mem[3]  = 16'h0F4C;  // 'L'
        char_mem[4]  = 16'h0F4F;  // 'O'
        char_mem[5]  = 16'h0F20;  // ' '
        char_mem[6]  = 16'h0F57;  // 'W'
        char_mem[7]  = 16'h0F4F;  // 'O'
        char_mem[8]  = 16'h0F52;  // 'R'
        char_mem[9]  = 16'h0F4C;  // 'L'
        char_mem[10] = 16'h0F44;  // 'D'
    end

endmodule
