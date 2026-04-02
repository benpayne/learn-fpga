// fbtest.c — Framebuffer mode test
// Fills SDRAM framebuffer at 0x810000 with a test pattern,
// then switches GPU to display_mode=2 (framebuffer).
// Press any key to return to text mode.

#include <femtorv32.h>

// RGB565 color helpers
#define RGB565(r,g,b) ((((r)&0x1F)<<11) | (((g)&0x3F)<<5) | ((b)&0x1F))

// Framebuffer in upper SDRAM (above program space)
// 640*400*2 = 512000 bytes = 0x7D000, fits in 0xA00000-0xA7D000
#define FB_BASE   0xA00000
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

    // Fill framebuffer with solid color bars using word writes
    volatile uint32_t *fb32 = (volatile uint32_t *)FB_BASE;

    // RGB565 colors packed as two pixels per 32-bit word
    // Red=0xF800, Green=0x07E0, Blue=0x001F, White=0xFFFF
    uint32_t red2   = 0xF800F800;
    uint32_t green2 = 0x07E007E0;
    uint32_t blue2  = 0x001F001F;
    uint32_t white2 = 0xFFFFFFFF;
    uint32_t yellow2= 0xFFE0FFE0;
    uint32_t cyan2  = 0x07FF07FF;
    uint32_t mag2   = 0xF81FF81F;
    uint32_t black2 = 0x00000000;

    uint32_t colors[] = {red2, green2, blue2, yellow2, mag2, cyan2, white2, black2};
    int bar_width_words = FB_WIDTH / 2 / 8;  // 40 words per bar

    GPU_WRITE(GPU_REG_CHAR_DATA, 'F');
    putchar('F');

    for (int y = 0; y < FB_HEIGHT; y++) {
        for (int bar = 0; bar < 8; bar++) {
            for (int x = 0; x < bar_width_words; x++) {
                fb32[y * (FB_WIDTH/2) + bar * bar_width_words + x] = colors[bar];
            }
        }
    }

    GPU_WRITE(GPU_REG_CHAR_DATA, 'D');
    putchar('D');

    // Switch to mode 2
    GPU_WRITE(0x0D, 2);

    GPU_WRITE(GPU_REG_CHAR_DATA, 'M');
    putchar('M');

    // Wait ~5 seconds
    for (volatile int i = 0; i < 40000000; i++);

    // Back to text mode
    GPU_WRITE(0x0D, 0);

    GPU_WRITE(GPU_REG_CHAR_DATA, 'R');
    putchar('R');

    return 0;
}
