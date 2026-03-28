//
// gpu_graphics_vram.v - 32KB Dual-Port VRAM for Graphics Framebuffer
//
// Implements video RAM for bitmap graphics display with true dual-port access:
// - CPU write port: Synchronous writes on system clock (clk_cpu)
// - Video read port: Synchronous reads on pixel clock (clk_pixel)
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - 32KB capacity (4 pages × 8KB per page)
// - True dual-port with independent clock domains (clk_cpu, clk_pixel)
// - 15-bit address space ($0000-$7FFF)
// - Address wrapping at boundary ($7FFF + 1 → $0000)
// - Block RAM synthesis directive for ECP5 EBR inference
// - Single-cycle read latency (registered output)
//
// Memory Organization:
//   Page 0: $0000-$1FFF (8,000 bytes) - Framebuffer page 0
//   Page 1: $2000-$3FFF (8,000 bytes) - Framebuffer page 1
//   Page 2: $4000-$5FFF (8,000 bytes) - Framebuffer page 2
//   Page 3: $6000-$7FFF (8,000 bytes) - Framebuffer page 3
//
// Clock Domain Crossing:
//   This module handles two independent clock domains safely:
//   - clk_cpu: CPU clock for writes (e.g., 12.5-25 MHz)
//   - clk_pixel: VGA pixel clock for reads (25 MHz for 640x480@60Hz)
//   The dual-port block RAM handles synchronization naturally through
//   separate read and write ports with independent clocks.
//
// Synthesis Note:
//   The (* ram_style = "block" *) directive ensures Yosys infers ECP5 EBR
//   (Embedded Block RAM) rather than distributed RAM. This is critical for
//   achieving 32KB capacity efficiently.
//

`include "gpu_graphics_params.vh"

module gpu_graphics_vram(
    // CPU write port (system clock domain)
    input  wire        clk_cpu,        // CPU clock
    input  wire [14:0] addr_write,     // Write address (0-32767)
    input  wire [7:0]  data_write,     // Data to write
    input  wire        we,             // Write enable

    // Video read port (pixel clock domain)
    input  wire        clk_pixel,      // Pixel clock (25 MHz)
    input  wire [14:0] addr_read,      // Read address (0-32767)
    output reg  [7:0]  data_read       // Data read (registered, 1-cycle latency)
);

    //=========================================================================
    // VRAM Storage Array
    //=========================================================================

    // 32KB dual-port RAM with block RAM synthesis directive
    // Ensures Yosys synthesizes this as ECP5 block RAM (EBR) for efficiency
    (* ram_style = "block" *)
    reg [7:0] vram_mem [0:32767];

    //=========================================================================
    // CPU Write Port Logic (clk_cpu domain)
    //=========================================================================

    // Synchronous write on CPU clock
    // Address wrapping is handled by 15-bit address (naturally wraps at 32768)
    always @(posedge clk_cpu) begin
        if (we) begin
            vram_mem[addr_write] <= data_write;
        end
    end

    //=========================================================================
    // Video Read Port Logic (clk_pixel domain)
    //=========================================================================

    // Synchronous read on pixel clock with registered output
    // This creates a 1-cycle read latency but ensures clean timing
    always @(posedge clk_pixel) begin
        data_read <= vram_mem[addr_read];
    end

    //=========================================================================
    // Memory Initialization (for simulation/debugging)
    //=========================================================================

    // Initialize VRAM to all zeros (black pixels in all modes)
    // This helps with debugging and ensures deterministic behavior
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) begin
            vram_mem[i] = 8'h00;
        end
    end

endmodule
