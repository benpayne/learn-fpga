//
// bounce.c - Bouncing logo screensaver (4BPP graphics mode)
//
// 160x100 16-color display, bouncing rectangle with color cycling.
// Press any key (PS2 or UART) to exit back to monitor.
//

#include <femtorv32.h>

// Graphics helpers
static inline void gfx_write(int reg, int val) { GPU_WRITE(reg, val); }

static void gfx_set_vram_addr(uint16_t addr) {
    gfx_write(GPU_REG_VRAM_ADDR_LO, addr & 0xFF);
    gfx_write(GPU_REG_VRAM_ADDR_HI, (addr >> 8) & 0x7F);
}

static void gfx_vram_byte(uint8_t data) {
    gfx_write(GPU_REG_VRAM_DATA, data);
}

// Fill a horizontal span in 4BPP (x and w must be even)
static void gfx_hspan(int x, int y, int w, int color) {
    uint16_t addr = y * 80 + x / 2;
    uint8_t byte_val = (color << 4) | color;
    gfx_set_vram_addr(addr);
    gfx_write(GPU_REG_VRAM_CTRL, 1);  // burst mode
    for (int i = 0; i < w / 2; i++) {
        gfx_vram_byte(byte_val);
    }
    gfx_write(GPU_REG_VRAM_CTRL, 0);
}

// Fill rectangle (x and w must be even)
static void gfx_rect(int x, int y, int w, int h, int color) {
    for (int row = y; row < y + h && row < 100; row++) {
        gfx_hspan(x, row, w, color);
    }
}

// Draw the bouncing logo: a bordered rectangle with inner pattern
// Logo is 24x16 pixels
#define LOGO_W 24
#define LOGO_H 16

static void draw_logo(int x, int y, int border_color, int fill_color, int accent_color) {
    // Border (top, bottom, left, right)
    gfx_hspan(x, y, LOGO_W, border_color);
    gfx_hspan(x, y + LOGO_H - 1, LOGO_W, border_color);
    for (int row = y + 1; row < y + LOGO_H - 1; row++) {
        // Left and right border pixels (2 pixels each)
        uint16_t addr = row * 80 + x / 2;
        gfx_set_vram_addr(addr);
        gfx_vram_byte((border_color << 4) | border_color);

        // Fill
        gfx_set_vram_addr(addr + 1);
        gfx_write(GPU_REG_VRAM_CTRL, 1);
        uint8_t fill = (fill_color << 4) | fill_color;
        for (int i = 0; i < (LOGO_W - 4) / 2; i++) {
            gfx_vram_byte(fill);
        }
        gfx_write(GPU_REG_VRAM_CTRL, 0);

        // Right border
        gfx_set_vram_addr(addr + LOGO_W / 2 - 1);
        gfx_vram_byte((border_color << 4) | border_color);
    }

    // Draw a simple "R" pattern in the center using accent color
    // R shape in a 6x8 grid, centered in the logo
    static const uint8_t r_pattern[8] = {
        0b111100,
        0b100010,
        0b100010,
        0b111100,
        0b101000,
        0b100100,
        0b100010,
        0b100001,
    };

    int cx = x + 4;  // center offset
    int cy = y + 4;
    for (int row = 0; row < 8; row++) {
        for (int col = 0; col < 6; col += 2) {
            int px = cx + col;
            int py = cy + row;
            uint16_t addr = py * 80 + px / 2;
            uint8_t left = (r_pattern[row] & (1 << (5 - col))) ? accent_color : fill_color;
            uint8_t right = (r_pattern[row] & (1 << (4 - col))) ? accent_color : fill_color;
            gfx_set_vram_addr(addr);
            gfx_vram_byte((left << 4) | right);
        }
    }

    // Draw "V" next to R
    static const uint8_t v_pattern[8] = {
        0b100010,
        0b100010,
        0b100010,
        0b100010,
        0b010100,
        0b010100,
        0b001000,
        0b001000,
    };

    cx = x + 12;
    for (int row = 0; row < 8; row++) {
        for (int col = 0; col < 6; col += 2) {
            int px = cx + col;
            int py = cy + row;
            uint16_t addr = py * 80 + px / 2;
            uint8_t left = (v_pattern[row] & (1 << (5 - col))) ? accent_color : fill_color;
            uint8_t right = (v_pattern[row] & (1 << (4 - col))) ? accent_color : fill_color;
            gfx_set_vram_addr(addr);
            gfx_vram_byte((left << 4) | right);
        }
    }
}

// Clear area where logo was (draw black)
static void clear_logo(int x, int y) {
    gfx_rect(x, y, LOGO_W, LOGO_H, 0);
}

