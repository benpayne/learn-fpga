// sdram_memtest.c - Serial-only SDRAM memory test
//
// Adapted from sdram_test.c for the colorlight_i5_llm profile, which has
// no GPU: all output goes to the UART only, via printf()/putchar() from
// <femtorv32.h>.
//
// This program is uploaded via the BIOS monitor's XMODEM loader ('L') and
// executed in place with 'G', both of which default to address 0x800000
// (see FEMTORV32/FIRMWARE/examples/upload_sdram.ld). Since the program
// itself lives at the start of SDRAM, it must not overwrite its own code,
// data or stack while testing memory.
//
// Rather than compute the program's exact footprint from the linker _end
// symbol (which would also have to account for .bss placement), this test
// simply skips the first 1MB of SDRAM (0x800000-0x8FFFFF) -- far larger
// than this program will ever be -- and tests the remainder of the usable
// range up to 0xEFFFFF, the last byte before the 1MB stack region at
// 0xF00000-0xFFFFF0 (see memory map in CLAUDE.md).
//
// Patterns tested (each reported PASS/FAIL with per-error detail):
//   1. Walking ones on the data bus, sampled at evenly spaced addresses
//      across the full range (stuck-at data lines fail at every address,
//      so a sparse sample is sufficient and keeps the test fast).
//   2. Address-as-data: every word stores its own address. This is a
//      full-range, single-pass test and is the most sensitive to
//      address-line stuck/shorted faults -- the most likely SDRAM wiring
//      problem.
//   3-6. Full-range fill/verify with constants 0x00000000, 0xFFFFFFFF,
//      0x55555555, 0xAAAAAAAA.
//
// A sustained transfer rate is measured with cycles() across the
// full-range passes (address-as-data + the four constant patterns, write
// and read counted together) and reported in KB/sec and MB/sec.

#include <femtorv32.h>

#define TEST_START   0x900000u   /* skip first 1MB: program code + margin */
#define TEST_END     0xEFFFFFu   /* inclusive; stack region starts above this */
#define TEST_BYTES   (TEST_END - TEST_START + 1u)
#define TEST_WORDS   (TEST_BYTES / 4u)

#define CPU_HZ       25000000u   /* colorlight_i5_llm system clock */

static uint32_t g_total_errors   = 0;
static uint32_t g_pattern_errors = 0;  /* errors found by the current pattern */

/* Cumulative byte/cycle totals across the full-range passes, used to
 * report a sustained transfer rate at the end. */
static uint64_t g_bulk_bytes  = 0;
static uint64_t g_bulk_cycles = 0;

static void report_error(uint32_t addr, uint32_t expected, uint32_t got) {
    g_pattern_errors++;
    g_total_errors++;
    if (g_pattern_errors <= 10) {
        printf("    error at 0x%x: expected 0x%x, got 0x%x\n",
               (unsigned int)addr, (unsigned int)expected, (unsigned int)got);
    } else if (g_pattern_errors == 11) {
        printf("    (further errors for this pattern suppressed)\n");
    }
}

/* Fill the full test range with a constant pattern and verify it reads
 * back correctly. */
static void test_full_range_constant(uint32_t pattern) {
    volatile uint32_t *p = (volatile uint32_t *)TEST_START;
    g_pattern_errors = 0;

    uint64_t t0 = cycles();
    for (uint32_t i = 0; i < TEST_WORDS; i++) p[i] = pattern;
    for (uint32_t i = 0; i < TEST_WORDS; i++) {
        uint32_t got = p[i];
        if (got != pattern) report_error(TEST_START + i * 4u, pattern, got);
    }
    uint64_t t1 = cycles();

    g_bulk_bytes  += (uint64_t)TEST_BYTES * 2u;  /* write + read */
    g_bulk_cycles += (t1 - t0);

    printf("[%s] pattern 0x%x: %u errors\n",
           g_pattern_errors == 0 ? "PASS" : "FAIL",
           (unsigned int)pattern, (unsigned int)g_pattern_errors);
}

/* Each word stores its own address. Catches address-line stuck/shorted
 * faults, the most likely SDRAM wiring problem. */
