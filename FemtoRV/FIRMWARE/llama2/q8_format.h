/*
 * q8_format.h -- Q8_0 quantized llama2.c checkpoint layout.
 *
 * The SINGLE shared definition of the on-disk format written by
 * tools/quantize_model.sh (which drives upstream llama2.c's export.py
 * --version 2) and read by both the host tools (tools/runq_host.c) and
 * the RISC-V firmware (runq.c, model_load.c). Both sides MUST include
 * this file rather than re-deriving the layout, so they cannot disagree
 * about it (spec T005). Verified against upstream runq.c -- see
 * specs/004-int8-matmul-accel/research.md R1, R3, R4, R5 and
 * data-model.md entities 1-3.
 *
 * ------------------------------------------------------------------
 * 256-byte header (all fields little-endian):
 *
 *   offset  size  field
 *   0       4     magic             uint32, Q8_0_MAGIC ("ak42")
 *   4       4     version           int32, must be Q8_0_VERSION (2)
 *   8       28    config            7 x int32 -- see Q8Config below
 *   36      1     shared_classifier uint8 (1 = classifier reuses the
 *                                    token embedding table, so no wcls
 *                                    tensor is stored)
 *   37      4     group_size        int32 GS -- a FILE PARAMETER, not a
 *                                    compile-time constant (research
 *                                    R3). Default 64; MUST be read from
 *                                    here, not assumed.
 *   41      215   (zero padding, out to 256)
 *   256     --    tensor data begins here
 *
 * A file NOT starting with Q8_0_MAGIC is feature 003's legacy format
 * (28-byte header, no magic, precomputed freq_cis tables -- see
 * model_load.h). The magic is how a loader tells the two apart
 * (research R4); loading one format as the other is exactly the kind
 * of silent-wrong-output failure this project guards against, so
 * callers MUST check the magic before trusting anything else.
 *
 * ------------------------------------------------------------------
 * Tensor data, in this EXACT order (matches upstream runq.c's
 * memory_map_weights() -- do not reorder):
 *
 *   fp32, NOT quantized (plain float32, row-major). Only the norm
 *   weights stay fp32; everything else below is quantized:
 *     rms_att_weight   [n_layers * dim]
 *     rms_ffn_weight   [n_layers * dim]
 *     rms_final_weight [dim]
 *
 *   int8 quantized. Each row below is an ARRAY of QuantizedTensor
 *   entries (research R1 / data-model entity 2). Every tensor in the
 *   array owns its OWN q block immediately followed by its OWN s
 *   block -- q/s blocks are per-tensor, NOT pooled across the array
 *   (i.e. for n_layers > 1 the layout is q0,s0,q1,s1,...,q(n-1),s(n-1),
 *   not q0,q1,...,s0,s1,...):
 *
 *     tensor            count      numel per tensor
 *     q_tokens          1          dim * vocab_size
 *     wq                n_layers   dim * (n_heads * head_size)
 *     wk                n_layers   dim * (n_kv_heads * head_size)
 *     wv                n_layers   dim * (n_kv_heads * head_size)
 *     wo                n_layers   (n_heads * head_size) * dim
 *     w1                n_layers   dim * hidden_dim
 *     w2                n_layers   hidden_dim * dim
 *     w3                n_layers   dim * hidden_dim
 *     wcls (classifier) 0 or 1     dim * vocab_size
 *
 *   wcls is PRESENT ONLY when shared_classifier == 0. When
 *   shared_classifier == 1 no bytes are stored for it and the reader
 *   MUST reuse q_tokens as the classifier weights instead.
 *
 *   head_size = dim / n_heads (Q8_0_HEAD_SIZE below).
 *
 * Within one QuantizedTensor of `numel` elements at group size GS:
 *     int8_t  q[numel]         -- Q8_0_TENSOR_Q_BYTES(numel)
 *     float   s[numel / GS]    -- Q8_0_TENSOR_S_BYTES(numel, GS)
 *   `numel` MUST be a multiple of GS (FR-009); reject otherwise rather
 *   than computing a partial group. Reconstruction: w[i] = q[i] *
 *   s[i/GS]. When both a weight and an activation are quantized (the
 *   MatMul case) the effective per-group scale is the PRODUCT of the
 *   two tensors' scales, w->s[g] * x->s[g] (research R2).
 */
#ifndef Q8_FORMAT_H
#define Q8_FORMAT_H

#include <stdint.h>

#define Q8_0_MAGIC        0x616b3432u  /* "ak42", little-endian in the file */
#define Q8_0_VERSION      2
#define Q8_0_HEADER_BYTES 256u

/* The 7 int32 fields between the version and shared_classifier. Field
 * order is part of the on-disk format -- do not reorder. */
typedef struct {
    int32_t dim;
    int32_t hidden_dim;
    int32_t n_layers;
    int32_t n_heads;
    int32_t n_kv_heads;
    int32_t vocab_size;
    int32_t seq_len;
} Q8Config;

/* Raw 256-byte on-disk header, byte-exact with the offsets documented
 * above. Packed so sizeof(Q8Header) matches the file exactly: without
 * `packed`, a compiler would insert 3 bytes before group_size to
 * 4-byte-align it after the single shared_classifier byte, which is
 * not what's on disk. Read/write this struct directly with a single
 * fread()/fwrite() of Q8_0_HEADER_BYTES. */