// Wait for VBlank start (poll GPU status register)
static void wait_vblank(void) {
    // Wait until NOT in vblank (in case we're already in one)
    while (GPU_READ(GPU_REG_GPU_STATUS) & 0x01);
    // Wait until vblank starts
    while (!(GPU_READ(GPU_REG_GPU_STATUS) & 0x01));
}

// Set up CGA-style palette
static void setup_palette(void) {
    static const uint8_t pal[16][3] = {
        {0x0,0x0,0x0}, {0x0,0x0,0xA}, {0x0,0xA,0x0}, {0x0,0xA,0xA},
        {0xA,0x0,0x0}, {0xA,0x0,0xA}, {0xA,0x5,0x0}, {0xA,0xA,0xA},
        {0x5,0x5,0x5}, {0x5,0x5,0xF}, {0x5,0xF,0x5}, {0x5,0xF,0xF},
        {0xF,0x5,0x5}, {0xF,0x5,0xF}, {0xF,0xF,0x5}, {0xF,0xF,0xF},
    };
    for (int i = 0; i < 16; i++) {
        gfx_write(GPU_REG_CLUT_INDEX, i);
        gfx_write(GPU_REG_CLUT_DATA_R, pal[i][0]);
        gfx_write(GPU_REG_CLUT_DATA_G, pal[i][1]);
        gfx_write(GPU_REG_CLUT_DATA_B, pal[i][2]);
    }
}

// Flush any pending UART/PS2 input
static void flush_input(void) {
    // Drain UART FIFO
    for (int i = 0; i < 256; i++) {
        uint32_t uart = IO_IN(IO_UART_DAT);
        if (!(uart & 0x100)) break;
    }
    // Drain PS2
    for (int i = 0; i < 16; i++) {
        uint32_t ps2 = IO_IN(IO_PS2);
        if (!(ps2 & 0x100)) break;
    }
}

// Check if ESC key pressed (UART or PS2, non-blocking)
static int esc_pressed(void) {
    // Check UART
    uint32_t uart = IO_IN(IO_UART_DAT);
    if (uart & 0x100) {
        if ((uart & 0xFF) == 0x1B) return 1;  // ESC
    }
    // Check PS2 (scan code 0x76 = ESC, but we get ASCII from the wrapper)
    uint32_t ps2 = IO_IN(IO_PS2);
    if (ps2 & 0x100) {
        if ((ps2 & 0xFF) == 0x76) return 1;  // ESC scan code
    }
    return 0;
}

int main(void) {
    // Set up 4BPP graphics mode
    gfx_write(GPU_REG_GPU_MODE, GPU_GFX_MODE_4BPP);
    gfx_write(GPU_REG_FB_BASE_LO, 0);
    gfx_write(GPU_REG_FB_BASE_HI, 0);
    setup_palette();

    // Clear screen to dark blue
    gfx_rect(0, 0, 160, 100, 1);

    // Flush any leftover input from UART/PS2 (upload script residue)
    flush_input();
    wait_cycles(100000);
    flush_input();

    // Switch to graphics mode
    gfx_write(GPU_REG_DISPLAY_MODE, 1);

    // Logo position and velocity
    int x = 20, y = 10;
    int dx = 2, dy = 1;

    // Color cycling
    int border_colors[] = {9, 10, 11, 12, 13, 14, 15};
    int fill_colors[]   = {1, 2, 3, 4, 5, 6, 8};
    int color_idx = 0;
    int frame = 0;

    while (!esc_pressed()) {
        // Erase old position
        clear_logo(x, y);

        // Move
        x += dx;
        y += dy;

        // Bounce off edges
        if (x <= 0) { x = 0; dx = -dx; color_idx = (color_idx + 1) % 7; }
        if (x >= 160 - LOGO_W) { x = 160 - LOGO_W; dx = -dx; color_idx = (color_idx + 1) % 7; }
        if (y <= 0) { y = 0; dy = -dy; color_idx = (color_idx + 1) % 7; }
        if (y >= 100 - LOGO_H) { y = 100 - LOGO_H; dy = -dy; color_idx = (color_idx + 1) % 7; }

        // Ensure x is even (4BPP requires even x for byte alignment)
        x &= ~1;

        // Draw at new position with cycling colors
        draw_logo(x, y, border_colors[color_idx], fill_colors[color_idx], 15);

        // Sync to VBlank (no tearing)
        wait_vblank();
        frame++;
    }

    // Switch back to character mode
    gfx_write(GPU_REG_DISPLAY_MODE, 0);

    return 0;
}
