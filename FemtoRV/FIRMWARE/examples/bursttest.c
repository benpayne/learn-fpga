// bursttest.c — Comprehensive SDRAM burst reader diagnostic
//
// Tests:
// 1. CPU write/read of framebuffer area (baseline)
// 2. Enable display_mode=2, wait for burst reads, return to text
// 3. Verify CPU data not corrupted by burst reads
// 4. Fill full framebuffer (stride=512 words), verify all lines
// 5. Run burst mode again, verify no corruption across all lines

#include <femtorv32.h>

static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }

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
        char c = n < 10 ? '0' + n : 'a' + n - 10;
        gpu_putc(c); putchar(c);
    }
}

static void out_dec(int v) {
    if (v < 0) { gpu_putc('-'); putchar('-'); v = -v; }
    if (v == 0) { gpu_putc('0'); putchar('0'); return; }
    char buf[11]; int n = 0;
    while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
    while (n > 0) { gpu_putc(buf[n-1]); putchar(buf[n-1]); n--; }
}

#define FB_BASE       0xA00000
#define STRIDE_WORDS  512       // 2KB per line (matches fetch engine)
#define LINE_WORDS    320       // Active words per line (640 pixels @ 16bpp)
#define NUM_LINES     10        // Test 10 lines (enough to verify, fast to fill)

// Verify a range of SDRAM, return error count
static int verify_pattern(volatile uint32_t *base, int count, uint32_t pattern_base) {
    int errors = 0;
    for (int i = 0; i < count; i++) {
        uint32_t expected = pattern_base + i;
        uint32_t got = base[i];
        if (got != expected) {
            if (errors < 3) {
                out_puts("  ERR["); out_dec(i); out_puts("]=0x");
                out_hex(got); out_puts(" exp=0x"); out_hex(expected);
                out_puts("\n");
            }
            errors++;
        }
    }
    return errors;
}

int main(void) {
    volatile uint32_t *fb = (volatile uint32_t *)FB_BASE;

    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("SDRAM Burst Test v2\n");
    out_puts("===================\n\n");

    // ---- Test 1: Fill framebuffer with stride-aligned pattern ----
    gpu_set_fg(GPU_WHITE);
    out_puts("1. Filling "); out_dec(NUM_LINES); out_puts(" lines (stride=");
    out_dec(STRIDE_WORDS); out_puts("w)...\n");

    for (int line = 0; line < NUM_LINES; line++) {
        volatile uint32_t *row = fb + line * STRIDE_WORDS;
        uint32_t pat = 0xA5000000 | (line << 16);
        for (int i = 0; i < LINE_WORDS; i++) {
            row[i] = pat | i;
        }
    }
    out_puts("   Done\n");

    // ---- Test 2: CPU verify before burst ----
    out_puts("2. Pre-burst verify...\n");
    int total_errors = 0;
    for (int line = 0; line < NUM_LINES; line++) {
        volatile uint32_t *row = fb + line * STRIDE_WORDS;
        uint32_t pat = 0xA5000000 | (line << 16);
        int err = verify_pattern(row, LINE_WORDS, pat);
        if (err > 0) {
            out_puts("   Line "); out_dec(line); out_puts(": ");
            out_dec(err); out_puts(" errors\n");
        }
        total_errors += err;
    }
    if (total_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("   ALL OK\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("   FAIL: "); out_dec(total_errors); out_puts(" total errors\n");
    }

    // ---- Test 3: Enable burst mode for 2 seconds ----
    gpu_set_fg(GPU_WHITE);
    out_puts("3. Enabling display_mode=2...\n");
    GPU_WRITE(0x0D, 2);

    out_puts("4. Waiting 2 seconds with bursts active...\n");
    // Each iteration stalls ~340 cycles (burst) + ~5 cycles (write) = ~345 cycles
    // 100K iterations × 345 = 34.5M cycles / 25MHz = ~1.4 seconds
    for (volatile int i = 0; i < 100000; i++);

    GPU_WRITE(0x0D, 0);
    out_puts("5. Back to text mode\n");

    // ---- Test 4: Post-burst verify ----
    out_puts("6. Post-burst verify...\n");
    total_errors = 0;
    for (int line = 0; line < NUM_LINES; line++) {
        volatile uint32_t *row = fb + line * STRIDE_WORDS;
        uint32_t pat = 0xA5000000 | (line << 16);
        int err = verify_pattern(row, LINE_WORDS, pat);
        if (err > 0) {
            out_puts("   Line "); out_dec(line); out_puts(": ");
            out_dec(err); out_puts(" errors\n");
        }
        total_errors += err;
    }
    if (total_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("   ALL OK - burst reads did NOT corrupt data\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("   FAIL: "); out_dec(total_errors); out_puts(" errors after burst\n");
    }

    // ---- Test 5: Check specific SDRAM row boundaries ----
    // Row boundary at word 256 within each stride-512 line
    gpu_set_fg(GPU_WHITE);
    out_puts("7. Row boundary check (word 254-258 each line)...\n");
    int boundary_errors = 0;
    for (int line = 0; line < NUM_LINES; line++) {
        volatile uint32_t *row = fb + line * STRIDE_WORDS;
        uint32_t pat = 0xA5000000 | (line << 16);
        for (int i = 254; i < 258 && i < LINE_WORDS; i++) {
            uint32_t expected = pat | i;
            uint32_t got = row[i];
            if (got != expected) {
                out_puts("  L"); out_dec(line); out_puts("["); out_dec(i);
                out_puts("]=0x"); out_hex(got); out_puts("\n");
                boundary_errors++;
            }
        }
    }
    if (boundary_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("   Row boundaries OK\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("   "); out_dec(boundary_errors); out_puts(" boundary errors\n");
    }

    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("\nDone.\n");
    return 0;
}
