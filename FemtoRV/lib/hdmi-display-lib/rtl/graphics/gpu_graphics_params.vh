//
// gpu_graphics_params.vh - Common Parameters for Graphics GPU
//
// Defines graphics modes, resolutions, palette sizes, and memory organization
// for the retrocpu graphics framebuffer GPU.
//
// Author: RetroCPU Project
// License: MIT
// Created: 2026-01-04
//

`ifndef GPU_GRAPHICS_PARAMS_VH
`define GPU_GRAPHICS_PARAMS_VH

//=============================================================================
// Graphics Mode Definitions
//=============================================================================

// GPU_MODE register values (2 bits)
localparam GPU_MODE_1BPP = 2'b00;  // 320x200 monochrome (8 pixels per byte)
localparam GPU_MODE_2BPP = 2'b01;  // 160x200, 4-color palette (4 pixels per byte)
localparam GPU_MODE_4BPP = 2'b10;  // 160x100, 16-color palette (2 pixels per byte)
localparam GPU_MODE_RESERVED = 2'b11;  // Reserved for future use

//=============================================================================
// Resolution Parameters by Mode
//=============================================================================

// 1 BPP Mode: 320x200 monochrome
localparam MODE_1BPP_WIDTH  = 320;
localparam MODE_1BPP_HEIGHT = 200;
localparam MODE_1BPP_BYTES_PER_ROW = 40;  // 320 / 8
localparam MODE_1BPP_TOTAL_BYTES = 8000;  // 40 * 200

// 2 BPP Mode: 160x200, 4 colors
localparam MODE_2BPP_WIDTH  = 160;
localparam MODE_2BPP_HEIGHT = 200;
localparam MODE_2BPP_BYTES_PER_ROW = 40;  // 160 / 4
localparam MODE_2BPP_TOTAL_BYTES = 8000;  // 40 * 200

// 4 BPP Mode: 160x100, 16 colors
localparam MODE_4BPP_WIDTH  = 160;
localparam MODE_4BPP_HEIGHT = 100;
localparam MODE_4BPP_BYTES_PER_ROW = 80;  // 160 / 2
localparam MODE_4BPP_TOTAL_BYTES = 8000;  // 80 * 100

//=============================================================================
// VRAM Organization
//=============================================================================

// VRAM size and address range
localparam VRAM_SIZE        = 32768;       // 32KB total
localparam VRAM_ADDR_WIDTH  = 15;          // 15-bit address (0-32767)
localparam VRAM_ADDR_MAX    = VRAM_SIZE - 1;  // $7FFF

// VRAM page organization (4 pages of 8KB each)
localparam VRAM_PAGE_SIZE   = 8192;        // 8KB per page
localparam VRAM_PAGE_0      = 15'h0000;    // Page 0: $0000-$1FFF
localparam VRAM_PAGE_1      = 15'h2000;    // Page 1: $2000-$3FFF
localparam VRAM_PAGE_2      = 15'h4000;    // Page 2: $4000-$5FFF
localparam VRAM_PAGE_3      = 15'h6000;    // Page 3: $6000-$7FFF

//=============================================================================
// Color Palette (CLUT) Parameters
//=============================================================================

// Palette size and color format
localparam PALETTE_ENTRIES  = 16;          // 16 palette entries
localparam PALETTE_ADDR_WIDTH = 4;         // 4-bit index (0-15)
localparam COLOR_BITS       = 4;           // 4 bits per RGB component (RGB444)

// RGB444 to RGB888 expansion (bit duplication)
// Example: 4'hA (1010) → 8'hAA (10101010)

//=============================================================================
// Register Address Offsets (Base: 0xC100)
//=============================================================================

// These are offsets from the graphics GPU register base (0xC100)
localparam REG_VRAM_ADDR_LO  = 4'h0;  // 0xC100: VRAM address pointer low byte
localparam REG_VRAM_ADDR_HI  = 4'h1;  // 0xC101: VRAM address pointer high byte
localparam REG_VRAM_DATA     = 4'h2;  // 0xC102: VRAM data read/write
localparam REG_VRAM_CTRL     = 4'h3;  // 0xC103: VRAM control (burst mode)
localparam REG_FB_BASE_LO    = 4'h4;  // 0xC104: Framebuffer base address low
localparam REG_FB_BASE_HI    = 4'h5;  // 0xC105: Framebuffer base address high
localparam REG_GPU_MODE      = 4'h6;  // 0xC106: Graphics mode (1/2/4 BPP)
localparam REG_CLUT_INDEX    = 4'h7;  // 0xC107: Palette index (0-15)
localparam REG_CLUT_DATA_R   = 4'h8;  // 0xC108: Palette red component
localparam REG_CLUT_DATA_G   = 4'h9;  // 0xC109: Palette green component
localparam REG_CLUT_DATA_B   = 4'hA;  // 0xC10A: Palette blue component
localparam REG_GPU_STATUS    = 4'hB;  // 0xC10B: Status (VBlank flag)
localparam REG_GPU_IRQ_CTRL  = 4'hC;  // 0xC10C: Interrupt control (VBlank enable)
localparam REG_DISPLAY_MODE  = 4'hD;  // 0xC10D: Display mode (char/graphics)
// 0xC10E-0xC10F: Reserved

//=============================================================================
// Control Register Bit Definitions
//=============================================================================

// VRAM_CTRL register (0xC103)
localparam VRAM_CTRL_BURST_BIT = 0;        // Bit 0: Burst mode enable

// GPU_STATUS register (0xC10B) - Read only
localparam GPU_STATUS_VBLANK_BIT = 0;      // Bit 0: VBlank flag

// GPU_IRQ_CTRL register (0xC10C)
localparam GPU_IRQ_VBLANK_EN_BIT = 0;      // Bit 0: VBlank interrupt enable

// DISPLAY_MODE register (0xC10D)
localparam DISPLAY_MODE_SELECT_BIT = 0;    // Bit 0: 0=Character, 1=Graphics

//=============================================================================
// VGA Timing Constants (from vga_timing_generator.v)
//=============================================================================

// These constants are shared with the character GPU
localparam VGA_H_VISIBLE = 640;            // Horizontal visible pixels
localparam VGA_V_VISIBLE = 480;            // Vertical visible lines
localparam VGA_V_SYNC_START = 490;         // VBlank starts at line 490

//=============================================================================
// Pixel Rendering Constants
//=============================================================================

// Pixels per byte for each mode
localparam PIXELS_PER_BYTE_1BPP = 8;       // 8 pixels per byte (1 bit each)
localparam PIXELS_PER_BYTE_2BPP = 4;       // 4 pixels per byte (2 bits each)
localparam PIXELS_PER_BYTE_4BPP = 2;       // 2 pixels per byte (4 bits each)

// Bit positions for pixel extraction
// 1 BPP: bit 7 = pixel 0 (leftmost), bit 0 = pixel 7 (rightmost)
// 2 BPP: bits [7:6] = pixel 0, [5:4] = pixel 1, [3:2] = pixel 2, [1:0] = pixel 3
// 4 BPP: bits [7:4] = pixel 0, [3:0] = pixel 1

`endif // GPU_GRAPHICS_PARAMS_VH