static void test_address_as_data(void) {
    volatile uint32_t *p = (volatile uint32_t *)TEST_START;
    g_pattern_errors = 0;

    uint64_t t0 = cycles();
    for (uint32_t i = 0; i < TEST_WORDS; i++) {
        p[i] = TEST_START + i * 4u;
    }
    for (uint32_t i = 0; i < TEST_WORDS; i++) {
        uint32_t addr = TEST_START + i * 4u;
        uint32_t got = p[i];
        if (got != addr) report_error(addr, addr, got);
    }
    uint64_t t1 = cycles();

    g_bulk_bytes  += (uint64_t)TEST_BYTES * 2u;
    g_bulk_cycles += (t1 - t0);

    printf("[%s] address-as-data: %u errors\n",
           g_pattern_errors == 0 ? "PASS" : "FAIL", (unsigned int)g_pattern_errors);
}

/* Walking ones on the data bus, sampled at evenly spaced addresses across
 * the full range (first word, last word, and points in between). Not
 * timed/counted toward the sustained transfer rate -- it is a sparse,
 * latency-bound test, not representative of bulk throughput. */
#define WALK_SAMPLES 17
static void test_walking_ones(void) {
    volatile uint32_t *p = (volatile uint32_t *)TEST_START;
    g_pattern_errors = 0;

    for (int s = 0; s < WALK_SAMPLES; s++) {
        uint32_t word_idx = s * (TEST_WORDS - 1u) / (WALK_SAMPLES - 1u);
        uint32_t addr = TEST_START + word_idx * 4u;
        for (int bit = 0; bit < 32; bit++) {
            uint32_t pattern = 1u << bit;
            p[word_idx] = pattern;
            uint32_t got = p[word_idx];
            if (got != pattern) report_error(addr, pattern, got);
        }
    }

    printf("[%s] walking ones (%d sample addresses): %u errors\n",
           g_pattern_errors == 0 ? "PASS" : "FAIL", WALK_SAMPLES, (unsigned int)g_pattern_errors);
}

int main(void) {
    printf("\n");
    printf("SDRAM Memory Test (serial-only) - EM638325 8MB\n");
    printf("================================================\n");
    printf("Tested range: 0x%x - 0x%x (%u bytes = %u MB)\n",
           (unsigned int)TEST_START, (unsigned int)TEST_END,
           (unsigned int)TEST_BYTES, (unsigned int)(TEST_BYTES / (1024u * 1024u)));
    printf("(0x800000-0x8FFFFF reserved: this program runs from SDRAM\n");
    printf(" starting at 0x800000, so that 1MB is NOT tested here.)\n\n");

    test_walking_ones();
    test_address_as_data();
    test_full_range_constant(0x00000000u);
    test_full_range_constant(0xFFFFFFFFu);
    test_full_range_constant(0x55555555u);
    test_full_range_constant(0xAAAAAAAAu);

    printf("\nSummary\n");
    printf("-------\n");
    printf("Bytes tested per pass: %u (%u MB); total errors: %u\n",
           (unsigned int)TEST_BYTES, (unsigned int)(TEST_BYTES / (1024u * 1024u)),
           (unsigned int)g_total_errors);

    if (g_bulk_cycles > 0) {
        uint64_t bytes_per_sec64 = (g_bulk_bytes * (uint64_t)CPU_HZ) / g_bulk_cycles;
        uint32_t bytes_per_sec   = (uint32_t)bytes_per_sec64;
        uint32_t kb_per_sec      = bytes_per_sec / 1024u;
        uint32_t mb_whole        = bytes_per_sec / 1000000u;
        uint32_t mb_frac         = (bytes_per_sec % 1000000u) / 10000u; /* 2 decimal digits */

        printf("Sustained transfer rate (write+read, full-range passes):\n");
        printf("  %u bytes in %u cycles @ %u Hz\n",
               (unsigned int)g_bulk_bytes, (unsigned int)g_bulk_cycles, (unsigned int)CPU_HZ);
        printf("  = %u KB/sec (%u.%u MB/sec)\n",
               (unsigned int)kb_per_sec, (unsigned int)mb_whole, (unsigned int)mb_frac);
    }

    if (g_total_errors == 0) {
        printf("\nALL TESTS PASSED - SDRAM OK\n");
    } else {
        printf("\nFAILED - %u total errors detected\n", (unsigned int)g_total_errors);
    }

    return 0;
}
