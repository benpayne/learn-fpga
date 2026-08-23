/*
 * profile.c -- per-category cycle accounting for llama2 inference
 * (T040-T042). Implements profile.h EXACTLY; see that file for the API
 * contract. See specs/003-llama2-minimal-soc/contracts/console-interface.md
 * for the Performance Report output format.
 *
 * NESTING POLICY (read this before calling prof_begin/prof_end anywhere)
 * ------------------------------------------------------------------------
 * Categories are made mutually exclusive by construction using an
 * explicit call stack, rather than by forbidding nesting outright. This
 * matters because matmul() is realistically called from inside the
 * attention path (e.g. Q/K/V projections, the output projection), so a
 * "no nesting allowed" rule would be violated by the real call graph.
 *
 * The stack holds the currently "open" categories, innermost on top.
 * Only the top-of-stack category is ever accruing time. When a new
 * category is pushed (prof_begin), the parent that was on top is first
 * credited for the time elapsed since it started/resumed; the child then
 * starts its own clock from "now". When the child is popped (prof_end),
 * it is credited for its own elapsed time, and the parent's clock is
 * restarted from "now" (its clock had been paused, not stopped, while
 * the child ran). Consequence: cat_total[X] is exactly the wall-clock
 * time X was innermost-active. Categories can never double-count cycles
 * against each other by construction, so percentages cannot sum above
 * 100% because of overlap; the only way sum(named) can exceed the
 * run-bracket total is a genuine caller bug (e.g. prof_run_begin() called
 * AFTER some prof_begin/prof_end pairs already ran, or mismatched
 * begin/end calls) -- prof_report() detects that case explicitly (T041)
 * and prints a loud warning instead of silently producing a >100% report.
 *
 * prof_enable(0) short-circuits prof_begin/prof_end to a single branch
 * (no cycles() call, no stack touch) so disabled profiling does not
 * distort the generation-rate measurement (T040). Because disabling
 * skips all stack bookkeeping, prof_enable() must only be toggled
 * between runs -- outside of any prof_begin/prof_end nesting and outside
 * a prof_run_begin/prof_run_end bracket -- never mid-stack.
 */

#include "profile.h"
#include <femtorv32.h>

/* Matches the CPU_HZ convention used by model_load.c / sd_bench.c in this
 * same directory/example tree (Colorlight i5 target runs at a fixed
 * 25MHz with no PLL on the CPU clock -- see CLAUDE.md). */
#define CPU_HZ 25000000u

#define PROF_MAX_DEPTH 8
#define COLUMN_WIDTH   13   /* matches the console-interface.md example alignment */

static uint64_t   cat_total[PROF_NCAT];
static prof_cat_t stack[PROF_MAX_DEPTH];
static int        stack_depth   = 0;
static uint64_t   segment_start = 0;
static int        enabled       = 1;

static uint64_t run_start_cycles = 0;
static uint64_t run_total_cycles = 0;
static uint32_t run_tokens       = 0;
static int      run_active       = 0;

static const char *const cat_names[PROF_NCAT] = {
    "matmul", "attention", "rmsnorm", "rope", "sample", "att_score", "att_soft", "att_sum",
    "quant"
};

/* -------------------------------------------------------------- lifecycle */

void prof_reset(void) {
    int i;
    for (i = 0; i < PROF_NCAT; i++)
        cat_total[i] = 0;
    stack_depth      = 0;
    segment_start    = 0;
    run_start_cycles = 0;
    run_total_cycles = 0;
    run_tokens       = 0;
    run_active       = 0;
}

void prof_enable(int on) { enabled = on ? 1 : 0; }
int  prof_enabled(void)  { return enabled; }

/* ------------------------------------------------------- category timing */

void prof_begin(prof_cat_t c) {
    uint64_t now;
    if (!enabled)
        return;
    if (c < 0 || c >= PROF_NCAT)
        return; /* defensive: ignore an out-of-range category */

    now = cycles();
    if (stack_depth > 0) {
        /* Pause the parent: credit it for the segment that just ended. */
        cat_total[stack[stack_depth - 1]] += now - segment_start;
    }
    if (stack_depth < PROF_MAX_DEPTH) {
        stack[stack_depth++] = c;
    }
    /* If the stack is full, we do not push (defensive against runaway
     * recursion); whatever IS on top still gets a correct fresh segment
     * start below, so no cycles are lost or double-counted -- the only
     * effect is that this particular nesting level's identity is not
     * separately tracked. */
    segment_start = now;
}

void prof_end(prof_cat_t c) {
    uint64_t now;
    (void)c; /* expected to match the popped frame; not enforced here --
              * we always credit whatever is actually on top of the
              * stack, which is the source of truth. */
    if (!enabled)
        return;
    if (stack_depth == 0)
        return; /* unmatched end: ignore defensively rather than corrupt state */

    now = cycles();
    cat_total[stack[stack_depth - 1]] += now - segment_start;
    stack_depth--;
    segment_start = now; /* resume point for the newly-exposed parent, if any */
}

/* ------------------------------------------------------------ run bracket */

void prof_run_begin(void) {
    run_start_cycles = cycles();
    run_total_cycles = 0;
    run_tokens       = 0;
    run_active       = 1;
}

