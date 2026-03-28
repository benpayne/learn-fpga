//
// gpu_mux.v - Graphics/Character GPU Output Multiplexer
//
// Selects between character mode GPU and graphics mode GPU outputs
// based on DISPLAY_MODE register
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - Simple RGB888 multiplexer
// - Controlled by DISPLAY_MODE register (from graphics registers)
// - 0 = Character mode (from existing character GPU)
// - 1 = Graphics mode (from new graphics GPU)
// - Single-cycle combinational logic
//
// Design Note:
//   Both GPUs run simultaneously. This mux simply selects which output
//   drives the final RGB signals to the DVI transmitter. This allows
//   instant switching between text and graphics with no state loss.
//

module gpu_mux(
    // Display mode control
    input  wire        display_mode,       // 0=Character, 1=Graphics

    // Character GPU RGB inputs
    input  wire [7:0]  char_rgb_r,         // Character mode red
    input  wire [7:0]  char_rgb_g,         // Character mode green
    input  wire [7:0]  char_rgb_b,         // Character mode blue

    // Graphics GPU RGB inputs
    input  wire [7:0]  gfx_rgb_r,          // Graphics mode red
    input  wire [7:0]  gfx_rgb_g,          // Graphics mode green
    input  wire [7:0]  gfx_rgb_b,          // Graphics mode blue

    // Final RGB outputs (to DVI transmitter)
    output wire [7:0]  rgb_r_out,          // Selected red output
    output wire [7:0]  rgb_g_out,          // Selected green output
    output wire [7:0]  rgb_b_out           // Selected blue output
);

    //=========================================================================
    // RGB Multiplexer (Combinational)
    //=========================================================================

    // Simple 2:1 mux for each color channel
    // display_mode = 0 → character GPU output
    // display_mode = 1 → graphics GPU output

    assign rgb_r_out = display_mode ? gfx_rgb_r : char_rgb_r;
    assign rgb_g_out = display_mode ? gfx_rgb_g : char_rgb_g;
    assign rgb_b_out = display_mode ? gfx_rgb_b : char_rgb_b;

endmodule
