// hello.c - Simple test program for RetroKernel
// Runs from 0x810000, uses GPU and UART directly (no syscalls yet)

#include <femtorv32.h>

static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }

static void out_puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            gpu_putc('\r'); gpu_putc('\n');
            putchar('\r'); putchar('\n');
        } else {
            gpu_putc(*s); putchar(*s);
        }
        s++;
    }
}

int main(void) {
    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("Hello from RetroKernel!\n");
    gpu_set_fg(GPU_WHITE);
    out_puts("This program was loaded from SD card.\n");
    out_puts("Returning to shell...\n");
    return 0;
}
