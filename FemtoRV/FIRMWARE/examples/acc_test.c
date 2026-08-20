/*
 * acc_test.c -- standalone test for the int8 MatMul accelerator
 * (feature 004-int8-matmul-accel, T051/T052).
 *
 * Runs ONE matmul operation both on the accelerator and on the CPU (a
 * hand-copy of runq.c's matmul_q8() arithmetic -- see the comment on
 * matmul_q8_ref() below for why it is a copy, not the real function), and
 * compares the two outputs bit-for-bit. This is the first program in this
 * feature that actually exercises the RTL on real hardware; llama2/'s
 * verify_fw_math.c (host-side) and runq_accel.bin (T059, full model)
 * exist alongside it but neither one is this: a minimal, single-operation,
 * serial-only bring-up test, deliberately small so a failure here points
 * straight at the accelerator rather than getting lost in a 5-layer
 * forward pass.
 *
 * Standalone: no SD card, no model loading, no RetroKernel -- generates
 * its own deterministic pseudo-random test vector and weight tensor in
 * static arrays, exactly the "standalone, serial only" shape requested.
 * Output goes only through printf()/putchar() (LIBFEMTOC), same
 * convention as model_load.c/llama2.c in this project.
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
 * comment lists them), but "does it actually pass on the FPGA" is
 * unverified -- that is exactly what running this program on real
 * hardware is for.
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
 * ACC_MAX_N/ACC_MAX_D = 4096, ACC_ACT_MAX_N = 1920, ACC_RESULT_MAX_D =
 * 512, ACC_GS_MIN/MAX = 4/1024) and match this project's actual group
 * size (gs=64 in model.q8.bin) is NOT required here -- gs=16 exercises a
 * different, still-valid value on purpose, so this test does not
 * accidentally only prove the one gs the model happens to use. */
#define TEST_N   64
#define TEST_D   16
#define TEST_GS  16

static float  g_x[TEST_N];
static int8_t g_xq[TEST_N];
static float  g_xs[TEST_N / TEST_GS];

static int8_t g_wq[TEST_N * TEST_D];
static float  g_ws[(TEST_N / TEST_GS) * TEST_D];

static float g_ref[TEST_D];
static float g_hw[TEST_D];

/* Deterministic xorshift32 -- reproducible test data run-to-run, not a
 * cryptographic RNG and not seeded from cycles() on purpose: a failure
 * must be reproducible on the next run for debugging to be possible. */
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

int main(void) {
    printf("\r\n");
    printf("acc_test: int8 MatMul accelerator standalone test\r\n");
    printf("shape: n=%d d=%d gs=%d\r\n", TEST_N, TEST_D, TEST_GS);

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

    matmul_q8_ref(g_ref, g_xq, g_xs, g_wq, g_ws, TEST_N, TEST_D, TEST_GS);

    acc_status_t st = acc_load_activation(ACC_TEST_X_SLOT, g_xq, g_xs, TEST_N, TEST_GS);
    if (st != ACCST_OK) {
        printf("acc_load_activation failed: %s\r\n", acc_strerror(st));
        printf("FAIL\r\n");
        return 1;
    }

    acc_perf_t perf;
    st = acc_matmul_q8(ACC_TEST_OUT_SLOT, g_wq, g_ws, ACC_TEST_X_SLOT,
                        TEST_N, TEST_D, TEST_GS, &perf);
    if (st != ACCST_OK) {
        printf("acc_matmul_q8 failed: %s\r\n", acc_strerror(st));
        printf("FAIL\r\n");
        return 1;
    }

    acc_read_result(ACC_TEST_OUT_SLOT, g_hw, TEST_D);

    printf("PERF_CYCLES=%d PERF_STALL=%d queue_depth=%d\r\n",
           (int)perf.cycles, (int)perf.stall, (int)perf.queue_depth);

    /* Bit-exact comparison via the raw uint32 pattern, not a float
     * tolerance: SC-009 and this whole feature's premise is that int8
     * accumulation is exact, so ANY difference (even one ULP) is a real
     * bug, not noise to be tolerated. */
    int mismatches = 0;
    for (int i = 0; i < TEST_D; i++) {
        uint32_t rb, hb;
        memcpy(&rb, &g_ref[i], sizeof(rb));
        memcpy(&hb, &g_hw[i], sizeof(hb));
        if (rb != hb) {
            mismatches++;
            if (mismatches <= 8)
                printf("MISMATCH i=%d ref=0x%x hw=0x%x\r\n", i, (unsigned)rb, (unsigned)hb);
        }
    }

    if (mismatches == 0) {
        printf("PASS: all %d outputs bit-identical to the CPU reference\r\n", TEST_D);
    } else {
        printf("FAIL: %d of %d outputs differ from the CPU reference\r\n", mismatches, TEST_D);
    }

    return mismatches != 0;
}
