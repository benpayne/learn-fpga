/*
 * acc_test.c -- standalone test for the int8 MatMul accelerator
 * (feature 004-int8-matmul-accel, T051/T052/T053).
 *
 * Runs the SAME matmul operation, on the SAME input, MANY times, both on
 * the accelerator and on the CPU (a hand-copy of runq.c's matmul_q8()
 * arithmetic -- see matmul_q8_ref() below for why it is a copy, not the
 * real function), and reports the DISTRIBUTION of outcomes, not a single
 * pass/fail verdict. This is the first program in this feature that
 * actually exercises the RTL on real hardware; llama2/'s
 * verify_fw_math.c (host-side) and runq_accel.bin (T059, full model)
 * exist alongside it but neither one is this: a minimal, single-operation,
 * serial-only bring-up test, deliberately small so a failure here points
 * straight at the accelerator rather than getting lost in a 5-layer
 * forward pass.
 *
 * *** WHY REPEAT THE SAME OPERATION INSTEAD OF JUST CHECKING ONCE (R27) ***
 * At the accelerator's measured 2.4% timing margin (25.61 MHz against a
 * 25 MHz target -- close enough that a 256-entry SDRAM cache was rejected
 * on this same board for a *looser* 28.4 MHz result), a single comparison
 * cannot tell a logic bug from a marginal timing path: both look like "the
 * result was wrong" on one run. The two failure modes need OPPOSITE
 * responses (RTL logic fix vs. clock/critical-path fix), and are
 * distinguished only by running the identical operation repeatedly:
 *   - a LOGIC bug reproduces the SAME wrong answer every single time
 *     (the input never changes, and neither does the faulty combinational
 *     path's output for that input) -- CONSISTENT failure.
 *   - a TIMING/setup-hold violation depends on conditions that vary run to
 *     run (temperature, voltage, exact clock-edge alignment) even with
 *     bit-identical input and a bit-identical descriptor -- INTERMITTENT
 *     failure, and specifically: some iterations pass, some do not, with
 *     no logical reason tied to the (unchanging) data.
 * This file therefore keeps the input vector and weight tensor FIXED
 * across all iterations (generated once, quantized once, before the loop
 * -- see "same input every iteration" below) and only repeats the
 * accelerator OPERATION, so that "same input, different output on
 * different runs" is a meaningful, diagnostic observation rather than
 * noise from changing test data.
 *
 * *** WHAT THIS TEST DOES NOT ESTABLISH ***
 * A clean run (zero mismatches across every iteration) does NOT prove the
 * timing path is safe. Marginal paths are temperature- and
 * voltage-sensitive; a short run at one set of board conditions passing
 * repeatedly is consistent with "fine" and ALSO consistent with "marginal
 * but not tipped over today". The summary printed at the end says this
 * explicitly rather than letting a clean run read as a guarantee.
 *
 * Standalone: no SD card, no model loading, no RetroKernel -- generates
 * its own deterministic pseudo-random test vector and weight tensor in
 * static arrays. Output goes only through printf()/putchar() (LIBFEMTOC),
 * same convention as model_load.c/llama2.c in this project. Designed so a
 * failure is diagnosable FROM THE TRANSCRIPT ALONE -- operator time at the
 * board is the scarce resource in this feature, and a session should come
 * back with a diagnosis, not a yes/no that needs a second session to
 * interpret.
 *
 * Links against the REAL quantize.c (so the activation vector fed to both
 * the CPU reference and the accelerator is produced by the actual
 * quantize_activations(), not a third hand-copy) and the REAL
 * acc_driver.c (T057/T058). See ../llama2/Makefile's verify-fw-math
 * target and examples/Makefile's acc_test rule for how each source is
 * pulled in.
 *
 * *** NOT VERIFIED ON HARDWARE ***
 * Written and built (links clean, see the feature report) without board
 * access. The comparison logic and accelerator driver calls are correct
 * by construction against the RTL truth sources (acc_driver.h's header
 * comment lists them), but "does it actually distinguish a real
 * intermittent failure on the FPGA" is unverified -- that is exactly what
 * running this program on real hardware, on the R27 accelerator
 * bitstream, is for.
 */

#include <femtorv32.h>
#include <string.h>
#include "../llama2/acc_driver.h"
#include "../llama2/quantize.h"

