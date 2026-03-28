//==============================================================================
// font_rom.v - Font ROM for Character Display GPU
//==============================================================================
// Project: RetroCPU - DVI Character Display GPU
// Description: ROM containing 8x16 pixel font bitmaps for ASCII characters
//
// Font Data:
//   - 8x16 pixel bitmap font (8 pixels wide, 16 rows tall)
//   - Covers printable ASCII characters 0x20-0x7E (96 characters)
//   - Each character is 16 bytes (1 byte per scanline)
//   - Total ROM size: 96 chars × 16 bytes = 1536 bytes
//
// Character Handling:
//   - Printable ASCII (0x20-0x7E): Display from font ROM
//   - Non-printable (0x00-0x1F, 0x7F, 0x80-0xFF): Solid block placeholder
//
// Timing:
//   - Synchronous read (registered output for better FPGA timing)
//   - 1 clock cycle latency
//
// Memory Layout:
//   ROM Address = (char_code - 0x20) * 16 + scanline
//   - Offset by 0x20 to align printable ASCII characters
//   - Multiply by 16 bytes per character
//   - Add scanline (0-15) for specific row within character
//
//==============================================================================

module font_rom(
    input  wire        clk,             // Pixel clock
    input  wire [7:0]  char_code,       // ASCII character code (0-255)
    input  wire [3:0]  scanline,        // Scanline within character (0-15)
    output reg  [7:0]  pixel_row        // 8 pixels for this scanline (1=fg, 0=bg)
);

    //==========================================================================
    // Font ROM Storage
    //==========================================================================

    // ROM array: 1536 bytes (96 characters × 16 bytes/char)
    reg [7:0] rom_data [0:1535];

    // Load font data from hex file on initialization
    initial begin
        $readmemh("font_data.hex", rom_data);
    end

    //==========================================================================
    // Character Classification
    //==========================================================================

    // Printable ASCII range: 0x20 (' ') to 0x7E ('~')
    wire is_printable = (char_code >= 8'h20) && (char_code <= 8'h7E);

    // Placeholder glyph for non-printable characters (solid block)
    wire [7:0] placeholder = 8'hFF;  // All pixels on

    //==========================================================================
    // ROM Address Calculation
    //==========================================================================

    // Calculate ROM address for printable characters
    // Address = (char_code - 0x20) * 16 + scanline
    //
    // Example: Character 'A' (0x41) at scanline 5:
    //   char_offset = 0x41 - 0x20 = 0x21 (33 decimal)
    //   address = 33 * 16 + 5 = 528 + 5 = 533
    wire [7:0] char_offset = char_code - 8'h20;
    wire [10:0] rom_address = {char_offset, 4'b0000} + {7'b0, scanline};

    // Note: {char_offset, 4'b0000} is equivalent to char_offset * 16
    // This uses bit shifting instead of multiplication for efficiency

    //==========================================================================
    // Synchronous ROM Read
    //==========================================================================

    // Read from ROM on clock edge (registered output for better timing)
    always @(posedge clk) begin
        if (is_printable) begin
            // Printable character: read from ROM
            pixel_row <= rom_data[rom_address];
        end else begin
            // Non-printable character: display placeholder (solid block)
            pixel_row <= placeholder;
        end
    end

endmodule
