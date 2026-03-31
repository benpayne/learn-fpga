#include <femtorv32.h>

#define SDRAM_BASE 0x800000

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
static void out_dec(int v) {
    if (v >= 1000000) { gpu_putc('0'+v/1000000); putchar('0'+v/1000000); v %= 1000000; }
    if (v >= 100000) { gpu_putc('0'+v/100000); putchar('0'+v/100000); v %= 100000; }
    if (v >= 10000) { gpu_putc('0'+v/10000); putchar('0'+v/10000); v %= 10000; }
    if (v >= 1000) { gpu_putc('0'+v/1000); putchar('0'+v/1000); v %= 1000; }
    if (v >= 100) { gpu_putc('0'+v/100); putchar('0'+v/100); v %= 100; }
    if (v >= 10) { gpu_putc('0'+v/10); putchar('0'+v/10); v %= 10; }
    gpu_putc('0'+v); putchar('0'+v);
}

static int test_count = 0, fail_count = 0;
static void test_result(const char *name, int pass) {
    test_count++;
    if (pass) { gpu_set_fg(GPU_BRIGHT_GREEN); out_puts("  PASS: "); }
    else      { gpu_set_fg(GPU_BRIGHT_RED);   out_puts("  FAIL: "); fail_count++; }
    gpu_set_fg(GPU_WHITE); out_puts(name); out_puts("\n");
}

int main(void) {
    gpu_clear();
    gpu_set_fg(GPU_BRIGHT_CYAN); gpu_set_bg(GPU_BLACK);
    out_puts("SDRAM Test - EM638325 (8MB, 32-bit)\n");
    out_puts("====================================\n\n");

    // Use offset 0x100000 (1MB) to avoid overwriting our own code at SDRAM_BASE
    volatile uint32_t *sdram = (volatile uint32_t *)(SDRAM_BASE + 0x100000);

    // Test 1: Single word
    sdram[0] = 0xDEADBEEF;
    test_result("Single word 0xDEADBEEF", sdram[0] == 0xDEADBEEF);

    // Test 2: Multiple words
    sdram[0]=0x11111111; sdram[1]=0x22222222; sdram[2]=0x33333333; sdram[3]=0x44444444;
    int ok = (sdram[0]==0x11111111)&&(sdram[1]==0x22222222)&&(sdram[2]==0x33333333)&&(sdram[3]==0x44444444);
    test_result("4 words at offset 0", ok);

    // Test 3: 256 sequential words
    for (int i = 0; i < 256; i++) sdram[i] = i;
    ok = 1;
    for (int i = 0; i < 256; i++) {
        if (sdram[i] != (uint32_t)i) { ok = 0; break; }
    }
    test_result("256 sequential words", ok);

    // Test 4: 1K words at 1MB offset
    volatile uint32_t *far = (volatile uint32_t *)(SDRAM_BASE + 0x200000);
    for (int i = 0; i < 1024; i++) far[i] = 0xCAFE0000 | i;
    ok = 1;
    for (int i = 0; i < 1024; i++) {
        if (far[i] != (0xCAFE0000 | i)) { ok = 0; break; }
    }
    test_result("1K words at 1MB offset", ok);

    // Test 5: Walking ones
    for (int i = 0; i < 32; i++) sdram[200+i] = 1U << i;
    ok = 1;
    for (int i = 0; i < 32; i++) {
        if (sdram[200+i] != (1U << i)) { ok = 0; break; }
    }
    test_result("Walking ones (data bus)", ok);

    // Test 6: Address uniqueness (all power-of-2 offsets up to 8MB)
    for (int bit = 0; bit < 21; bit++) sdram[1U << bit] = 0xAA000000 | (1U << bit);
    sdram[0] = 0xBB000000;
    ok = 1;
    for (int bit = 0; bit < 21; bit++) {
        uint32_t exp = 0xAA000000 | (1U << bit);
        if (sdram[1U << bit] != exp) {
            ok = 0;
            out_puts("    bit "); out_dec(bit); out_puts(" aliased\n");
            break;
        }
    }
    test_result("Address uniqueness (21 bits = 8MB)", ok);

    // Test 7: Large block write/verify (64KB)
    out_puts("  Writing 64KB...");
    volatile uint32_t *block = (volatile uint32_t *)(SDRAM_BASE + 0x300000);
    for (int i = 0; i < 16384; i++) block[i] = i ^ 0x55AA55AA;
    out_puts(" verifying...");
    ok = 1;
    int first_err = -1;
    for (int i = 0; i < 16384; i++) {
        if (block[i] != ((uint32_t)i ^ 0x55AA55AA)) {
            ok = 0; first_err = i; break;
        }
    }
    out_puts("\n");
    test_result("64KB block at 2MB", ok);
    if (!ok) {
        out_puts("    First error at word "); out_dec(first_err); out_puts("\n");
    }

    // Summary
    out_puts("\n");
    out_dec(test_count); out_puts(" tests, ");
    out_dec(fail_count); out_puts(" failures\n");
    if (fail_count == 0) {
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts("ALL PASSED - SDRAM working!\n");
    }

    return 0;
}
