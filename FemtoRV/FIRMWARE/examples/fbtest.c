// fbtest.c — Framebuffer mode test
// Fills SDRAM framebuffer at 0x810000 with a test pattern,
// then switches GPU to display_mode=2 (framebuffer).
// Press any key to return to text mode.

#include <femtorv32.h>

// RGB565 color helpers
#define RGB565(r,g,b) ((((r)&0x1F)<<11) | (((g)&0x3F)<<5) | ((b)&0x1F))

// Framebuffer at program space start (320 words per line = 1280 bytes = 640 pixels)
#define FB_BASE   0x810000
#define FB_WIDTH  640
#define FB_HEIGHT 400
#define FB_STRIDE 1280  // bytes per line (640 * 2)

static inline void fb_pixel(int x, int y, uint16_t color) {
    volatile uint16_t *fb = (volatile uint16_t *)FB_BASE;
    fb[y * FB_WIDTH + x] = color;
}

static inline void fb_fill_rect(int x0, int y0, int w, int h, uint16_t color) {
    volatile uint16_t *fb = (volatile uint16_t *)FB_BASE;
    for (int y = y0; y < y0 + h && y < FB_HEIGHT; y++)
        for (int x = x0; x < x0 + w && x < FB_WIDTH; x++)
            fb[y * FB_WIDTH + x] = color;
}

int main(void) {
    // Print status to text console first
    GPU_WRITE(GPU_REG_FG_COLOR, GPU_BRIGHT_CYAN);
    GPU_WRITE(GPU_REG_CHAR_DATA, 'F');
    GPU_WRITE(GPU_REG_CHAR_DATA, 'B');
    putchar('F'); putchar('B');

    // Fill framebuffer with color bars
    volatile uint16_t *fb = (volatile uint16_t *)FB_BASE;

    // 8 vertical color bars
    uint16_t colors[] = {
        RGB565(31,0,0),    // Red
        RGB565(0,63,0),    // Green
        RGB565(0,0,31),    // Blue
        RGB565(31,63,0),   // Yellow
        RGB565(31,0,31),   // Magenta
        RGB565(0,63,31),   // Cyan
        RGB565(31,63,31),  // White
        RGB565(0,0,0),     // Black
    };

    int bar_width = FB_WIDTH / 8;

    for (int y = 0; y < FB_HEIGHT; y++) {
        for (int x = 0; x < FB_WIDTH; x++) {
            int bar = x / bar_width;
            // Add gradient: darken toward bottom
            int r = ((colors[bar] >> 11) & 0x1F) * (FB_HEIGHT - y) / FB_HEIGHT;
            int g = ((colors[bar] >> 5)  & 0x3F) * (FB_HEIGHT - y) / FB_HEIGHT;
            int b = ((colors[bar])       & 0x1F) * (FB_HEIGHT - y) / FB_HEIGHT;
            fb[y * FB_WIDTH + x] = RGB565(r, g, b);
        }
    }

    // Switch to framebuffer mode
    // GPU_REG_DISPLAY_MODE is in graphics register space (addr 0x0D)
    // Graphics GPU address = 0x00-0x0F (gfx_gpu_cs = addr[7:4]==0)
    // So full GPU addr = 0x0D
    GPU_WRITE(0x0D, 2);  // display_mode = 2

    // Wait for keypress
    while (1) {
        uint32_t uart = IO_IN(IO_UART_DAT);
        if (uart & 0x100) break;
    }

    // Switch back to text mode
    GPU_WRITE(0x0D, 0);  // display_mode = 0

    return 0;
}
