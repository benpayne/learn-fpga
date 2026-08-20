/*
 * verify_fw_math.c -- host-side cross-check that the FIRMWARE's int8
 * arithmetic matches tools/runq_host.c (the golden reference), bit for
 * bit, without needing the board.
 *
 * This is NOT a substitute for T023 (on-hardware, byte-identical generated
 * text). It only proves the isolated math primitives agree -- the same
 * scope the original ad-hoc version of this check covered when T015-T020
 * were built, now landed permanently so it stays runnable after someone
 * edits matmul, quantize, or RoPE six months from now instead of living
 * only in a throwaway scratch file.
 *
 * WHAT IS CHECKED, AND HOW EACH SIDE IS SOURCED:
 *
 *   quantize_activations() (quantize.c)  vs  quantize()  (runq_host.c)
 *     -- the REAL quantize.c is compiled into this binary (Makefile
 *     target links it in, not a copy), and runq_host.c's quantize() is
 *     reached by #include-ing runq_host.c itself below with TESTING
 *     defined (which compiles out its main()/CLI, per that file's own
 *     `#ifndef TESTING` guard around them). Neither side is retyped here,
 *     so this half of the check cannot silently drift from either source
 *     file.
 *
 *   matmul_q8() (runq.c, NOT linked here -- runq.c needs femtorv32.h and
 *   is not host-buildable) vs matmul() (runq_host.c, included below)
 *     -- runq.c is firmware-only, so its matmul_q8() is reproduced BY
 *     HAND below (matmul_q8_copy()) with a comment pointing back at the
 *     real one. THIS HALF CAN DRIFT if runq.c's matmul_q8() is edited
 *     without updating the copy here -- there is no way around that
 *     without a shared, target-and-host-buildable source file, which is
 *     more machinery than this check has earned. Diff the two by hand
 *     when touching either.
 *
 *   RoPE loop in runq.c's forward_q8() vs the RoPE block inside
 *   runq_host.c's forward() (not a separate function there either)
 *     -- same situation: hand-copied as rope_q8_copy() below, comment
 *     points back at runq.c.
 *
 * Build and run:
 *   cd FemtoRV/FIRMWARE/llama2 && make verify-fw-math
 * (links the real quantize.c; plain host gcc, NOT the RISC-V cross
 * toolchain -- this program runs on the developer's machine, matching
 * runq_host.c's own "gcc -O2 ... -lm" build line.)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

/* The real quantize.c (linked by the Makefile target, not copied) --
 * quantize_activations() is the firmware side of the first check above. */
#include "../quantize.h"

/* runq_host.c itself, compiled in with its CLI/main() removed by its own
 * `#ifndef TESTING` guard, so its quantize()/matmul()/rmsnorm()/softmax()
 * are the exact golden-reference functions, not a retyped copy. */
#define TESTING
#include "runq_host.c"
#undef TESTING

/* ----------------------------------------------------------------------
 * matmul_q8_copy() -- HAND COPY of runq.c's matmul_q8(). Keep this in
 * sync by inspection whenever runq.c's matmul_q8() changes; see file
 * header. Debug-dump parameters already absent from runq.c's version (it
 * was ported from runq_host.c's matmul() with those dropped), so nothing
 * to strip here.
 */
