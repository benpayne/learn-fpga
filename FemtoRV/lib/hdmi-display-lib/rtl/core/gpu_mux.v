// gpu_mux.v - GPU Output Multiplexer (3-mode)
//
// Selects between character, bitmap graphics, and scanline graphics modes
// based on DISPLAY_MODE register (2-bit):
//   0 = Character mode (text)
//   1 = Bitmap graphics mode (1/2/4 BPP VRAM)
//   2 = Scanline hi-res mode (8bpp line buffer)

module gpu_mux(
    // Display mode control
    input  wire [1:0]  display_mode,       // 0=Char, 1=Bitmap, 2=Scanline

    // Character GPU RGB inputs
    input  wire [7:0]  char_rgb_r,
    input  wire [7:0]  char_rgb_g,
    input  wire [7:0]  char_rgb_b,

    // Bitmap Graphics GPU RGB inputs
    input  wire [7:0]  gfx_rgb_r,
    input  wire [7:0]  gfx_rgb_g,
    input  wire [7:0]  gfx_rgb_b,

    // Scanline GPU RGB inputs
    input  wire [7:0]  scan_rgb_r,
    input  wire [7:0]  scan_rgb_g,
    input  wire [7:0]  scan_rgb_b,

    // Final RGB outputs (to DVI transmitter)
    output reg  [7:0]  rgb_r_out,
    output reg  [7:0]  rgb_g_out,
    output reg  [7:0]  rgb_b_out
);

    always @(*) begin
        case (display_mode)
            2'd0: begin // Character mode
                rgb_r_out = char_rgb_r;
                rgb_g_out = char_rgb_g;
                rgb_b_out = char_rgb_b;
            end
            2'd1: begin // Bitmap graphics
                rgb_r_out = gfx_rgb_r;
                rgb_g_out = gfx_rgb_g;
                rgb_b_out = gfx_rgb_b;
            end
            2'd2: begin // Scanline hi-res
                rgb_r_out = scan_rgb_r;
                rgb_g_out = scan_rgb_g;
                rgb_b_out = scan_rgb_b;
            end
            default: begin
                rgb_r_out = char_rgb_r;
                rgb_g_out = char_rgb_g;
                rgb_b_out = char_rgb_b;
            end
        endcase
    end

endmodule
