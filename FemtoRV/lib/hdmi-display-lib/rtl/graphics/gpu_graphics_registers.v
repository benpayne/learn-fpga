//
// gpu_graphics_registers.v - Graphics GPU Register File
//
// Implements CPU-accessible registers for graphics GPU control at base 0xC100
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//
// Features:
// - 16 registers (0xC100-0xC10F)
// - VRAM address pointer with auto-increment (burst mode)
// - Framebuffer base address for page flipping
// - Graphics mode selection (1/2/4 BPP)
// - Palette programming interface (CLUT)
// - Display mode control (character/graphics)
// - VBlank status and interrupt control
//
// Register Map:
//   0x0: VRAM_ADDR_LO   - VRAM address low byte
//   0x1: VRAM_ADDR_HI   - VRAM address high byte (bits 14:8)
//   0x2: VRAM_DATA      - VRAM read/write with optional auto-increment
//   0x3: VRAM_CTRL      - Bit 0: Burst mode enable
//   0x4: FB_BASE_LO     - Framebuffer base address low byte
//   0x5: FB_BASE_HI     - Framebuffer base address high byte
//   0x6: GPU_MODE       - Bits 1:0: Graphics mode (00/01/10)
//   0x7: CLUT_INDEX     - Palette index (0-15)
//   0x8: CLUT_DATA_R    - Palette red component
//   0x9: CLUT_DATA_G    - Palette green component
//   0xA: CLUT_DATA_B    - Palette blue component
//   0xB: GPU_STATUS     - Bit 0: VBlank flag (read-only)
//   0xC: GPU_IRQ_CTRL   - Bit 0: VBlank interrupt enable
//   0xD: DISPLAY_MODE   - Bit 0: 0=Character, 1=Graphics
//

