//
// gfx_test.c - Graphics mode test for HDMI display
//
// Switches to 4BPP graphics mode (160x100, 16 colors) and draws
// test patterns: color bars, rectangles, a simple gradient.
//
// Upload via monitor: L 4000, then G 4000
//

#include <femtorv32.h>

// Graphics GPU helpers
static inline void gfx_write(int reg, int val) { GPU_WRITE(reg, val); }

static void gfx_set_vram_addr(uint16_t addr) {
    gfx_write(GPU_REG_VRAM_ADDR_LO, addr & 0xFF);
    gfx_write(GPU_REG_VRAM_ADDR_HI, (addr >> 8) & 0x7F);
}

static void gfx_write_vram(uint8_t data) {
    gfx_write(GPU_REG_VRAM_DATA, data);
}

static void gfx_set_palette(int index, int r, int g, int b) {
    gfx_write(GPU_REG_CLUT_INDEX, index);
    gfx_write(GPU_REG_CLUT_DATA_R, r & 0xF);
    gfx_write(GPU_REG_CLUT_DATA_G, g & 0xF);
    gfx_write(GPU_REG_CLUT_DATA_B, b & 0xF);  // triggers palette write
}

// Set pixel in 4BPP mode (160x100, 2 pixels per byte)
// VRAM layout: byte = {pixel0[7:4], pixel1[3:0]}
//   pixel0 = left pixel, pixel1 = right pixel
static void gfx_set_pixel(int x, int y, int color) {
    uint16_t byte_addr = (y * 80) + (x / 2);
    int is_right = x & 1;

    // Read-modify-write: need to read current byte to preserve other pixel
    // Since we can't easily read VRAM via this interface, we'll use
    // full-byte writes where we control both pixels
    (void)is_right;  // handled in draw functions below
    (void)byte_addr;
    (void)color;
}

// Fill a rectangle in 4BPP mode (x must be even, w must be even)
static void gfx_fill_rect(int x, int y, int w, int h, int color) {
    uint8_t byte_val = (color << 4) | color;  // same color for both pixels
    for (int row = y; row < y + h && row < 100; row++) {
        uint16_t addr = (row * 80) + (x / 2);
        gfx_set_vram_addr(addr);
        // Enable burst mode for fast sequential writes
        gfx_write(GPU_REG_VRAM_CTRL, 1);
        for (int col = 0; col < w / 2; col++) {
            gfx_write_vram(byte_val);
        }
        gfx_write(GPU_REG_VRAM_CTRL, 0);
    }
}

// Clear entire screen (fill with color 0)
static void gfx_clear(int color) {
    gfx_fill_rect(0, 0, 160, 100, color);
}

// Draw horizontal color bars
static void gfx_color_bars(int y, int h) {
    for (int i = 0; i < 16; i++) {
        int x = i * 10;
        gfx_fill_rect(x, y, 10, h, i);
    }
}

// Draw a horizontal line of pixels with alternating colors
static void gfx_hline(int y, int color1, int color2) {
    uint16_t addr = y * 80;
    gfx_set_vram_addr(addr);
    gfx_write(GPU_REG_VRAM_CTRL, 1);
    uint8_t byte_val = (color1 << 4) | color2;
    for (int i = 0; i < 80; i++) {
        gfx_write_vram(byte_val);
    }
    gfx_write(GPU_REG_VRAM_CTRL, 0);
}

// Set up a nice 16-color palette (classic CGA-ish)
static void setup_palette(void) {
    // CGA-style palette with RGB444
    gfx_set_palette(0,  0x0, 0x0, 0x0);  // Black
    gfx_set_palette(1,  0x0, 0x0, 0xA);  // Blue
    gfx_set_palette(2,  0x0, 0xA, 0x0);  // Green
    gfx_set_palette(3,  0x0, 0xA, 0xA);  // Cyan
    gfx_set_palette(4,  0xA, 0x0, 0x0);  // Red
    gfx_set_palette(5,  0xA, 0x0, 0xA);  // Magenta
    gfx_set_palette(6,  0xA, 0x5, 0x0);  // Brown
    gfx_set_palette(7,  0xA, 0xA, 0xA);  // Light gray
    gfx_set_palette(8,  0x5, 0x5, 0x5);  // Dark gray
    gfx_set_palette(9,  0x5, 0x5, 0xF);  // Bright blue
    gfx_set_palette(10, 0x5, 0xF, 0x5);  // Bright green
    gfx_set_palette(11, 0x5, 0xF, 0xF);  // Bright cyan
    gfx_set_palette(12, 0xF, 0x5, 0x5);  // Bright red
    gfx_set_palette(13, 0xF, 0x5, 0xF);  // Bright magenta
    gfx_set_palette(14, 0xF, 0xF, 0x5);  // Yellow
    gfx_set_palette(15, 0xF, 0xF, 0xF);  // White
}

int main(void) {
    // Set up 4BPP mode
    gfx_write(GPU_REG_GPU_MODE, GPU_GFX_MODE_4BPP);
    gfx_write(GPU_REG_FB_BASE_LO, 0);
    gfx_write(GPU_REG_FB_BASE_HI, 0);

    // Set up palette
    setup_palette();

    // Clear screen
    gfx_clear(0);

    // Switch to graphics display mode
    gfx_write(GPU_REG_DISPLAY_MODE, 1);

    // Draw test patterns

    // 1. Color bars at top (16 colors, each 10px wide)
    gfx_color_bars(0, 20);

    // 2. Colored rectangles
    gfx_fill_rect(10, 30, 40, 20, 9);   // Bright blue box
    gfx_fill_rect(60, 30, 40, 20, 12);  // Bright red box
    gfx_fill_rect(110, 30, 40, 20, 10); // Bright green box

    // 3. Nested rectangles
    gfx_fill_rect(40, 60, 80, 30, 1);   // Blue background
    gfx_fill_rect(50, 65, 60, 20, 4);   // Red inner
    gfx_fill_rect(60, 70, 40, 10, 14);  // Yellow inner

    // 4. Dither pattern at bottom
    for (int y = 92; y < 100; y++) {
        if (y & 1)
            gfx_hline(y, 15, 0);  // White/black checkerboard
        else
            gfx_hline(y, 0, 15);
    }

    // Wait a while then switch back to text mode
    wait_cycles(25000000 * 5);  // ~5 seconds at 25MHz

    // Switch back to character mode
    gfx_write(GPU_REG_DISPLAY_MODE, 0);

    return 0;
}
