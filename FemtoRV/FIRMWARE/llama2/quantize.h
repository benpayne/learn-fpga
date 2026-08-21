/*
 * quantize.h -- activation quantization for the int8 (Q8_0) inference path.
 *
 * This is NEW scalar work feature 004 adds that the fp32 llama2.c path
 * never needed (research R2, data-model.md entity 3): before every matmul,
 * the CPU quantizes the fp32 activation vector to int8 + per-group fp32
 * scales, matching upstream llama2.c's runq.c quantize() so the result
 * compares bit-for-bit against tools/runq_host.c (the golden reference).
 */
#ifndef QUANTIZE_H
#define QUANTIZE_H

#include <stdint.h>

/* Quantize x[0..n) into q[0..n) (int8) + s[0..n/gs) (float32 per-group
 * scale). `n` MUST already be a multiple of `gs` -- model_load.c's
 * ml_load_model_q8() validates this against the loaded model's dim/
 * hidden_dim once at load time (FR-009, data-model entity 4), so callers
 * here trust it rather than re-checking every call, exactly as upstream
 * runq.c's quantize() does.
 *
 * Arithmetic matches upstream (tools/runq_host.c's quantize(), itself
 * verbatim karpathy/llama2.c's runq.c) BIT FOR BIT, but uses the
 * single-precision libm entry points rather than the double-precision ones
 * upstream writes.
 *
 * This is not an "improvement" to the arithmetic, which runq.c's header
 * rightly forbids -- it is the same arithmetic reached by a cheaper route,
 * and that was verified rather than argued. float -> double is exact,
 * round() yields an integral value, and the int8_t conversion is identical
 * either way. Swept 2,264,378 values across the float32 space comparing
 * (int8_t)round((double)x) against (int8_t)roundf(x): zero differences.
 *
 * The reason it matters: this CPU is rv32imafc -- single-precision FP in
 * hardware, no double. Written with fabs()/round(), the inner loop called
 * __extendsfdf2, round and __fixdfsi per element, three software-emulated
 * double routines, and cost 8.5% of per-token runtime (75 ms/token,
 * research R43/R44). Faithfulness to upstream's spelling was measurably
 * expensive; faithfulness to its RESULT is free.
 *
 * If this is ever ported to a target with real double-precision hardware,
 * reverting to fabs()/round() is harmless -- the results are the same. */
void quantize_activations(int8_t *q, float *s, const float *x, int n, int gs);

#endif
