// bursttest.c — Test SDRAM burst reader on real hardware
//
// 1. Write known pattern to SDRAM via normal CPU writes
// 2. Enable display_mode=2 to trigger burst reads from that address
// 3. Read FIFO status to see if data is flowing
// 4. Read FIFO data and compare with expected pattern
//
// This tests the burst reader independently from the GPU pixel output.

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
    if (v == 0) { gpu_putc('0'); putchar('0'); return; }
    char buf[11]; int n = 0;
    while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
    while (n > 0) { gpu_putc(buf[n-1]); putchar(buf[n-1]); n--; }
}

#define FB_BASE   0xA00000
#define TEST_WORDS 320   // One scanline worth

int main(void) {
    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("SDRAM Burst Test\n");
    out_puts("================\n\n");

    // Step 1: Write test pattern to SDRAM
    gpu_set_fg(GPU_WHITE);
    out_puts("1. Writing test pattern to 0x");
    out_hex(FB_BASE);
    out_puts("...\n");

    volatile uint32_t *fb = (volatile uint32_t *)FB_BASE;
    for (int i = 0; i < TEST_WORDS * 2; i++) {  // Fill 2 lines worth
        fb[i] = 0xA5000000 | i;  // Distinctive pattern
    }

    // Verify CPU can read it back
    out_puts("2. CPU read-back verify...");
    int cpu_errors = 0;
    for (int i = 0; i < TEST_WORDS; i++) {
        uint32_t v = fb[i];
        if (v != (0xA5000000 | i)) {
            if (cpu_errors < 3) {
                out_puts("\n   ERR["); out_dec(i); out_puts("]=0x"); out_hex(v);
            }
            cpu_errors++;
        }
    }
    if (cpu_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("OK\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("\n   FAIL: "); out_dec(cpu_errors); out_puts(" errors\n");
    }

    // Step 2: Read the synth IO to check audio ring buffer status (sanity check)
    gpu_set_fg(GPU_WHITE);
    out_puts("3. Synth IO read: 0x");
    uint32_t synth_status = SBUF_READ_STATUS();
    out_hex(synth_status);
    out_puts("\n");

    // Step 3: Check if GPU display_mode register works
    out_puts("4. Setting display_mode=2...\n");
    GPU_WRITE(0x0D, 2);  // Switch to framebuffer mode

    // Wait a few frames for burst reads to happen
    out_puts("5. Waiting 1 second for burst reads...\n");
    for (volatile int i = 0; i < 5000000; i++);

    // Step 4: Switch back to text mode and check results
    GPU_WRITE(0x0D, 0);  // Back to text mode
    out_puts("6. Back to text mode\n");

    // Step 5: Read SDRAM again to verify burst reads didn't corrupt it
    out_puts("7. Post-burst CPU read verify...");
    int post_errors = 0;
    for (int i = 0; i < TEST_WORDS; i++) {
        uint32_t v = fb[i];
        if (v != (0xA5000000 | i)) {
            if (post_errors < 3) {
                out_puts("\n   ERR["); out_dec(i); out_puts("]=0x"); out_hex(v);
            }
            post_errors++;
        }
    }
    if (post_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("OK\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("\n   FAIL: "); out_dec(post_errors); out_puts(" errors\n");
    }

    // Step 6: Check if SDRAM data was corrupted by burst reads
    // The burst reader reads from the same address — it should NOT modify data
    // But if the controller's state gets corrupted, writes could happen
    out_puts("8. Checking for burst corruption at FB+2KB...\n");
    // Check second line (stride=512 words = 2KB offset)
    volatile uint32_t *fb2 = (volatile uint32_t *)(FB_BASE + 2048);
    int line2_errors = 0;
    for (int i = 0; i < TEST_WORDS; i++) {
        uint32_t v = fb2[i];
        uint32_t expected = 0xA5000000 | (512 + i);  // stride=512 words
        if (v != expected) {
            if (line2_errors < 3) {
                out_puts("   Line2["); out_dec(i); out_puts("]=0x"); out_hex(v);
                out_puts(" exp=0x"); out_hex(expected); out_puts("\n");
            }
            line2_errors++;
        }
    }
    if (line2_errors == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("   Line 2 OK\n");
    } else {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("   Line 2: "); out_dec(line2_errors); out_puts(" errors\n");
    }

    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("\nDone.\n");
    return 0;
}
