//
// hello_gpu.c - Uploadable program that writes to HDMI display
//
// Upload via monitor: L 4000, then G 4000
// Or: python3 TOOLS/xmodem_upload.py FIRMWARE/examples/hello_gpu.bin
//

#include <femtorv32.h>

// GPU helpers (same as monitor, duplicated for standalone use)
static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_set_cursor(int r, int c) { GPU_WRITE(GPU_REG_CURSOR_ROW, r); GPU_WRITE(GPU_REG_CURSOR_COL, c); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }
static inline void gpu_set_bg(int c) { GPU_WRITE(GPU_REG_BG_COLOR, c); }
static inline void gpu_clear(void) { GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN | GPU_CTRL_80COL); wait_cycles(5000); }

static void gpu_puts(const char *s) {
    while (*s) {
        if (*s == '\n') { gpu_putc('\r'); gpu_putc('\n'); }
        else gpu_putc(*s);
        s++;
    }
}

static void gpu_puts_at(int row, int col, const char *s) {
    gpu_set_cursor(row, col);
    gpu_puts(s);
}

// Draw a colored box
static void draw_box(int row, int col, int w, int h, int fg, int bg, char fill) {
    gpu_set_fg(fg);
    gpu_set_bg(bg);
    for (int r = 0; r < h; r++) {
        gpu_set_cursor(row + r, col);
        for (int c = 0; c < w; c++) {
            gpu_putc(fill);
        }
    }
}

int main(void) {
    gpu_clear();

    // Title
    gpu_set_fg(GPU_WHITE);
    gpu_set_bg(GPU_BLUE);
    gpu_puts_at(0, 0, "                         Hello from uploaded program!                          ");

    // Draw some colored boxes
    gpu_set_bg(GPU_BLACK);
    draw_box(3, 5, 20, 5, GPU_BRIGHT_GREEN, GPU_BLACK, '#');
    draw_box(3, 30, 20, 5, GPU_BRIGHT_RED, GPU_BLACK, '*');
    draw_box(3, 55, 20, 5, GPU_BRIGHT_CYAN, GPU_BLACK, '=');

    // Labels
    gpu_set_bg(GPU_BLACK);
    gpu_set_fg(GPU_WHITE);
    gpu_puts_at(9, 5, "Green box");
    gpu_puts_at(9, 30, "Red box");
    gpu_puts_at(9, 55, "Cyan box");

    // Show a color gradient bar
    gpu_puts_at(12, 5, "16-color palette:");
    for (int i = 0; i < 16; i++) {
        gpu_set_fg(GPU_BLACK);
        gpu_set_bg(i);
        gpu_set_cursor(13, 5 + i * 4);
        // Print color index
        char buf[4];
        buf[0] = ' ';
        buf[1] = (i >= 10) ? '1' : ' ';
        buf[2] = '0' + (i % 10);
        buf[3] = ' ';
        for (int j = 0; j < 4; j++) gpu_putc(buf[j]);
    }

    // Animated counter
    gpu_set_bg(GPU_BLACK);
    gpu_set_fg(GPU_YELLOW);
    gpu_puts_at(16, 5, "Running counter: ");

    int count = 0;
    while (1) {
        gpu_set_cursor(16, 22);
        gpu_set_fg(GPU_BRIGHT_GREEN);

        // Print decimal number (simple)
        int n = count;
        char digits[10];
        int pos = 0;
        if (n == 0) { digits[pos++] = '0'; }
        else {
            int tmp = n;
            int start = pos;
            while (tmp > 0) { digits[pos++] = '0' + (tmp % 10); tmp /= 10; }
            // Reverse
            for (int i = start, j = pos - 1; i < j; i++, j--) {
                char t = digits[i]; digits[i] = digits[j]; digits[j] = t;
            }
        }
        digits[pos++] = ' '; digits[pos++] = ' '; digits[pos++] = ' ';
        for (int i = 0; i < pos; i++) gpu_putc(digits[i]);

        count++;
        wait_cycles(500000);

        // Exit after 1000 iterations (return to monitor)
        if (count >= 1000) break;
    }

    gpu_set_fg(GPU_BRIGHT_CYAN);
    gpu_puts_at(18, 5, "Program finished! Returning to monitor.");

    return 0;
}