/* Small on purpose: this is a bring-up smoke test, not a throughput
 * benchmark (that is a different, later task). Still exercises multiple
 * groups (TEST_N/TEST_GS = 4) and a multi-row output (TEST_D = 16) rather
 * than the degenerate single-group/single-row case. All three values are
 * comfortably inside the accelerator's configured limits (acc_driver.h:
 * ACC_MAX_N/ACC_MAX_D = 4096, ACC_ACT_MAX_N = 896 (was 1920 before the
 * R31/R32 BRAM-sizing pass -- NUM_SLOTS 8->4 halved the activation slot
 * count but ACT_AWIDTH 12->10 also narrowed the activation BRAM itself,
 * so ACT_XQ_WORDS dropped by more than 2x; see acc_driver.h's "two BRAMs
 * no longer share a slot size" note), ACC_RESULT_MAX_D = 512 (unchanged),
 * ACC_GS_MIN/MAX = 4/1024) and match this project's actual group size
 * (gs=64 in model.q8.bin) is NOT required here -- gs=16 exercises a
 * different, still-valid value on purpose, so this test does not
 * accidentally only prove the one gs the model happens to use. */
#define TEST_N   64
#define TEST_D   16
#define TEST_GS  16

/* How many times to repeat the identical operation (R27). 200 is a
 * judgment call, not a measured figure: no hardware access here to see
 * how many iterations it actually takes to expose a marginal path, or how
 * long each iteration takes over the real UART. Large enough to have some
 * chance of catching an intermittent fault and to make clustering visible
 * as a pattern rather than a coin flip; small enough that the per-
 * iteration progress line (one character each) stays a readable single
 * block of serial output instead of a multi-screen scroll. Tune this
 * once real timing is known -- see the "what this test does not
 * establish" note above for why more iterations always helps but never
 * proves safety outright. */
#define ACC_TEST_ITERS 200

static float  g_x[TEST_N];
static int8_t g_xq[TEST_N];
static float  g_xs[TEST_N / TEST_GS];

static int8_t g_wq[TEST_N * TEST_D];
static float  g_ws[(TEST_N / TEST_GS) * TEST_D];

static float g_ref[TEST_D];   /* computed once: the fixed expected answer */
static float g_hw[TEST_D];    /* re-read every iteration */

/* Per-word mismatch counter across all completed (ACCST_OK) iterations --
 * this is what tells "always wrong" (logic bug signature: every
 * completed iteration disagrees on this word) from "sometimes wrong"
 * (timing signature: value flips between iterations despite identical
 * input and descriptor). */
static uint16_t g_word_fail_count[TEST_D];

/* Deterministic xorshift32 -- reproducible test data run-to-run, not a
 * cryptographic RNG and not seeded from cycles() on purpose: a failure
 * must be reproducible on the next run for debugging to be possible. Used
 * ONLY to build the fixed input once, before the iteration loop -- never
 * called again inside it, so the input truly is identical every
 * iteration (R27's whole premise depends on this). */
static uint32_t g_seed = 0x1234abcdu;
static uint32_t next_rand(void) {
    g_seed ^= g_seed << 13;
    g_seed ^= g_seed >> 17;
    g_seed ^= g_seed << 5;
    return g_seed;
}
static float rand_unit(void) {   /* pseudo-random float in [-1, 1) */
    return ((float)(int32_t)(next_rand() % 20000) / 10000.0f) - 1.0f;
}

/* HAND COPY of runq.c's matmul_q8() -- runq.c is not includable here
 * (its forward_q8()/tokenizer/etc pull in the whole SD-card-loading
 * program, which this standalone test deliberately does not link). Keep
 * this in sync by inspection if runq.c's matmul_q8() arithmetic ever
 * changes; the ACTUAL cross-check that this arithmetic matches upstream
 * lives in llama2/tools/verify_fw_math.c (host-side, checked against the
 * real quantize.c AND the real tools/runq_host.c). This copy exists only
 * so THIS program has a CPU-computed reference to compare the hardware
 * against, without depending on a second binary or a host connection. */
static void matmul_q8_ref(float *xout, const int8_t *xq, const float *xs,
                           const int8_t *wq, const float *ws, int n, int d, int gs) {
    for (int i = 0; i < d; i++) {
        float val = 0.0f;
        int32_t ival = 0;
        int in = i * n;
        int j;
        for (j = 0; j <= n - gs; j += gs) {
            for (int k = 0; k < gs; k++) {
                ival += ((int32_t) xq[j + k]) * ((int32_t) wq[in + j + k]);
            }
            float contrib = ((float) ival) * ws[(in + j) / gs] * xs[j / gs];
            val += contrib;
            ival = 0;
        }
        xout[i] = val;
    }
}

