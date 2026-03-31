// sd_test.c - Simple SD card hardware test
// Just initializes the card and reads sector 0 (MBR)

#include <femtorv32.h>

// SD card functions from spi_sd.c
extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_clear(void) { GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN | GPU_CTRL_80COL); wait_cycles(5000); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }
static inline void gpu_set_bg(int c) { GPU_WRITE(GPU_REG_BG_COLOR, c); }

static void out_puts(const char *s) {
    while (*s) {
        if (*s == '\n') { gpu_putc('\r'); gpu_putc('\n'); putchar('\r'); putchar('\n'); }
        else { gpu_putc(*s); putchar(*s); }
        s++;
    }
}
static void out_hex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) {
        int n = (v >> i) & 0xF;
        char c = n < 10 ? '0' + n : 'A' + n - 10;
        gpu_putc(c); putchar(c);
    }
}
static void out_hex8(uint8_t v) {
    int hi = (v >> 4) & 0xF, lo = v & 0xF;
    char c1 = hi < 10 ? '0' + hi : 'A' + hi - 10;
    char c2 = lo < 10 ? '0' + lo : 'A' + lo - 10;
    gpu_putc(c1); putchar(c1);
    gpu_putc(c2); putchar(c2);
}

int main(void) {
    gpu_clear();
    gpu_set_fg(GPU_BRIGHT_CYAN); gpu_set_bg(GPU_BLACK);
    out_puts("SD Card Hardware Test\n");
    out_puts("=====================\n\n");

    gpu_set_fg(GPU_YELLOW);
    out_puts("Initializing SD card...\n");

    int result = sd_init();
    if (result) {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("FAIL: sd_init returned ");
        out_hex(result);
        out_puts("\n");
        out_puts("Check: is SD card inserted?\n");
        return 1;
    }

    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("SD card initialized OK!\n\n");

    // Read sector 0 (MBR)
    gpu_set_fg(GPU_YELLOW);
    out_puts("Reading sector 0 (MBR)...\n");

    uint8_t buffer[512];
    for (int i = 0; i < 512; i++) buffer[i] = 0;

    result = sd_readsector(0, buffer, 1);
    if (result == 0) {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("FAIL: could not read sector 0\n");
        return 1;
    }

    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("Read OK! First 128 bytes of MBR:\n\n");

    // Display hex dump
    gpu_set_fg(GPU_LIGHT_GRAY);
    for (int row = 0; row < 8; row++) {
        gpu_set_fg(GPU_CYAN);
        out_hex8(row * 16);
        out_puts(": ");
        gpu_set_fg(GPU_LIGHT_GRAY);
        for (int col = 0; col < 16; col++) {
            out_hex8(buffer[row * 16 + col]);
            gpu_putc(' '); putchar(' ');
        }
        gpu_set_fg(GPU_GREEN);
        for (int col = 0; col < 16; col++) {
            uint8_t c = buffer[row * 16 + col];
            char ch = (c >= 0x20 && c < 0x7F) ? c : '.';
            gpu_putc(ch); putchar(ch);
        }
        out_puts("\n");
    }

    // Check MBR signature (0x55AA at offset 510-511)
    out_puts("\n");
    if (buffer[510] == 0x55 && buffer[511] == 0xAA) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("MBR signature: 55 AA (valid)\n");
    } else {
        gpu_set_fg(GPU_YELLOW);
        out_puts("MBR signature: ");
        out_hex8(buffer[510]); out_puts(" "); out_hex8(buffer[511]);
        out_puts(" (not standard MBR)\n");
    }

    return 0;
}
