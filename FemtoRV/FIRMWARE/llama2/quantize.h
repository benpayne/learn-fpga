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
 * Arithmetic is verbatim upstream (tools/runq_host.c's quantize(), which
 * is itself verbatim karpathy/llama2.c's runq.c): abs value in double
 * precision (fabs, not fabsf) and round-half-away-from-zero in double
 * precision (round, not roundf), exactly as upstream computes it -- see
 * runq.c's file header on why the arithmetic must not be "improved". */
void quantize_activations(int8_t *q, float *s, const float *x, int n, int gs);

#endif