void prof_run_end(uint32_t tokens_generated) {
    uint64_t now = cycles();
    run_total_cycles = run_active ? (now - run_start_cycles) : 0;
    run_tokens = tokens_generated;
    run_active = 0;
}

uint64_t prof_total_cycles(void) {
    return run_total_cycles;
}

/* --------------------------------------------------------- report helpers
 * printf here supports ONLY %s %x %d %u %c -- no %f, no field width/
 * precision. All rates/percentages are computed as scaled integers, and
 * anything that must carry a full uint64_t (raw cycle counts can exceed
 * 2^32 well within a normal run at 25MHz) is printed digit-by-digit
 * rather than truncated through a 32-bit %u/%d.
 */

static void print_u64_dec(uint64_t v) {
    char buf[21]; /* max 20 digits for a 64-bit value, + NUL */
    int  i = 20;
    buf[20] = '\0';
    if (v == 0) {
        putchar('0');
        return;
    }
    while (v > 0) {
        buf[--i] = (char)('0' + (int)(v % 10));
        v /= 10;
    }
    print_string(&buf[i]);
}

/* Right-pads a category name with spaces to COLUMN_WIDTH (printf has no
 * field-width specifier), preceded by the report's 2-space indent. */
static void print_name_padded(const char *name) {
    int n = 0;
    const char *p;
    printf("  %s", name);
    for (p = name; *p; p++)
        n++;
    while (n < COLUMN_WIDTH) {
        putchar(' ');
        n++;
    }
}

/* value*1000/total as an integer in "tenths of a percent" (0..1000);
 * printing x/10 "." x%10 gives one decimal digit of percentage, matching
 * the "58.1%" style in console-interface.md. Guards against overflowing
 * the value*1000 intermediate for extreme 64-bit cycle counts by scaling
 * both operands down together first -- only relevant for counts
 * approaching 2^64 (many centuries of continuous runtime at 25MHz), but
 * cheap to make correct rather than assumed away. */
static uint32_t pct_tenths(uint64_t value, uint64_t total) {
    if (total == 0)
        return 0;
    while (value > (~(uint64_t)0) / 1000) {
        value >>= 1;
        total >>= 1;
        if (total == 0)
            return 1000;
    }
    return (uint32_t)((value * 1000 + total / 2) / total);
}

/* ------------------------------------------------------------------ report */

void prof_report(void) {
    uint64_t total = run_total_cycles;
    uint64_t sum_named = 0;
    uint64_t other;
    uint64_t elapsed_ms, rate_x100;
    int      i;
    int      largest_idx = -2; /* -2 = unset, -1 = "other", else index into cat_names */
    uint64_t largest_val = 0;

    for (i = 0; i < PROF_NCAT; i++)
        sum_named += cat_total[i];

    if (total == 0) {
        printf("prof_report: no run recorded (call prof_run_begin/prof_run_end)\r\n");
        return;
    }

    /* T041: "other" is a residual, never estimated. A negative residual
     * (sum_named > total) is proof of double counting -- e.g. mismatched
     * begin/end pairs, or categories timed outside the run bracket. Warn
     * loudly instead of printing a nonsensical negative percentage. */
    if (sum_named > total) {
        printf("*** WARNING: profiled categories (");
        print_u64_dec(sum_named);
        printf(" cycles) EXCEED total run cycles (");
        print_u64_dec(total);
        printf(") -- double counting detected! Category percentages below\r\n");
        printf("    are still printed for diagnosis; treat 'other'/'coverage' as invalid. ***\r\n");
        other = 0;
    } else {
        other = total - sum_named;
    }

    elapsed_ms = (total * 1000u) / CPU_HZ;
    rate_x100  = elapsed_ms ? ((uint64_t)run_tokens * 100000ull) / elapsed_ms : 0;

    printf("tokens: %d in %d.%d s (%d.%d%d tok/s)\r\n",
           (int)run_tokens,
           (int)(elapsed_ms / 1000), (int)((elapsed_ms % 1000) / 100),
           (int)(rate_x100 / 100), (int)((rate_x100 / 10) % 10), (int)(rate_x100 % 10));

    for (i = 0; i < PROF_NCAT; i++) {
        uint32_t pt = pct_tenths(cat_total[i], total);
        print_name_padded(cat_names[i]);
        printf("%d.%d%%  (", (int)(pt / 10), (int)(pt % 10));
        print_u64_dec(cat_total[i]);
        printf(" cycles)\r\n");
        if (largest_idx == -2 || cat_total[i] > largest_val) {
            largest_val = cat_total[i];
            largest_idx = i;
        }
    }
    {
        uint32_t pt = pct_tenths(other, total);
        print_name_padded("other");
        printf("%d.%d%%  (", (int)(pt / 10), (int)(pt % 10));
        print_u64_dec(other);
        printf(" cycles)\r\n");
        if (other > largest_val) {
            largest_val = other;
            largest_idx = -1;
        }
    }

    printf("largest: %s\r\n", (largest_idx == -1) ? "other" : cat_names[largest_idx]);

    {
        /* coverage = 100% - other%, per console-interface.md */
        uint32_t other_pt    = pct_tenths(other, total);
        uint32_t coverage_pt = (other_pt <= 1000) ? (1000 - other_pt) : 0;
        printf("coverage: %d.%d%%\r\n", (int)(coverage_pt / 10), (int)(coverage_pt % 10));
    }
}
