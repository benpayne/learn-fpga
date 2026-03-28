//
// gpu_graphics_core.v - Graphics GPU Top-Level Integration
//
// Integrates all graphics GPU components: VRAM, palette, registers, pixel renderer
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - Complete bitmap graphics subsystem
// - CPU register interface at base address 0xC100
// - 32KB VRAM with dual-port access
// - 16-entry RGB444 color palette
// - Three graphics modes: 1 BPP, 2 BPP, 4 BPP
// - Burst write mode for efficient transfers
// - VBlank interrupt generation with clock domain crossing
// - Page flipping support
//
// Integration:
//   This module instantiates and connects:
//   - gpu_graphics_vram (32KB block RAM)
//   - gpu_graphics_palette (16-entry CLUT)
//   - gpu_graphics_registers (CPU interface)
//   - gpu_pixel_renderer (pixel fetch and decode)
//

`include "gpu_graphics_params.vh"

module gpu_graphics_core(
    // Clock and reset
    input  wire        clk_cpu,        // CPU clock domain
    input  wire        clk_pixel,      // Pixel clock domain (25 MHz VGA)
    input  wire        rst_n,          // Active-low reset

    // CPU register bus interface (base 0xC100)
    input  wire [3:0]  reg_addr,       // Register offset (0x0-0xF)
    input  wire [7:0]  reg_data_in,    // Write data
    input  wire        reg_we,         // Write enable
    input  wire        reg_re,         // Read enable
    output wire [7:0]  reg_data_out,   // Read data

    // VGA timing inputs (from vga_timing_generator)
    input  wire [9:0]  h_count,        // Horizontal counter
    input  wire [9:0]  v_count,        // Vertical counter
    input  wire        hsync,          // Horizontal sync
    input  wire        vsync,          // Vertical sync
    input  wire        video_active,   // Visible region flag

    // RGB output (to display mux)
    output wire [7:0]  rgb_r_out,      // Red component (8-bit)
    output wire [7:0]  rgb_g_out,      // Green component (8-bit)
    output wire [7:0]  rgb_b_out,      // Blue component (8-bit)

    // Control outputs
    output wire        display_mode,   // 0=Character, 1=Graphics
    output wire        gpu_irq         // VBlank interrupt output
);

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // VRAM interface
    wire [14:0] vram_addr_write;       // CPU write address
    wire [7:0]  vram_data_write;       // CPU write data
    wire        vram_we;               // CPU write enable
    wire [14:0] vram_addr_read;        // Video read address
    wire [7:0]  vram_data_read;        // Video read data

    // Palette interface
    wire [3:0]  clut_index;            // Palette entry index for programming
    wire [3:0]  clut_data_r;           // Red component for programming
    wire [3:0]  clut_data_g;           // Green component for programming
    wire [3:0]  clut_data_b;           // Blue component for programming
    wire        clut_we;               // Palette write enable
    wire [3:0]  pixel_palette_index;   // Palette index for pixel lookup

    // Graphics control
    wire [14:0] fb_base_addr;          // Framebuffer base address
    wire [1:0]  gpu_mode;              // Graphics mode
    wire        vblank_flag;           // VBlank status from timing

    // VBlank interrupt control
    wire        gpu_irq_enable;        // VBlank interrupt enable from registers
    wire        pixel_valid;           // Pixel in visible region

    //=========================================================================
    // VBlank Signal Generation and Clock Domain Crossing
    //=========================================================================

    // Generate VBlank flag from vsync signal
    // VBlank is active during vertical retrace period
    assign vblank_flag = vsync;

    // Synchronize VBlank to CPU clock domain using dual-flop synchronizer
    // This prevents metastability when crossing clock domains
    reg vblank_sync1, vblank_sync2;

    always @(posedge clk_cpu) begin
        if (!rst_n) begin
            vblank_sync1 <= 1'b0;
            vblank_sync2 <= 1'b0;
        end else begin
            vblank_sync1 <= vblank_flag;        // First flop
            vblank_sync2 <= vblank_sync1;       // Second flop (synchronized output)
        end
    end

    // Edge detection for VBlank interrupt (rising edge generates pulse)
    reg vblank_prev;
    wire vblank_edge;

    always @(posedge clk_cpu) begin
        if (!rst_n) begin
            vblank_prev <= 1'b0;
        end else begin
            vblank_prev <= vblank_sync2;
        end
    end

    // Generate one-cycle interrupt pulse on VBlank rising edge
    assign vblank_edge = vblank_sync2 && !vblank_prev;

    // VBlank interrupt output (gated by enable bit)
    assign gpu_irq = vblank_edge && gpu_irq_enable;

    //=========================================================================
    // Module Instantiations
    //=========================================================================

    // VRAM Module (32KB dual-port block RAM)
    gpu_graphics_vram vram_inst (
        .clk_cpu       (clk_cpu),
        .addr_write    (vram_addr_write),
        .data_write    (vram_data_write),
        .we            (vram_we),

        .clk_pixel     (clk_pixel),
        .addr_read     (vram_addr_read),
        .data_read     (vram_data_read)
    );

    // Palette Module (16-entry RGB444 CLUT)
    gpu_graphics_palette palette_inst (
        .clk           (clk_cpu),
        .rst_n         (rst_n),

        .clut_index    (clut_index),
        .clut_data_r   (clut_data_r),
        .clut_data_g   (clut_data_g),
        .clut_data_b   (clut_data_b),
        .clut_we       (clut_we),

        .pixel_index   (pixel_palette_index),
        .rgb_r_out     (rgb_r_out),
        .rgb_g_out     (rgb_g_out),
        .rgb_b_out     (rgb_b_out)
    );

    // Graphics Registers Module (CPU interface)
    gpu_graphics_registers registers_inst (
        .clk_cpu       (clk_cpu),
        .rst_n         (rst_n),

        .reg_addr      (reg_addr),
        .reg_data_in   (reg_data_in),
        .reg_we        (reg_we),
        .reg_re        (reg_re),
        .reg_data_out  (reg_data_out),

        .vram_addr     (vram_addr_write),
        .vram_data_out (vram_data_write),
        .vram_data_in  (vram_data_read),
        .vram_we       (vram_we),

        .clut_index    (clut_index),
        .clut_data_r   (clut_data_r),
        .clut_data_g   (clut_data_g),
        .clut_data_b   (clut_data_b),
        .clut_we       (clut_we),

        .fb_base_addr  (fb_base_addr),
        .gpu_mode      (gpu_mode),
        .display_mode  (display_mode),

        .vblank_flag   (vblank_sync2),      // Synchronized VBlank status
        .gpu_irq_enable(gpu_irq_enable)
    );

    // Pixel Renderer Module (pixel fetch and decode)
    gpu_pixel_renderer renderer_inst (
        .clk_pixel          (clk_pixel),
        .rst_n              (rst_n),

        .h_count            (h_count),
        .v_count            (v_count),
        .video_active       (video_active),

        .gpu_mode           (gpu_mode),
        .fb_base_addr       (fb_base_addr),

        .vram_addr          (vram_addr_read),
        .vram_data          (vram_data_read),

        .pixel_palette_index(pixel_palette_index),
        .pixel_valid        (pixel_valid)
    );

endmodule
