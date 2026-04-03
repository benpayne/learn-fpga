// showimg.c — Load and display a raw RGB565 image from SD card
// Usage: showimg <filename.raw>
// Image format: 640x400 RGB565, compact (1280 bytes/line, no padding)
// Loaded to SDRAM with 2KB stride for SDRAM row alignment.

#include "retrokernel.h"

#define FB_BASE    0xA00000
#define FB_STRIDE  2048    // bytes per line in SDRAM (512 words, row-aligned)
#define IMG_STRIDE 1280    // bytes per line in file (640 pixels × 2)
#define FB_WIDTH   640
#define FB_HEIGHT  400

int main(int argc, char **argv) {
    if (argc < 2) {
        rk_puts("usage: showimg <file.raw>\n");
        rk_puts("  640x400 RGB565, 1280 bytes/line\n");
        return 1;
    }

    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts("Loading ");
    rk_puts(argv[1]);
    rk_puts("...\n");

    // Load compact image to temp buffer
    uint8_t *tmp = (uint8_t *)0x900000;
    int size = rk_load_file(argv[1], tmp, IMG_STRIDE * FB_HEIGHT);
    if (size <= 0) {
        rk_set_fg(GPU_BRIGHT_RED);
        rk_puts("Failed to load\n");
        return 1;
    }

    rk_set_fg(GPU_BRIGHT_GREEN);
    rk_putdec(size);
    rk_puts(" bytes\n");

    // Copy to framebuffer with stride expansion
    // Compact: 1280 bytes/line → SDRAM: 2048 bytes/line
    rk_puts("Expanding to FB...\n");
    volatile uint32_t *fb = (volatile uint32_t *)FB_BASE;
    uint32_t *src = (uint32_t *)tmp;
    int src_words_per_line = IMG_STRIDE / 4;    // 320
    int dst_words_per_line = FB_STRIDE / 4;     // 512

    for (int y = 0; y < FB_HEIGHT; y++) {
        for (int x = 0; x < src_words_per_line; x++) {
            fb[y * dst_words_per_line + x] = src[y * src_words_per_line + x];
        }
    }

    // Switch to framebuffer mode
    GPU_WRITE(0x0D, 2);

    // Wait for keypress to exit
    rk_getc();

    // Back to text mode
    GPU_WRITE(0x0D, 0);
    return 0;
}
