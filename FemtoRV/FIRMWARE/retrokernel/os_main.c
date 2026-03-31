// RetroKernel - Main entry point
// Called by BIOS after loading to 0x800000

#include "kernel.h"

// Decimal print (no printf dependency for kernel core)
void con_dec(uint32_t v) {
    char buf[11];
    int pos = 0;
    if (v == 0) { con_putc('0'); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    while (pos > 0) con_putc(buf[--pos]);
}

static void show_banner(void) {
    con_set_fg(GPU_BRIGHT_CYAN);
    con_set_bg(GPU_BLACK);
    con_puts("RetroKernel v0.1 - FemtoRV @ 25MHz\n");
    con_puts("===================================\n");
    con_set_fg(GPU_LIGHT_GRAY);
    con_puts("8MB SDRAM, 16KB ROM\n");
}

void kernel_init(void) {
    con_clear();
    show_banner();

    // Initialize filesystem
    con_set_fg(GPU_YELLOW);
    con_puts("Mounting SD card...\n");

    if (fs_init()) {
        con_set_fg(GPU_BRIGHT_GREEN);
        con_puts("SD card mounted at /\n");
    } else {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("No SD card - serial mode only\n");
    }

    con_puts("\n");
}

int main(void) {
    kernel_init();
    shell_loop();
    return 0;
}
