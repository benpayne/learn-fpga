// showimg.c — Load and display a raw RGB565 image from SD card
// Usage: showimg <filename.raw>
// Image format: 640x400 RGB565 with 2048-byte stride (512 words per line)

#include "retrokernel.h"

#define FB_BASE    0xA00000
#define FB_STRIDE  2048    // bytes per line
#define FB_WIDTH   640
#define FB_HEIGHT  400

int main(int argc, char **argv) {
    if (argc < 2) {
        rk_puts("usage: showimg <file.raw>\n");
        rk_puts("  640x400 RGB565, 2KB stride\n");
        return 1;
    }

    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts("Loading ");
    rk_puts(argv[1]);
    rk_puts("...\n");

    // Load directly to framebuffer in SDRAM
    int size = rk_load_file(argv[1], (void *)FB_BASE, FB_STRIDE * FB_HEIGHT);
    if (size <= 0) {
        rk_set_fg(GPU_BRIGHT_RED);
        rk_puts("Failed to load\n");
        return 1;
    }

    rk_set_fg(GPU_BRIGHT_GREEN);
    rk_putdec(size);
    rk_puts(" bytes loaded\n");

    // Verify data at framebuffer address
    rk_puts("Verify FB data:\n");
    volatile uint32_t *fb = (volatile uint32_t *)FB_BASE;
    rk_puts("  [0]=0x"); rk_puthex8(fb[0]>>24); rk_puthex8(fb[0]>>16); rk_puthex8(fb[0]>>8); rk_puthex8(fb[0]);
    rk_puts("\n  [1]=0x"); rk_puthex8(fb[1]>>24); rk_puthex8(fb[1]>>16); rk_puthex8(fb[1]>>8); rk_puthex8(fb[1]);
    rk_puts("\n  [160]=0x"); rk_puthex8(fb[160]>>24); rk_puthex8(fb[160]>>16); rk_puthex8(fb[160]>>8); rk_puthex8(fb[160]);
    rk_puts("\n  [512]=0x"); rk_puthex8(fb[512]>>24); rk_puthex8(fb[512]>>16); rk_puthex8(fb[512]>>8); rk_puthex8(fb[512]);
    rk_puts("\n");

    // Switch to framebuffer mode
    GPU_WRITE(0x0D, 2);

    // Wait for PS2 keypress
    rk_getc();

    // Back to text mode
    GPU_WRITE(0x0D, 0);
    return 0;
}
