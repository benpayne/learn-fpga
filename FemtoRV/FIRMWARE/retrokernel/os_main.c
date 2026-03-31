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

// Zero BSS section (not done by CRT0 since we're loaded raw)
extern uint32_t _bss_start, _bss_end;
static void clear_bss(void) {
    volatile uint32_t *p = &_bss_start;
    while (p < &_bss_end)
        *p++ = 0;
}

// Simple trap handler — catches exceptions and prints debug info
// Note: petitbateau shares mtvec for both interrupts and exceptions.
// The shell sets mtvec to the PS2 ISR. This is a fallback for
// unhandled traps before the shell starts.
static void trap_handler(void) __attribute__ ((interrupt ("machine")));
static void trap_handler(void) {
    uint32_t mepc, mcause;
    asm volatile ("csrr %0, mepc" : "=r"(mepc));
    asm volatile ("csrr %0, mcause" : "=r"(mcause));

    // Restore gp for IO access
    asm volatile (".option push\n.option norelax\nli gp, 0x400000\n.option pop\n");

    // Force text mode
    GPU_WRITE(GPU_REG_DISPLAY_MODE, 0);
    wait_cycles(1000);

    con_set_fg(GPU_BRIGHT_RED);
    con_puts("\n*** TRAP ***\n");
    con_puts("  mepc=0x");
    for (int i = 28; i >= 0; i -= 4) {
        int n = (mepc >> i) & 0xF;
        con_putc(n < 10 ? '0' + n : 'a' + n - 10);
    }
    con_puts(" mcause=0x");
    for (int i = 28; i >= 0; i -= 4) {
        int n = (mcause >> i) & 0xF;
        con_putc(n < 10 ? '0' + n : 'a' + n - 10);
    }
    con_putc('\n');

    // Halt
    con_puts("System halted. Reboot to continue.\n");
    while(1);
}

void kernel_init(void) {
    clear_bss();

    // Don't set mtvec here — mtvec is shared with interrupts.
    // The shell's ISR will check mcause to distinguish interrupts from traps.

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