`include "gpu_graphics_params.vh"

module gpu_graphics_registers(
    input  wire        clk_cpu,        // CPU clock
    input  wire        rst_n,          // Active-low reset

    // CPU bus interface
    input  wire [3:0]  reg_addr,       // Register address offset (0x0-0xF)
    input  wire [7:0]  reg_data_in,    // Write data
    input  wire        reg_we,         // Write enable
    input  wire        reg_re,         // Read enable
    output reg  [7:0]  reg_data_out,   // Read data

    // VRAM interface
    output wire [14:0] vram_addr,      // VRAM address for read/write
    output wire [7:0]  vram_data_out,  // Data to write to VRAM
    input  wire [7:0]  vram_data_in,   // Data read from VRAM
    output wire        vram_we,        // VRAM write enable

    // Palette interface
    output wire [3:0]  clut_index,     // Palette index
    output wire [3:0]  clut_data_r,    // Palette red
    output wire [3:0]  clut_data_g,    // Palette green
    output wire [3:0]  clut_data_b,    // Palette blue
    output wire        clut_we,        // Palette write enable

    // Graphics control outputs
    output wire [14:0] fb_base_addr,   // Framebuffer base address
    output wire [1:0]  gpu_mode,       // Graphics mode
    output wire        display_mode,   // 0=Character, 1=Graphics

    // Status inputs
    input  wire        vblank_flag,    // VBlank status from timing

    // Interrupt control
    output wire        gpu_irq_enable  // VBlank interrupt enable
);

    //=========================================================================
    // Register Storage
    //=========================================================================

    reg [14:0] vram_addr_ptr;          // 15-bit VRAM address pointer
    reg        vram_ctrl_burst;        // Burst mode enable
    reg [14:0] fb_base_addr_reg;       // Framebuffer base address
    reg [1:0]  gpu_mode_reg;           // Graphics mode
    reg [3:0]  clut_index_reg;         // Palette index
    reg [3:0]  clut_data_r_reg;        // Palette R component
    reg [3:0]  clut_data_g_reg;        // Palette G component
    reg [3:0]  clut_data_b_reg;        // Palette B component
    reg        gpu_irq_ctrl_reg;       // VBlank interrupt enable
    reg        display_mode_reg;       // Display mode select

    //=========================================================================
    // Register Write Logic
    //=========================================================================

    // Track VRAM_DATA writes for burst mode auto-increment
    wire vram_data_write = reg_we && (reg_addr == REG_VRAM_DATA);
    wire vram_data_read  = reg_re && (reg_addr == REG_VRAM_DATA);

    always @(posedge clk_cpu) begin
        if (!rst_n) begin
            // Reset all registers to default values
            vram_addr_ptr     <= 15'h0000;
            vram_ctrl_burst   <= 1'b0;
            fb_base_addr_reg  <= 15'h0000;
            gpu_mode_reg      <= GPU_MODE_1BPP;  // Default to 1 BPP
            clut_index_reg    <= 4'h0;
            clut_data_r_reg   <= 4'h0;
            clut_data_g_reg   <= 4'h0;
            clut_data_b_reg   <= 4'h0;
            gpu_irq_ctrl_reg  <= 1'b0;           // Interrupts disabled
            display_mode_reg  <= 1'b0;           // Character mode default
        end else if (reg_we) begin
            case (reg_addr)
                REG_VRAM_ADDR_LO: vram_addr_ptr[7:0]  <= reg_data_in;
                REG_VRAM_ADDR_HI: vram_addr_ptr[14:8] <= reg_data_in[6:0];  // Bit 7 unused
                REG_VRAM_DATA: begin
                    // VRAM_DATA write handled separately for burst mode
                    // Auto-increment happens after write if burst enabled
                end
                REG_VRAM_CTRL: vram_ctrl_burst <= reg_data_in[0];
                REG_FB_BASE_LO: fb_base_addr_reg[7:0]  <= reg_data_in;
                REG_FB_BASE_HI: fb_base_addr_reg[14:8] <= reg_data_in[6:0];
                REG_GPU_MODE: gpu_mode_reg <= reg_data_in[1:0];
                REG_CLUT_INDEX: clut_index_reg <= reg_data_in[3:0];
                REG_CLUT_DATA_R: clut_data_r_reg <= reg_data_in[3:0];
                REG_CLUT_DATA_G: clut_data_g_reg <= reg_data_in[3:0];
                REG_CLUT_DATA_B: clut_data_b_reg <= reg_data_in[3:0];
                REG_GPU_STATUS: begin
                    // Read-only register, ignore writes
                end
                REG_GPU_IRQ_CTRL: gpu_irq_ctrl_reg <= reg_data_in[0];
                REG_DISPLAY_MODE: display_mode_reg <= reg_data_in[0];
                default: begin
                    // Reserved registers, ignore writes
                end
            endcase
        end

        // Burst mode auto-increment logic
        // After writing to VRAM_DATA, increment address if burst enabled
        // Also increment after reading VRAM_DATA if burst enabled
        if ((vram_data_write || vram_data_read) && vram_ctrl_burst) begin
            vram_addr_ptr <= vram_addr_ptr + 1'b1;  // Auto-increment with wrap
        end
    end

    //=========================================================================
    // Register Read Logic
    //=========================================================================

    always @(*) begin
        case (reg_addr)
            REG_VRAM_ADDR_LO: reg_data_out = vram_addr_ptr[7:0];
            REG_VRAM_ADDR_HI: reg_data_out = {1'b0, vram_addr_ptr[14:8]};
            REG_VRAM_DATA: reg_data_out = vram_data_in;  // Read from VRAM
            REG_VRAM_CTRL: reg_data_out = {7'b0, vram_ctrl_burst};
            REG_FB_BASE_LO: reg_data_out = fb_base_addr_reg[7:0];
            REG_FB_BASE_HI: reg_data_out = {1'b0, fb_base_addr_reg[14:8]};
            REG_GPU_MODE: reg_data_out = {6'b0, gpu_mode_reg};
            REG_CLUT_INDEX: reg_data_out = {4'b0, clut_index_reg};
            REG_CLUT_DATA_R: reg_data_out = {4'b0, clut_data_r_reg};
            REG_CLUT_DATA_G: reg_data_out = {4'b0, clut_data_g_reg};
            REG_CLUT_DATA_B: reg_data_out = {4'b0, clut_data_b_reg};
            REG_GPU_STATUS: reg_data_out = {7'b0, vblank_flag};  // VBlank status
            REG_GPU_IRQ_CTRL: reg_data_out = {7'b0, gpu_irq_ctrl_reg};
            REG_DISPLAY_MODE: reg_data_out = {7'b0, display_mode_reg};
            default: reg_data_out = 8'h00;  // Reserved registers read as 0
        endcase
    end

    //=========================================================================
    // VRAM Interface Outputs
    //=========================================================================

    // VRAM address is current pointer value
    assign vram_addr = vram_addr_ptr;

    // VRAM data output is register write data
    assign vram_data_out = reg_data_in;

    // VRAM write enable: active when writing to VRAM_DATA register
    assign vram_we = vram_data_write;

    //=========================================================================
    // Palette Interface Outputs
    //=========================================================================

    assign clut_index  = clut_index_reg;
    assign clut_data_r = clut_data_r_reg;
    assign clut_data_g = clut_data_g_reg;
    assign clut_data_b = clut_data_b_reg;

    // Palette write enable: only write when BLUE component is written
    // This ensures all three components (R, G, B) are written to registers
    // before the palette entry is updated. Typical usage:
    //   1. Write CLUT_INDEX
    //   2. Write CLUT_DATA_R
    //   3. Write CLUT_DATA_G
    //   4. Write CLUT_DATA_B <- triggers palette write with all 3 components
    reg clut_we_reg;
    always @(posedge clk_cpu) begin
        if (!rst_n) begin
            clut_we_reg <= 1'b0;
        end else begin
            clut_we_reg <= reg_we && (reg_addr == REG_CLUT_DATA_B);
        end
    end
    assign clut_we = clut_we_reg;

    //=========================================================================
    // Graphics Control Outputs
    //=========================================================================

    assign fb_base_addr = fb_base_addr_reg;
    assign gpu_mode     = gpu_mode_reg;
    assign display_mode = display_mode_reg;
    assign gpu_irq_enable = gpu_irq_ctrl_reg;

endmodule