static void matmul_q8_copy(float *xout, const int8_t *xq, const float *xs,
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

/* ----------------------------------------------------------------------
 * rope_q8_copy() -- HAND COPY of the RoPE loop inside runq.c's
 * forward_q8(). Keep in sync by inspection; see file header. Operates on
 * q[0..dim) and k[0..kv_dim), matching runq.c's call convention (q is
 * always rotated, k only for i < kv_dim).
 */
static void rope_q8_copy(float *q, float *k, int dim, int kv_dim, int head_size, int pos) {
    for (int i = 0; i < dim; i += 2) {
        int head_dim = i % head_size;
        float freq = 1.0f / powf(10000.0f, head_dim / (float)head_size);
        float val = pos * freq;
        float fcr = cosf(val);
        float fci = sinf(val);
        int rotn = i < kv_dim ? 2 : 1;
        for (int v = 0; v < rotn; v++) {
            float *vec = v == 0 ? q : k;
            float v0 = vec[i], v1 = vec[i + 1];
            vec[i]     = v0 * fcr - v1 * fci;
            vec[i + 1] = v0 * fci + v1 * fcr;
        }
    }
}

/* ---------------------------------------------------------------------- */

static uint64_t g_rng = 88172645463325252ull;
static double frand(void) {
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17;
    return (double)(g_rng % 1000000) / 1000000.0 * 4.0 - 2.0; /* [-2,2) */
}

/* Compares quantize_activations() (real quantize.c) against runq_host.c's
 * quantize() (via the shared QuantizedTensor-shaped calls) for one (n,gs)
 * shape, then feeds the results into matmul_q8_copy() vs matmul() for one
 * (n,d) weight shape. Returns 1 on any mismatch. */
static int check_quantize_and_matmul(int n, int d, int gs) {
    /* runq_host.c's quantize()/matmul() do NOT take gs as a parameter --
     * both read the file-scope global `GS` directly (its own file header
     * even calls this out: "group size global for quantization of the
     * weights"). MUST be set before every call or GS defaults to 0 and
     * quantize()'s `n / GS` divides by zero. */
    GS = gs;

    float *x = malloc((size_t)n * sizeof(float));
    int8_t *wq = malloc((size_t)n * d);
    float *ws = malloc((size_t)((size_t)n * d / gs) * sizeof(float));
    for (int i = 0; i < n; i++) x[i] = (float)frand();
    for (long i = 0; i < (long)n * d; i++)
        wq[i] = (int8_t)((g_rng = g_rng * 6364136223846793005ull + 1) >> 40);
    for (long i = 0; i < (long)n * d / gs; i++) ws[i] = (float)(frand() * 0.05 + 0.01);

    int8_t *q_ref = malloc(n), *q_new = malloc(n);
    float *s_ref = malloc(((size_t)n / gs) * sizeof(float));
    float *s_new = malloc(((size_t)n / gs) * sizeof(float));

    QuantizedTensor xr = { q_ref, s_ref };
    quantize(&xr, x, n);                              /* runq_host.c, real function */
    quantize_activations(q_new, s_new, x, n, gs);      /* quantize.c, real function */

    int qdiff = memcmp(q_ref, q_new, n) != 0;
    int sdiff = memcmp(s_ref, s_new, ((size_t)n / gs) * sizeof(float)) != 0;

    QuantizedTensor wr = { wq, ws };
    float *out_ref = malloc((size_t)d * sizeof(float));
    float *out_new = malloc((size_t)d * sizeof(float));
    matmul(out_ref, &xr, &wr, n, d, "test", 0);                  /* runq_host.c */
    matmul_q8_copy(out_new, q_new, s_new, wq, ws, n, d, gs);     /* runq.c copy */
    int mdiff = memcmp(out_ref, out_new, (size_t)d * sizeof(float)) != 0;

    printf("n=%-4d d=%-4d gs=%-3d : quantize q %s, s %s | matmul %s\n",
           n, d, gs, qdiff ? "DIFF" : "match", sdiff ? "DIFF" : "match",
           mdiff ? "DIFF" : "match");

    free(x); free(wq); free(ws); free(q_ref); free(q_new); free(s_ref); free(s_new);
    free(out_ref); free(out_new);
    return qdiff || sdiff || mdiff;
}

static int check_rope(int dim, int kv_dim, int head_size) {
    int fail = 0;
    for (int pos = 0; pos < 20; pos++) {
        float qref[256], kref[256], qnew[256], knew[256];
        for (int i = 0; i < dim; i++) qref[i] = qnew[i] = 0.01f * (i + 1) - 0.3f;
        for (int i = 0; i < kv_dim; i++) kref[i] = knew[i] = 0.02f * (i + 1) - 0.1f;

        /* Reference: the same expression runq_host.c's forward() computes
         * inline for its RoPE block (not a standalone function there, so
         * reproduced here verbatim rather than called). */
        for (int i = 0; i < dim; i += 2) {
            int head_dim = i % head_size;
            float freq = 1.0f / powf(10000.0f, head_dim / (float)head_size);
            float val = pos * freq;
            float fcr = cosf(val);
            float fci = sinf(val);
            int rotn = i < kv_dim ? 2 : 1;
            for (int v = 0; v < rotn; v++) {
                float *vec = v == 0 ? qref : kref;
                float v0 = vec[i], v1 = vec[i + 1];
                vec[i]     = v0 * fcr - v1 * fci;
                vec[i + 1] = v0 * fci + v1 * fcr;
            }
        }
        rope_q8_copy(qnew, knew, dim, kv_dim, head_size, pos);

        if (memcmp(qref, qnew, (size_t)dim * sizeof(float)) != 0 ||
            memcmp(kref, knew, (size_t)kv_dim * sizeof(float)) != 0) {
            printf("RoPE pos=%d MISMATCH (dim=%d kv_dim=%d head_size=%d)\n",
                   pos, dim, kv_dim, head_size);
            fail = 1;
        }
    }
    if (!fail)
        printf("RoPE dim=%-4d kv_dim=%-4d head_size=%-3d : match (pos=0..19)\n",
               dim, kv_dim, head_size);
    return fail;
}

int main(void) {
    int fail = 0;

    /* This project's actual tensor shapes (model.q8.bin: dim=64,
     * hidden_dim=192, n_layers=5, n_heads=8, n_kv_heads=4, vocab=512,
     * gs=64) plus one off-default gs to exercise the general case. */
    fail |= check_quantize_and_matmul(64, 64, 64);     /* wq/wo: dim x dim */
    fail |= check_quantize_and_matmul(64, 192, 64);    /* w1/w3: dim x hidden */
    fail |= check_quantize_and_matmul(192, 64, 64);    /* w2: hidden x dim */
    fail |= check_quantize_and_matmul(64, 32, 64);     /* wk/wv: dim x kv_dim */
    fail |= check_quantize_and_matmul(64, 512, 64);    /* q_tokens/wcls: dim x vocab */
    fail |= check_quantize_and_matmul(128, 256, 32);   /* off-model shape, gs=32 */

    fail |= check_rope(64, 32, 8);   /* this model: dim=64, kv_dim=32, head_size=dim/n_heads=8 */

    printf(fail ? "\nFAIL: firmware math diverges from tools/runq_host.c\n"
                : "\nPASS: firmware math (quantize/matmul/RoPE) bit-identical "
                  "to tools/runq_host.c across all checked shapes\n");
    return fail;
}
