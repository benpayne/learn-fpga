//
// gpu_text.c - HDMI Character Display GPU Demo
//
// Demonstrates text mode features:
//   - Clear screen, print strings
//   - Foreground and background colors (8 colors)
//   - Cursor positioning, auto-advance, scrolling
//   - PS2 keyboard input echoed to display
//

#include <femtorv32.h>
#include "ps2_keymap.h"

// ----- GPU helper functions -----

static inline void gpu_putchar(char c) {
    GPU_WRITE(GPU_REG_CHAR_DATA, c);
}

static inline void gpu_set_cursor(int row, int col) {
    GPU_WRITE(GPU_REG_CURSOR_ROW, row);
    GPU_WRITE(GPU_REG_CURSOR_COL, col);
}

static inline void gpu_set_fg(int color) {
    GPU_WRITE(GPU_REG_FG_COLOR, color);
}

static inline void gpu_set_bg(int color) {
    GPU_WRITE(GPU_REG_BG_COLOR, color);
}

static inline void gpu_clear(void) {
    GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN);
    // gpu_registers state machine takes 1200 cycles (40-col) or 2400 cycles
    // (80-col) to clear screen. All writes are dropped during clear.
    wait_cycles(3000);
}

static inline void gpu_set_mode(int mode_80col, int cursor_en) {
    GPU_WRITE(GPU_REG_CONTROL, (mode_80col ? GPU_CTRL_80COL : 0) |
                               (cursor_en ? GPU_CTRL_CURSOR_EN : 0));
}

static void gpu_puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            gpu_putchar('\r');
            gpu_putchar('\n');
        } else {
            gpu_putchar(*s);
        }
        s++;
    }
}

static void gpu_puts_at(int row, int col, const char *s) {
    gpu_set_cursor(row, col);
    gpu_puts(s);
}

// ----- PS2 keyboard state -----

static volatile int ps2_ready = 0;
static volatile ps2_event_t ps2_last_event;
static ps2_state_t ps2;

static void irq_entry(void) __attribute__ ((interrupt ("machine")));

void irq_entry(void) {
    uint32_t flags = IO_IN(IO_INT_CONTROLLER);

    if (flags & (1 << INT_PS2_bit)) {
        uint32_t ps2_reg = IO_IN(IO_PS2);
        uint8_t scancode = ps2_reg & 0xFF;
        ps2_event_t ev = ps2_process_scancode(&ps2, scancode);

        if (ev.type == PS2_EVENT_PRESS) {
            ps2_last_event = ev;
            ps2_ready = 1;
        }
        CLEAR_INT(INT_PS2_bit);
    }
}

// ----- Demo screens -----

static void demo_banner(void) {
    gpu_clear();
    gpu_set_fg(GPU_BRIGHT_CYAN);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(0, 0, "========================================");
    gpu_puts_at(1, 0, "  FemtoRV HDMI Character Display Demo   ");
    gpu_puts_at(2, 0, "========================================");

    gpu_set_fg(GPU_WHITE);
    gpu_puts_at(4, 0, "Per-character colors! 16 CGA colors");

    // Show all 16 colors
    gpu_set_fg(GPU_BRIGHT_GREEN);
    gpu_puts_at(6, 0, "Foreground colors:");
    const char *names[] = {
        "Black", "Blue", "Green", "Cyan",
        "Red", "Magenta", "Brown", "LtGray",
        "DkGray", "BrBlue", "BrGreen", "BrCyan",
        "BrRed", "BrMagnt", "Yellow", "White"
    };
    for (int i = 0; i < 16; i++) {
        gpu_set_fg(i);
        gpu_set_bg(GPU_BLACK);
        gpu_puts_at(7 + i, 2, names[i]);
    }

    // Show background colors
    gpu_set_fg(GPU_BRIGHT_GREEN);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(6, 20, "Background colors:");
    for (int i = 0; i < 16; i++) {
        gpu_set_fg(i < 8 ? GPU_WHITE : GPU_BLACK);
        gpu_set_bg(i);
        gpu_puts_at(7 + i, 22, names[i]);
    }

    gpu_set_fg(GPU_BRIGHT_CYAN);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(24, 0, "ASCII table:");
    gpu_set_fg(GPU_YELLOW);
    gpu_set_cursor(25, 0);
    for (int c = 0x20; c < 0x7F; c++) {
        gpu_putchar(c);
    }

    gpu_set_fg(GPU_BRIGHT_CYAN);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(28, 0, "Press any key for scroll demo...");
}

