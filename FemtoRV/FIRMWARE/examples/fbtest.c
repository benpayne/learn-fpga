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
#define FB_STRIDE 2048  // bytes per line (512 words, 2KB-aligned for SDRAM rows)

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

    volatile uint32_t *fb32 = (volatile uint32_t *)FB_BASE;
    int stride_words = FB_STRIDE / 4;  // 512 words per line

    GPU_WRITE(GPU_REG_CHAR_DATA, 'F');
    putchar('F');

    // Diagnostic pattern: each line has a unique color based on Y
    // Left half: vertical gradient (R increases with Y)
    // Right half: horizontal gradient (B increases with X)
    // Diagonal white stripe at y==x to detect line skipping/repeating
    for (int y = 0; y < FB_HEIGHT; y++) {
        // Line color: R based on Y, G based on Y inverted
        uint8_t r = (y * 31) / FB_HEIGHT;           // 0-31
        uint8_t g = ((FB_HEIGHT - y) * 63) / FB_HEIGHT; // 63-0
        uint16_t line_color = (r << 11) | (g << 5);  // RG gradient, no blue

        for (int x = 0; x < FB_WIDTH / 2; x++) {  // x in word units = 2 pixels
            int px = x * 2;  // pixel x position

            uint16_t pix0, pix1;

            if (px < FB_WIDTH / 2) {
                // Left half: line color (unique per Y — detects repeats)
                pix0 = line_color;
                pix1 = line_color;
            } else {
                // Right half: blue gradient (unique per X — detects column issues)
                uint8_t b0 = ((px) * 31) / FB_WIDTH;
                uint8_t b1 = ((px+1) * 31) / FB_WIDTH;
                pix0 = (r << 11) | b0;
                pix1 = (r << 11) | b1;
            }

            // Diagonal stripe: white line where y ~= px/1.6 (aspect ratio)
            int diag = (y * FB_WIDTH) / FB_HEIGHT;
            if (px >= diag - 2 && px <= diag + 2) {
                pix0 = 0xFFFF;  // White
                pix1 = 0xFFFF;
            }

            fb32[y * stride_words + x] = ((uint32_t)pix1 << 16) | pix0;
        }
    }

    GPU_WRITE(GPU_REG_CHAR_DATA, 'D');
    putchar('D');

    // Switch to mode 2
    GPU_WRITE(0x0D, 2);

    GPU_WRITE(GPU_REG_CHAR_DATA, 'M');
    putchar('M');

    // Wait ~10 seconds (CPU is slower during mode 2 due to SDRAM burst stalls)
    for (volatile long i = 0; i < 100000000; i++);

    // Back to text mode
    GPU_WRITE(0x0D, 0);

    GPU_WRITE(GPU_REG_CHAR_DATA, 'R');
    putchar('R');

    return 0;
}
