// bench.c — CPU Performance Benchmark for FemtoRV
//
// Tests:
// 1. Dhrystone-like integer benchmark (loops/sec → approximate DMIPS)
// 2. Memory copy bandwidth (SDRAM to SDRAM)
// 3. Floating point (hardware FPU)
// 4. Register-only integer throughput
//
// Uses hardware timer for accurate measurement.

#include "retrokernel.h"
#include <string.h>

// Timer: counts up at 25MHz
static inline void timer_start(void) { IO_OUT(IO_TIMER, 0xFFFFFFFF); }
static inline uint32_t timer_read(void) { return IO_IN(IO_TIMER); }

static void print_result(const char *name, uint32_t ticks, uint32_t iterations) {
    uint32_t us = ticks / 25;  // 25 ticks per microsecond
    uint32_t ms = us / 1000;

    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts(name);
    rk_set_fg(GPU_WHITE);
    rk_puts(": ");
    rk_putdec(iterations);
    rk_puts(" iters in ");
    rk_putdec(ms);
    rk_puts("ms (");
    if (ms > 0) {
        uint32_t per_sec = (iterations * 1000) / ms;
        rk_putdec(per_sec);
        rk_puts("/sec");
    }
    rk_puts(")\n");
}

// ---- Test 1: Dhrystone-like integer workload ----
// Simple integer operations: array access, compare, branch, add, multiply
static volatile int dhry_result;

static void test_dhrystone(void) {
    #define DHRY_LOOPS 100000
    int a = 1, b = 2, c = 3;
    int array[10] = {9,8,7,6,5,4,3,2,1,0};

    timer_start();
    uint32_t t0 = timer_read();

    for (int i = 0; i < DHRY_LOOPS; i++) {
        a = a + b * c;
        b = array[a & 7] + c;
        c = (a > b) ? a - b : b - a;
        array[i & 7] = a ^ b ^ c;
        if (c > 100) c = c - 50;
        a = a + array[(i+1) & 7];
    }

    uint32_t t1 = timer_read();
    dhry_result = a + b + c;  // Prevent optimization

    print_result("Integer", t1 - t0, DHRY_LOOPS);

    // Approximate DMIPS: Dhrystone 2.1 uses 1757 as VAX MIPS divider
    uint32_t ms = (t1 - t0) / 25000;
    if (ms > 0) {
        uint32_t loops_per_sec = (DHRY_LOOPS * 1000) / ms;
        uint32_t dmips_x100 = (loops_per_sec * 100) / 1757;
        rk_puts("  ~");
        rk_putdec(dmips_x100 / 100);
        rk_puts(".");
        rk_putdec((dmips_x100 % 100) / 10);
        rk_puts(" DMIPS (approx)\n");
    }
}

// ---- Test 2: Memory copy bandwidth ----
static void test_memcpy(void) {
    #define MEM_SIZE  (64 * 1024)  // 64KB copy
    #define MEM_LOOPS 10
    volatile uint32_t *src = (volatile uint32_t *)0x900000;
    volatile uint32_t *dst = (volatile uint32_t *)0x910000;

    // Fill source
    for (int i = 0; i < MEM_SIZE/4; i++) src[i] = i;

    timer_start();
    uint32_t t0 = timer_read();

    for (int loop = 0; loop < MEM_LOOPS; loop++) {
        for (int i = 0; i < MEM_SIZE/4; i++) {
            dst[i] = src[i];
        }
    }

    uint32_t t1 = timer_read();

    print_result("Memcpy 64KB", t1 - t0, MEM_LOOPS);

    uint32_t us = (t1 - t0) / 25;
    if (us > 0) {
        uint32_t bytes_total = MEM_SIZE * MEM_LOOPS;
        uint32_t kb_per_sec = (bytes_total / 1024) * 1000000 / us;
        rk_puts("  ");
        rk_putdec(kb_per_sec);
        rk_puts(" KB/sec\n");
    }
}

// ---- Test 3: Floating point ----
static volatile float fp_result;

static void test_float(void) {
    #define FP_LOOPS 100000

    float a = 1.0f, b = 0.5f, c = 0.1f;

    timer_start();
    uint32_t t0 = timer_read();

    for (int i = 0; i < FP_LOOPS; i++) {
        a = a * b + c;
        b = b + c * 0.99f;
        c = a - b * 0.5f;
        if (a > 1000.0f) a = 1.0f;
        if (b > 1000.0f) b = 0.5f;
    }

    uint32_t t1 = timer_read();
    fp_result = a + b + c;

    print_result("Float", t1 - t0, FP_LOOPS);

    uint32_t ms = (t1 - t0) / 25000;
    if (ms > 0) {
        uint32_t mflops_x10 = (FP_LOOPS * 3 * 10) / ms;  // ~3 FP ops per iter, result in KFLOPS
        rk_puts("  ~");
        rk_putdec(mflops_x10 / 10);
        rk_puts(".");
        rk_putdec(mflops_x10 % 10);
        rk_puts(" KFLOPS\n");
    }
}

// ---- Test 4: Pure register integer throughput ----
static void test_reg_int(void) {
    #define REG_LOOPS 1000000
    register int a = 1, b = 2, c = 3, d = 4;

    timer_start();
    uint32_t t0 = timer_read();

    for (int i = 0; i < REG_LOOPS; i++) {
        a = a + b;
        b = b ^ c;
        c = c + d;
        d = d - a;
    }

    uint32_t t1 = timer_read();
    dhry_result = a + b + c + d;

    print_result("Reg Int", t1 - t0, REG_LOOPS);

    uint32_t us = (t1 - t0) / 25;
    if (us > 0) {
        // 4 ops per iteration, result in MIPS
        uint32_t mips_x10 = ((uint32_t)REG_LOOPS * 4 * 10) / us;
        rk_puts("  ~");
        rk_putdec(mips_x10 / 10);
        rk_puts(".");
        rk_putdec(mips_x10 % 10);
        rk_puts(" MIPS (register ops)\n");
    }
}

int main(int argc, char **argv) {
    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts("FemtoRV Benchmark\n");
    rk_puts("=================\n");
    rk_set_fg(GPU_LIGHT_GRAY);
    rk_puts("CPU: RV32IMFC (petitbateau) @ 25MHz\n");
    rk_puts("RAM: 8MB SDRAM (cached, write-through)\n\n");

    test_reg_int();
    rk_putc('\n');
    test_dhrystone();
    rk_putc('\n');
    test_float();
    rk_putc('\n');
    test_memcpy();

    rk_putc('\n');
    rk_set_fg(GPU_BRIGHT_GREEN);
    rk_puts("Done.\n");

    return 0;
}