static void demo_scroll(void) {
    gpu_clear();
    gpu_set_fg(GPU_YELLOW);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(0, 0, "Scroll test - filling 40 lines...");
    wait_cycles(500000);

    gpu_set_fg(GPU_GREEN);
    for (int i = 1; i <= 40; i++) {
        // Build line string manually (no sprintf to GPU)
        char buf[41];
        int pos = 0;
        buf[pos++] = 'L'; buf[pos++] = 'i'; buf[pos++] = 'n';
        buf[pos++] = 'e'; buf[pos++] = ' ';
        if (i >= 10) buf[pos++] = '0' + (i / 10);
        buf[pos++] = '0' + (i % 10);
        buf[pos++] = ':'; buf[pos++] = ' ';
        while (pos < 39) buf[pos++] = '#';
        buf[pos] = 0;

        gpu_puts(buf);
        gpu_putchar('\r');
        gpu_putchar('\n');
        wait_cycles(200000);
    }

    gpu_set_fg(GPU_CYAN);
    gpu_puts_at(29, 0, "Done! Press key for keyboard demo");
}

static void demo_keyboard(void) {
    gpu_clear();
    gpu_set_fg(GPU_CYAN);
    gpu_set_bg(GPU_BLACK);
    gpu_puts_at(0, 0, "========================================");
    gpu_puts_at(1, 0, "      PS2 Keyboard -> HDMI Display      ");
    gpu_puts_at(2, 0, "========================================");

    gpu_set_fg(GPU_WHITE);
    gpu_puts_at(4, 0, "Type on PS2 keyboard (ESC to restart):");
    gpu_set_fg(GPU_GREEN);
    gpu_set_cursor(6, 0);

    while (1) {
        if (ps2_ready) {
            ps2_ready = 0;
            ps2_event_t ev = ps2_last_event;

            if (ev.ascii >= 0x20 && ev.ascii < 0x7F) {
                gpu_putchar(ev.ascii);
                putchar(ev.ascii);
            } else if (ev.ascii == '\r') {
                gpu_putchar('\r');
                gpu_putchar('\n');
                putchar('\r');
                putchar('\n');
            } else if (ev.ascii == '\b') {
                // Backspace: read cursor position, move back, overwrite
                uint8_t col = GPU_READ(GPU_REG_CURSOR_COL);
                uint8_t row = GPU_READ(GPU_REG_CURSOR_ROW);
                if (col > 0) {
                    gpu_set_cursor(row, col - 1);
                    gpu_putchar(' ');
                    gpu_set_cursor(row, col - 1);
                }
            } else if (ev.ascii == '\x1b') {
                return;  // ESC: back to banner
            }
        }
    }
}

// ----- Main -----

int main(void) {
    ps2_init(&ps2);

    // Enable interrupts
    asm volatile ("csrw mtvec, %0" :: "r"(&irq_entry));
    asm volatile ("csrw mie, %0" :: "r"(0xFFFFFFFF));
    asm volatile ("csrsi mstatus, 0x8");

    printf("GPU Text Demo started\n");

    // 40-column mode with cursor
    gpu_set_mode(0, 1);

    while (1) {
        demo_banner();
        while (!ps2_ready);
        ps2_ready = 0;

        demo_scroll();
        while (!ps2_ready);
        ps2_ready = 0;

        demo_keyboard();
    }

    return 0;
}