#define ACC_TEST_X_SLOT   0
#define ACC_TEST_OUT_SLOT 1

/* Simple min/max/sum tracker for one perf counter across iterations.
 * Printed as min/max/mean (integer division -- printf here has no %f) so
 * a reader can see at a glance whether the operation's own timing is
 * stable. A stable PERF_CYCLES/PERF_STALL alongside an UNSTABLE result is
 * the specific "stable operation, unstable results" pattern R27 calls a
 * strong timing signal -- the hardware took the same measured time to
 * finish, but finished with a different answer, which points at a
 * marginal data path rather than at control-flow variation. */
typedef struct {
    uint32_t min, max;
    uint32_t sum;
    uint32_t n;
} stat_t;

static void stat_init(stat_t *s) {
    s->min = 0xFFFFFFFFu;
    s->max = 0;
    s->sum = 0;
    s->n = 0;
}
static void stat_add(stat_t *s, uint32_t v) {
    if (v < s->min) s->min = v;
    if (v > s->max) s->max = v;
    s->sum += v;
    s->n++;
}
static void stat_print(const char *name, const stat_t *s) {
    if (s->n == 0) {
        printf("  %s: no completed samples\r\n", name);
        return;
    }
    uint32_t mean = s->sum / s->n;
    printf("  %s: min=%d max=%d mean=%d (n=%d, range=%d)\r\n",
           name, (int)s->min, (int)s->max, (int)mean, (int)s->n, (int)(s->max - s->min));
}