typedef struct {
    uint32_t magic;
    int32_t  version;
    Q8Config config;
    uint8_t  shared_classifier;
    int32_t  group_size;
    uint8_t  reserved[Q8_0_HEADER_BYTES - 4u - 4u - sizeof(Q8Config) - 1u - 4u];
} __attribute__((packed)) Q8Header;

/* Compile-time check that the struct above really is 256 bytes -- if
 * this ever fails to compile, the `reserved` padding size above needs
 * updating to match Q8_0_HEADER_BYTES. */
typedef char q8_header_size_must_be_256[
    (sizeof(Q8Header) == Q8_0_HEADER_BYTES) ? 1 : -1];

/* head_size = dim / n_heads (used to size wq/wk/wv/wo, see the layout
 * table above). */
#define Q8_0_HEAD_SIZE(cfgptr) \
    ((uint32_t)(cfgptr)->dim / (uint32_t)(cfgptr)->n_heads)

/* ------------------------------------------------------------- sizing */

/* Bytes for the q block of one tensor with `numel` elements: exactly
 * one int8 per element, independent of group size. */
#define Q8_0_TENSOR_Q_BYTES(numel) ((uint32_t)(numel))

/* Number of per-group scale factors for one tensor with `numel`
 * elements at group size `gs`. `numel` MUST be a multiple of `gs`
 * (FR-009) -- this macro does not check that; validate first. */
#define Q8_0_TENSOR_S_COUNT(numel, gs) \
    ((uint32_t)(numel) / (uint32_t)(gs))

/* Bytes for the s block (float32 scales) of one tensor. */
#define Q8_0_TENSOR_S_BYTES(numel, gs) \
    (Q8_0_TENSOR_S_COUNT((numel), (gs)) * (uint32_t)sizeof(float))

/* Total bytes for one QuantizedTensor: its q block immediately
 * followed by its s block. At the default GS=64 this is (numel + 4)
 * bytes per numel int8s, i.e. 1.0625 bytes/weight (research R1, R3). */
#define Q8_0_TENSOR_BYTES(numel, gs) \
    (Q8_0_TENSOR_Q_BYTES(numel) + Q8_0_TENSOR_S_BYTES((numel), (gs)))

/* Total size in bytes of a complete Q8_0 checkpoint file: the 256-byte
 * header, the three fp32 norm tensors, then every quantized tensor in
 * the exact order documented above. `gs` is the group_size read from
 * the header (research R3 -- it is NOT a constant); `shared_classifier`
 * is the header's shared_classifier byte. Mirrors upstream runq.c's
 * memory_map_weights() (research R1/R4/R5) -- if this and the actual
 * loader ever disagree about the total, one of them is wrong. */
static inline uint32_t q8_checkpoint_bytes(const Q8Config *cfg, int32_t gs,
                                            int shared_classifier) {
    uint32_t dim      = (uint32_t)cfg->dim;
    uint32_t hidden   = (uint32_t)cfg->hidden_dim;
    uint32_t layers   = (uint32_t)cfg->n_layers;
    uint32_t heads    = (uint32_t)cfg->n_heads;
    uint32_t kv_heads = (uint32_t)cfg->n_kv_heads;
    uint32_t vocab    = (uint32_t)cfg->vocab_size;
    uint32_t head_sz  = Q8_0_HEAD_SIZE(cfg);
    uint32_t ugs      = (uint32_t)gs;
    uint32_t bytes    = Q8_0_HEADER_BYTES;

    /* fp32, not quantized */
    bytes += (uint32_t)sizeof(float) * layers * dim;   /* rms_att_weight */
    bytes += (uint32_t)sizeof(float) * layers * dim;   /* rms_ffn_weight */
    bytes += (uint32_t)sizeof(float) * dim;            /* rms_final_weight */

    /* quantized: token embedding table (1 tensor) */
    bytes += Q8_0_TENSOR_BYTES(vocab * dim, ugs);

    /* quantized: per-layer arrays, one q+s pair per layer */
    bytes += layers * Q8_0_TENSOR_BYTES(dim * (heads * head_sz), ugs);     /* wq */
    bytes += layers * Q8_0_TENSOR_BYTES(dim * (kv_heads * head_sz), ugs);  /* wk */
    bytes += layers * Q8_0_TENSOR_BYTES(dim * (kv_heads * head_sz), ugs);  /* wv */
    bytes += layers * Q8_0_TENSOR_BYTES((heads * head_sz) * dim, ugs);     /* wo */
    bytes += layers * Q8_0_TENSOR_BYTES(dim * hidden, ugs);                /* w1 */
    bytes += layers * Q8_0_TENSOR_BYTES(hidden * dim, ugs);                /* w2 */
    bytes += layers * Q8_0_TENSOR_BYTES(dim * hidden, ugs);                /* w3 */

    /* quantized: classifier, only when NOT sharing the embedding table */
    if (!shared_classifier)
        bytes += Q8_0_TENSOR_BYTES(dim * vocab, ugs);

    return bytes;
}

/* ------------------------------------------------------------ tensors */

/* One quantized tensor as it appears once the checkpoint is resident in
 * memory (research R1, data-model entity 2): q and s point directly
 * into the checkpoint image, contiguous but NOT interleaved. The same
 * shape also describes the quantized activation vector once quantize()
 * has filled it (data-model entity 3) -- there `numel` is the vector
 * length (dim or hidden_dim) rather than a weight matrix's element
 * count. */
typedef struct {
    const int8_t *q;      /* numel quantized values */
    const float  *s;      /* numel/GS scale factors, one per group */
    uint32_t      numel;
} Q8Tensor;

#endif /* Q8_FORMAT_H */
