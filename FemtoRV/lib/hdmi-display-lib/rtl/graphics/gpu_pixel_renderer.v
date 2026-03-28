//
// gpu_pixel_renderer.v - Graphics Pixel Renderer with Mode Decoding
//
// Decodes pixel data from VRAM based on graphics mode (1/2/4 BPP) and
// generates palette indices for color lookup.
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - Supports 3 graphics modes:
//   * 1 BPP: 320x200, 8 pixels per byte
//   * 2 BPP: 160x200, 4 pixels per byte → palette indices 0-3
//   * 4 BPP: 160x100, 2 pixels per byte → palette indices 0-15
// - Address calculation from h_count, v_count, FB_BASE_ADDR
// - Pixel extraction and palette index generation
// - Pipeline design for efficient pixel fetch
//
// Rendering Pipeline:
//   1. Calculate VRAM address from (x, y) position
//   2. Fetch VRAM byte (1-cycle latency from VRAM module)
//   3. Extract pixel bits based on mode
//   4. Output palette index for current pixel
//

`include "gpu_graphics_params.vh"

module gpu_pixel_renderer(
    input  wire        clk_pixel,          // Pixel clock (25 MHz)
    input  wire        rst_n,              // Active-low reset

    // VGA timing inputs
    input  wire [9:0]  h_count,            // Horizontal counter (0-799)
    input  wire [9:0]  v_count,            // Vertical counter (0-524)
    input  wire        video_active,       // Visible region flag

    // Graphics mode control
    input  wire [1:0]  gpu_mode,           // Graphics mode (00/01/10)
    input  wire [14:0] fb_base_addr,       // Framebuffer base address

    // VRAM read interface
    output reg  [14:0] vram_addr,          // VRAM address to read
    input  wire [7:0]  vram_data,          // VRAM data (registered, 1-cycle delay)

    // Pixel output
    output reg  [3:0]  pixel_palette_index, // Palette index for current pixel
    output reg         pixel_valid          // Pixel is valid (in visible region)
);

    //=========================================================================
    // Pixel Position Calculation
    //=========================================================================

    // Calculate pixel X, Y position scaled to graphics resolution
    // Display is 640x400, so scaling is simple power-of-2 divisions:
    // For 320-wide modes: x_pixel = h_count / 2 (each pixel doubled horizontally)
    // For 160-wide modes: x_pixel = h_count / 4 (each pixel quadrupled horizontally)
    // For 200-tall modes: y_pixel = v_count / 2 (each line doubled vertically)
    // For 100-tall modes: y_pixel = v_count / 4 (each line quadrupled vertically)

    reg [8:0] x_pixel;    // X coordinate in graphics space (0-319)
    reg [7:0] y_pixel;    // Y coordinate in graphics space (0-199)

    always @(*) begin
        case (gpu_mode)
            GPU_MODE_1BPP: begin
                // 320x200: h_count / 2, v_count / 2
                x_pixel = h_count[9:1];     // Bit shift right by 1 = divide by 2
                y_pixel = v_count[9:1];     // Bit shift right by 1 = divide by 2
            end
            GPU_MODE_2BPP: begin
                // 160x200: h_count / 4, v_count / 2
                x_pixel = h_count[9:2];     // Bit shift right by 2 = divide by 4
                y_pixel = v_count[9:1];     // Bit shift right by 1 = divide by 2
            end
            GPU_MODE_4BPP: begin
                // 160x100: h_count / 4, v_count / 4
                x_pixel = h_count[9:2];     // Bit shift right by 2 = divide by 4
                y_pixel = v_count[9:2];     // Bit shift right by 2 = divide by 4
            end
            default: begin
                x_pixel = 9'h000;
                y_pixel = 8'h00;
            end
        endcase
    end

    //=========================================================================
    // VRAM Address Calculation
    //=========================================================================

    // Calculate byte offset in framebuffer based on mode
    // During horizontal blanking (video_active=0), clamp x_pixel to 0 to
    // prime the pipeline with the first pixel of each line.
    reg [14:0] byte_offset;
    wire [8:0] x_pixel_clamped = video_active ? x_pixel : 9'd0;

    always @(*) begin
        case (gpu_mode)
            GPU_MODE_1BPP: begin
                // 1 BPP: 40 bytes per row, 8 pixels per byte
                byte_offset = (y_pixel * 40) + (x_pixel_clamped / 8);
            end
            GPU_MODE_2BPP: begin
                // 2 BPP: 40 bytes per row, 4 pixels per byte
                byte_offset = (y_pixel * 40) + (x_pixel_clamped / 4);
            end
            GPU_MODE_4BPP: begin
                // 4 BPP: 80 bytes per row, 2 pixels per byte
                byte_offset = (y_pixel * 80) + (x_pixel_clamped / 2);
            end
            default: begin
                byte_offset = 15'h0000;
            end
        endcase
    end

    // VRAM address = framebuffer base + byte offset
    // Calculate one cycle ahead for VRAM pipeline latency
    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            vram_addr <= 15'h0000;
        end else begin
            vram_addr <= fb_base_addr + byte_offset;
        end
    end

    //=========================================================================
    // Pixel Extraction and Palette Index Generation
    //=========================================================================

    // Delay x_pixel by 2 cycles to match VRAM pipeline latency
    // Pipeline:
    //   Cycle N:   x_pixel calculated, byte_offset calculated (combinational)
    //   Cycle N+1: vram_addr registered (address sent to VRAM)
    //   Cycle N+2: vram_data available (VRAM registered output)
    // So we need x_pixel delayed by 2 cycles to align with vram_data.
    reg [8:0] x_pixel_delay1;
    reg [8:0] x_pixel_delay2;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            x_pixel_delay1 <= 9'h000;
            x_pixel_delay2 <= 9'h000;
        end else begin
            x_pixel_delay1 <= x_pixel;
            x_pixel_delay2 <= x_pixel_delay1;
        end
    end

    // Extract pixel bits from VRAM byte based on X position within byte
    reg [2:0] pixel_in_byte;   // Which pixel within the byte (0-7 for 1BPP)
    reg [3:0] pixel_index;     // Extracted palette index

    always @(*) begin
        case (gpu_mode)
            GPU_MODE_1BPP: begin
                // 1 BPP: 8 pixels per byte, MSB = leftmost
                pixel_in_byte = x_pixel_delay2[2:0];                    // Low 3 bits (0-7)
                pixel_index = {3'b000, vram_data[7 - pixel_in_byte]};  // Extract bit
            end
            GPU_MODE_2BPP: begin
                // 2 BPP: 4 pixels per byte, 2 bits per pixel
                pixel_in_byte = {1'b0, x_pixel_delay2[1:0]};            // Low 2 bits (0-3)
                case (x_pixel_delay2[1:0])
                    2'b00: pixel_index = {2'b00, vram_data[7:6]};  // Pixel 0
                    2'b01: pixel_index = {2'b00, vram_data[5:4]};  // Pixel 1
                    2'b10: pixel_index = {2'b00, vram_data[3:2]};  // Pixel 2
                    2'b11: pixel_index = {2'b00, vram_data[1:0]};  // Pixel 3
                endcase
            end
            GPU_MODE_4BPP: begin
                // 4 BPP: 2 pixels per byte, 4 bits per pixel
                pixel_in_byte = {2'b00, x_pixel_delay2[0]};             // Low 1 bit (0-1)
                pixel_index = x_pixel_delay2[0] ? vram_data[3:0] : vram_data[7:4];
            end
            default: begin
                pixel_in_byte = 3'b000;
                pixel_index = 4'h0;
            end
        endcase
    end

    //=========================================================================
    // Output Pipeline
    //=========================================================================

    // Delay video_active to compensate for pixel pipeline latency:
    // - Cycle N:   x_pixel calculated, byte_offset calculated (combinational)
    // - Cycle N+1: vram_addr registered, x_pixel_delay1 registered
    // - Cycle N+2: vram_data available, x_pixel_delay2 registered
    // - Cycle N+3: pixel_palette_index registered
    // Total: 3 cycle delay, so delay video_active by 3 cycles
    reg [2:0] video_active_delay;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            video_active_delay <= 3'b000;
        end else begin
            video_active_delay <= {video_active_delay[1:0], video_active};
        end
    end

    wire video_active_delayed = video_active_delay[2];

    // Register outputs for clean timing (compensates for VRAM read latency)
    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            pixel_palette_index <= 4'h0;
            pixel_valid <= 1'b0;
        end else begin
            pixel_palette_index <= pixel_index;
            pixel_valid <= video_active_delayed;  // Use delayed signal
        end
    end

endmodule