int main(void) {
    printf("\r\n");
    printf("acc_test: int8 MatMul accelerator repeated-trial test (R27)\r\n");
    printf("shape: n=%d d=%d gs=%d, iterations=%d\r\n", TEST_N, TEST_D, TEST_GS, ACC_TEST_ITERS);

    /* Build the fixed input ONCE. Every iteration below reuses this exact
     * data -- see the file header on why that is the point. */
    for (int i = 0; i < TEST_N; i++)
        g_x[i] = rand_unit();
    for (int i = 0; i < TEST_N * TEST_D; i++)
        g_wq[i] = (int8_t)(next_rand() & 0xFF);
    for (int i = 0; i < (TEST_N / TEST_GS) * TEST_D; i++)
        g_ws[i] = 0.01f + 0.001f * (float)(next_rand() % 50);

    /* Real quantize_activations() (quantize.c) -- same function runq.c
     * calls, so the vector fed to both sides below is exactly what
     * production code would produce, not a test-only stand-in. */
    quantize_activations(g_xq, g_xs, g_x, TEST_N, TEST_GS);

    /* The expected answer, computed once. The CPU path is not re-run
     * per iteration: it has no hardware timing to be marginal about, and
     * re-running it would only cost time without adding information. */
    matmul_q8_ref(g_ref, g_xq, g_xs, g_wq, g_ws, TEST_N, TEST_D, TEST_GS);

    acc_status_t st = acc_load_activation(ACC_TEST_X_SLOT, g_xq, g_xs, TEST_N, TEST_GS);
    if (st != ACCST_OK) {
        printf("acc_load_activation failed: %s\r\n", acc_strerror(st));
        printf("FAIL (setup)\r\n");
        return 1;
    }

    for (int i = 0; i < TEST_D; i++) g_word_fail_count[i] = 0;

    stat_t cycles_stat, stall_stat;
    stat_init(&cycles_stat);
    stat_init(&stall_stat);

    uint32_t ok_count = 0;         /* ACCST_OK, a real completed comparison */
    uint32_t rejected_count = 0;   /* a real ACC_ERR_* from the hardware -- descriptor refused */
    uint32_t timeout_count = 0;    /* driver-side: never completed, already aborted */
    uint32_t mismatch_iters = 0;   /* of the ok_count, how many had >=1 wrong word */

    /* Clustering: does a failing iteration tend to follow another failing
     * iteration (a "burst", closer to a sustained condition -- e.g.
     * temperature drift) or scatter randomly through the run (closer to
     * per-cycle jitter on a marginal path)? Tracked with a simple run-
     * length scan over the pass/fail sequence, no history buffer needed. */
    int in_fail_run = 0;
    uint32_t fail_run_len = 0;
    uint32_t longest_fail_run = 0;
    uint32_t fail_cluster_count = 0;  /* number of distinct fail runs */

    int first_mismatch_iter = -1;
    int printed_first_mismatch_detail = 0;

    for (uint32_t iter = 0; iter < ACC_TEST_ITERS; iter++) {
        acc_perf_t perf;
        acc_status_t op_st = acc_matmul_q8(ACC_TEST_OUT_SLOT, g_wq, g_ws, ACC_TEST_X_SLOT,
                                            TEST_N, TEST_D, TEST_GS, &perf);

        char progress_char;
        int iter_failed = 0;

        if (op_st == ACCST_ERR_TIMEOUT) {
            timeout_count++;
            progress_char = 'T';
            iter_failed = 1;
        } else if (op_st != ACCST_OK) {
            /* A real hardware rejection (ERR_DIM/GS/RANGE/SLOT/FULL/MODE).
             * The descriptor is identical every iteration and was valid
             * the first time it would be valid every time -- an
             * INTERMITTENT rejection here is itself a finding (the
             * accept-time logic is unstable), distinct from a wrong
             * VALUE. Counted and flagged separately rather than folded
             * into "mismatch" so the two failure shapes are not
             * conflated. */
            rejected_count++;
            progress_char = 'R';
            iter_failed = 1;
        } else {
            ok_count++;
            stat_add(&cycles_stat, perf.cycles);
            stat_add(&stall_stat, perf.stall);

            acc_read_result(ACC_TEST_OUT_SLOT, g_hw, TEST_D);

            /* Bit-exact comparison via the raw uint32 pattern, not a
             * float tolerance: SC-009 and this whole feature's premise
             * is that int8 accumulation is exact, so ANY difference
             * (even one ULP) is a real observation, not noise. */
            int this_iter_mismatches = 0;
            for (int i = 0; i < TEST_D; i++) {
                uint32_t rb, hb;
                memcpy(&rb, &g_ref[i], sizeof(rb));
                memcpy(&hb, &g_hw[i], sizeof(hb));
                if (rb != hb) {
                    this_iter_mismatches++;
                    g_word_fail_count[i]++;
                }
            }

            if (this_iter_mismatches > 0) {
                mismatch_iters++;
                iter_failed = 1;
                progress_char = 'x';
                if (first_mismatch_iter < 0) first_mismatch_iter = (int)iter;
                if (!printed_first_mismatch_detail) {
                    printed_first_mismatch_detail = 1;
                    printf("\r\n  first mismatch at iteration %d (%d/%d words wrong):\r\n",
                           (int)iter, this_iter_mismatches, TEST_D);
                    for (int i = 0; i < TEST_D; i++) {
                        uint32_t rb, hb;
                        memcpy(&rb, &g_ref[i], sizeof(rb));
                        memcpy(&hb, &g_hw[i], sizeof(hb));
                        if (rb != hb)
                            printf("    word i=%d ref=0x%x hw=0x%x\r\n", i, (unsigned)rb, (unsigned)hb);
                    }
                }
            } else {
                progress_char = '.';
            }
        }

        putchar(progress_char);
        if ((iter % 50) == 49) printf("  [%d/%d]\r\n", (int)(iter + 1), ACC_TEST_ITERS);

        if (iter_failed) {
            if (!in_fail_run) {
                in_fail_run = 1;
                fail_cluster_count++;
                fail_run_len = 0;
            }
            fail_run_len++;
            if (fail_run_len > longest_fail_run) longest_fail_run = fail_run_len;
        } else {
            in_fail_run = 0;
            fail_run_len = 0;
        }
    }
    printf("\r\n");

    /* ---------------------------------------------------------------
     * Summary. Everything a reader needs to diagnose CONSISTENT
     * (logic) vs. INTERMITTENT (timing) failure is printed here --
     * no re-run with different arguments should be necessary.
     * --------------------------------------------------------------- */
    printf("\r\n=== acc_test summary (%d iterations, identical input every time) ===\r\n",
           ACC_TEST_ITERS);
    printf("completed(OK)=%d  rejected(ERR)=%d  timeout=%d\r\n",
           (int)ok_count, (int)rejected_count, (int)timeout_count);
    printf("of %d completed: %d mismatched (>=1 wrong word), %d bit-exact\r\n",
           (int)ok_count, (int)mismatch_iters, (int)(ok_count - mismatch_iters));

    printf("\r\nPERF counters across completed iterations:\r\n");
    stat_print("PERF_CYCLES", &cycles_stat);
    stat_print("PERF_STALL ", &stall_stat);

    if (ok_count == 0) {
        printf("\r\nPer-word result: no completed iterations to report -- see rejected/timeout "
               "counts above.\r\n");
    } else {
        printf("\r\nPer-word result across %d completed iterations:\r\n", (int)ok_count);
        for (int i = 0; i < TEST_D; i++) {
            uint16_t f = g_word_fail_count[i];
            if (f == 0) {
                printf("  word i=%-2d: always correct\r\n", i);
            } else if (f == ok_count) {
                printf("  word i=%-2d: ALWAYS WRONG (%d/%d) -- consistent, logic-bug signature\r\n",
                       i, (int)f, (int)ok_count);
            } else {
                printf("  word i=%-2d: intermittent (%d/%d wrong) -- timing signature\r\n",
                       i, (int)f, (int)ok_count);
            }
        }
    }

    printf("\r\nClustering: longest run of consecutive failing iterations = %d, "
           "distinct fail clusters = %d\r\n", (int)longest_fail_run, (int)fail_cluster_count);
    if (first_mismatch_iter >= 0)
        printf("first mismatching iteration: %d\r\n", first_mismatch_iter);

    /* ---------------------------------------------------------------
     * Diagnosis. Phrased as "consistent with", not a verdict -- this
     * test observes a pattern, it does not itself determine root cause.
     * --------------------------------------------------------------- */
    printf("\r\n=== diagnosis ===\r\n");
    if (rejected_count > 0 && rejected_count < ACC_TEST_ITERS) {
        printf("The descriptor was accepted on some iterations and REJECTED on others, for an\r\n"
               "IDENTICAL descriptor every time. That instability is itself a finding, separate\r\n"
               "from any value mismatch below -- the accept-time logic (or its inputs) is not\r\n"
               "behaving deterministically.\r\n");
    }
    if (ok_count == 0) {
        printf("No iteration completed (OK) at all -- cannot compare results. Check "
               "rejected/timeout counts above; nothing below this line is meaningful.\r\n");
    } else if (mismatch_iters == 0) {
        printf("All %d completed iterations were bit-exact.\r\n"
               "This does NOT prove timing is safe. Marginal paths are temperature- and\r\n"
               "voltage-sensitive and can pass a short run, under one set of board conditions,\r\n"
               "repeatedly. This run establishes correctness only under THESE %d trials, at\r\n"
               "whatever conditions the board was at during them -- not a guarantee.\r\n",
               (int)ok_count, (int)ok_count);
    } else if (mismatch_iters == ok_count) {
        printf("EVERY completed iteration produced a wrong result, and (see per-word table\r\n"
               "above) the SAME words were wrong in the SAME way each time. Identical input\r\n"
               "producing the identical wrong output on every single trial is consistent with\r\n"
               "a LOGIC bug, not a timing/marginal-path issue -- a marginal path would not be\r\n"
               "expected to reproduce the exact same failure on every one of %d independent\r\n"
               "attempts. Look at the RTL, not the clock.\r\n", (int)ok_count);
    } else {
        printf("Failures are INTERMITTENT: %d of %d completed iterations mismatched, not all\r\n"
               "and not none, on an IDENTICAL input and descriptor every time. Same input,\r\n"
               "different output across different runs is consistent with a TIMING/marginal-\r\n"
               "path issue, not a logic bug -- a logic bug would be expected to fail the same\r\n"
               "way every time. Cross-check against the clustering (a scattered pattern points\r\n"
               "more at per-cycle jitter; a clustered pattern more at a slower drift, e.g.\r\n"
               "temperature) and the PERF_CYCLES/PERF_STALL spread above: a STABLE perf counter\r\n"
               "alongside an UNSTABLE result is a strong additional signal for timing, since a\r\n"
               "control-flow/logic difference would usually also perturb the cycle count.\r\n",
               (int)mismatch_iters, (int)ok_count);
    }

    int overall_fail = (mismatch_iters != 0) || (rejected_count != 0) || (timeout_count != 0);
    printf("\r\n%s\r\n", overall_fail ? "FAIL (see diagnosis above)" : "PASS (see caveat above)");
    return overall_fail;
}
