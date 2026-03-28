//
// gpu_graphics_palette.v - 16-Entry RGB444 Color Palette (CLUT)
//
// Implements Color Lookup Table for graphics GPU with RGB444 format
// and expansion to RGB888 for DVI output.
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - 16 palette entries (indices 0-15)
// - RGB444 format (4 bits per component = 4,096 possible colors)
// - RGB888 expansion using bit duplication for smooth gradients
// - CPU write interface for palette programming
// - Pixel lookup interface for renderer
// - Default grayscale ramp on reset
//
// Color Expansion:
//   RGB444 → RGB888 using bit duplication:
//   Example: R=0xA (1010) → 0xAA (10101010)
//   This provides full 0-255 range with uniform steps (0,17,34,...,255)
//
// Palette Usage by Mode:
//   1 BPP: Not used (monochrome or fixed colors)
//   2 BPP: Uses entries 0-3 (4 colors)
//   4 BPP: Uses entries 0-15 (16 colors)
//

`include "gpu_graphics_params.vh"

module gpu_graphics_palette(
    input  wire        clk,            // System clock
    input  wire        rst_n,          // Active-low reset

    // CPU palette programming interface
    input  wire [3:0]  clut_index,     // Palette entry index (0-15)
    input  wire [3:0]  clut_data_r,    // Red component (4 bits)
    input  wire [3:0]  clut_data_g,    // Green component (4 bits)
    input  wire [3:0]  clut_data_b,    // Blue component (4 bits)
    input  wire        clut_we,        // Write enable

    // Pixel rendering interface (lookup)
    input  wire [3:0]  pixel_index,    // Pixel palette index (0-15)
    output wire [7:0]  rgb_r_out,      // Red output (8 bits, expanded)
    output wire [7:0]  rgb_g_out,      // Green output (8 bits, expanded)
    output wire [7:0]  rgb_b_out       // Blue output (8 bits, expanded)
);

    //=========================================================================
    // Palette Storage
    //=========================================================================

    // 16 entries × 3 components (R, G, B) × 4 bits each
    reg [3:0] palette_r [0:15];  // Red components
    reg [3:0] palette_g [0:15];  // Green components
    reg [3:0] palette_b [0:15];  // Blue components

    //=========================================================================
    // CPU Write Port (Palette Programming)
    //=========================================================================

    // Synchronous write to palette entry selected by clut_index
    // Using synchronous reset to avoid edge-sensitive event issues
    // Initial values will be undefined, but CPU should program palette before use
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            // Initialize to default grayscale ramp on reset
            // Entry N: R=N, G=N, B=N (0=black, 15=white)
            for (i = 0; i < 16; i = i + 1) begin
                palette_r[i] <= i[3:0];
                palette_g[i] <= i[3:0];
                palette_b[i] <= i[3:0];
            end
        end else if (clut_we) begin
            // Write to selected palette entry (index masked to 4 bits)
            palette_r[clut_index] <= clut_data_r;
            palette_g[clut_index] <= clut_data_g;
            palette_b[clut_index] <= clut_data_b;
        end
    end

    //=========================================================================
    // Pixel Lookup (Combinational)
    //=========================================================================

    // Look up palette entry for pixel rendering
    // pixel_index is masked to 4 bits to handle invalid indices
    wire [3:0] safe_pixel_index = pixel_index & 4'hF;  // Mask to 0-15

    wire [3:0] palette_r_val = palette_r[safe_pixel_index];
    wire [3:0] palette_g_val = palette_g[safe_pixel_index];
    wire [3:0] palette_b_val = palette_b[safe_pixel_index];

    //=========================================================================
    // RGB444 → RGB888 Expansion (Bit Duplication)
    //=========================================================================

    // Expand 4-bit color components to 8-bit by duplicating bits
    // This gives uniform distribution from 0x00 to 0xFF with no gaps
    // Example: 4'hA (1010) → 8'hAA (10101010)
    assign rgb_r_out = {palette_r_val, palette_r_val};
    assign rgb_g_out = {palette_g_val, palette_g_val};
    assign rgb_b_out = {palette_b_val, palette_b_val};

endmodule
