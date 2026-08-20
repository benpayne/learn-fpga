/*
 * runq.c - port of karpathy's llama2.c int8 (Q8_0) quantized inference
 * engine (runq.c) to FemtoRV (RV32IMFC, petitbateau), following the same
 * adaptation pattern as this directory's fp32 sibling, llama2.c: model
 * weights and vocabulary loaded from SD card into SDRAM by model_load.c,
 * output streamed over serial, no mmap, no host file I/O, no malloc,
 * every buffer either a small bounded static array or a pointer computed
 * into a fixed SDRAM region.
 *
 * *** ARITHMETIC FIDELITY ***
 * The whole point of this file is that its output is byte-identical to
 * tools/runq_host.c (the golden reference) for the same model, prompt and
 * seed. Every neural-net block below (rmsnorm, softmax, quantize, matmul,
 * RoPE, attention, SwiGLU) is a verbatim, statement-for-statement port of
 * runq_host.c's version of the same block -- same operand types, same
 * accumulation order, same library calls (fabs/round in double precision
 * where upstream uses them, not the float-suffixed forms -- see
 * quantize.c). Do NOT "improve" or reorder any of it; doing so would
 * silently invalidate the T023 hardware-vs-host comparison this feature
 * exists to make. The two adaptations below are the ONLY departures from
 * a literal statement-for-statement port, and both are proven
 * value-for-value identical, not just "close enough":
 *
 *   1. k/v cache aliasing (same pattern already used by llama2.c): rather
 *      than writing q/k/v into their own scratch buffers and memcpy'ing
 *      k/v into the KV cache afterward (what runq_host.c's forward()
 *      does), s->k/s->v are pointed DIRECTLY at this (layer,pos)'s cache
 *      row before the k/v matmuls run, so the matmul writes -- and RoPE's
 *      later in-place rotation of k -- land straight in the cache. The
 *      final bytes in the cache are identical either way; this only skips
 *      a redundant copy.
 *   2. Token embedding dequantization: runq_host.c dequantizes the WHOLE
 *      token embedding table once at startup (dequantize() over
 *      vocab*dim elements) and then memcpy's one row out of that fp32
 *      copy per forward() call. This file instead dequantizes just the
 *      needed dim-element row, on demand, in forward() itself -- same
 *      formula (q[i] * s[i/GS]) applied to the exact same table, so the
 *      row's values are identical; this only avoids keeping a redundant
 *      vocab*dim*4-byte fp32 shadow copy of the table in SDRAM.
 *
 * *** No RoPE table lookup (unlike llama2.c) ***
 * Unlike the legacy fp32 checkpoint, model.q8.bin (q8_format.h) does NOT
 * carry precomputed freq_cis_real/freq_cis_imag tables -- upstream runq.c
 * computes RoPE's rotation angle directly with powf/cosf/sinf per call,
 * and so does runq_host.c and this file, to stay byte-identical. This is
 * different from llama2.c's table-lookup RoPE (T015 note: do not copy
 * llama2.c's rope_rotate() here, it is the wrong reference for this
 * format).
 *
 * Reference ported from (and adapted away from, for memory model only):
 *   https://github.com/karpathy/llama2.c/blob/master/runq.c
 * Golden reference for output comparison: tools/runq_host.c
 */

#include <femtorv32.h>
#include <math.h>
#include <string.h>
#include "model_load.h"
#include "q8_format.h"
#include "quantize.h"
#include "profile.h"

/* ===================================================================
 * User-editable run parameters. No command line on this target, so
 * everything generate()-related is a compile-time constant here.
 * Match these against tools/runq_host.c's invocation when comparing
 * output for T023 (same prompt, same seed, same temperature/top-p).
 * =================================================================== */

#define GEN_PROMPT             "Once upon a time"
#define GEN_NUM_TOKENS         110     /* generate at most this many tokens; clamped to seq_len */
#define GEN_TEMPERATURE_X100   100     /* temperature * 100 (0 = greedy argmax, 100 = 1.00) */
#define GEN_TOPP_X100           90     /* top-p * 100 (<=0 or >=100 disables nucleus sampling) */
#define GEN_SEED               2026u   /* RNG seed; 0 => derive from cycles() at startup */
#define MEASURE_MODE             1     /* 1 = turn on profiling and print prof_report() at exit */

/* Board clock, used to convert cycles() into tokens/sec and ms (matches
 * model_load.c's CPU_HZ). */
#define CPU_HZ 25000000u

/* ===================================================================
 * Static capacity limits for tokenizer bookkeeping (NOT for weights or
 * activations -- those are sized from the real, loaded Q8Config via
 * pointer arithmetic below). Same bounds as llama2.c: model.q8.bin's
 * vocab=512, max_token_length=7.
 * =================================================================== */

#define MAX_VOCAB       600
#define MAX_TOKEN_LEN    32
#define STRBUF_LEN      (MAX_TOKEN_LEN * 2 + 4)
#define MAX_PROMPT_TOKENS ((int)sizeof(GEN_PROMPT) + 4) /* BOS + dummy-prefix + bytes + EOS + slack */

/* ===================================================================
 * Little-endian unaligned reads (same rationale as llama2.c: the
 * tokenizer's variable-length records are not guaranteed 4-byte
 * aligned in SDRAM).
 * =================================================================== */

static uint32_t rd_u32le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static float rd_f32le(const uint8_t *p) {
    uint32_t u = rd_u32le(p);
    float f;
    memcpy(&f, &u, sizeof(f));
    return f;
}

/* ===================================================================
 * Quantized weights: set up once, purely by pointer arithmetic into the
 * region ml_load_model_q8() already filled at ML_WEIGHTS_BASE. Only the
 * TENSOR DATA is streamed there (the 256-byte header is never copied to
 * SDRAM -- see model_load.h), so this mirrors runq_host.c's
 * memory_map_weights() exactly, with `ptr` starting at ML_WEIGHTS_BASE
 * standing in for its `weights_ptr` (== data + header_size).
 *
 * Per-tensor-TYPE base pointers are kept (not per-layer arrays, and no
 * malloc): a layer's actual (q,s) pair is computed on demand by
 * q8_layer_tensor() below, the same way llama2.c's Weights keeps one
 * base pointer per tensor type and adds `l * stride` in forward().
 * =================================================================== */

typedef struct {
    Q8Tensor q_tokens;         /* (vocab*dim,) single tensor */
    float   *rms_att_weight;   /* (n_layers*dim,) fp32 */
    float   *rms_ffn_weight;   /* (n_layers*dim,) fp32 */
    float   *rms_final_weight; /* (dim,) fp32 */
    const uint8_t *wq_base, *wk_base, *wv_base, *wo_base;
    const uint8_t *w1_base, *w2_base, *w3_base;
    Q8Tensor wcls;              /* == q_tokens if shared_classifier */
} Q8Weights;

/* Locates layer `layer`'s (q,s) pair inside a per-tensor-type blob whose
 * tensors are laid out back-to-back, each one's own q block immediately
 * followed by its own s block (q8_format.h, Q8_0_TENSOR_BYTES) -- NOT
 * pooled across the array, matching memory_map_weights()'s
 * init_quantized_tensors(). */
static void q8_layer_tensor(Q8Tensor *out, const uint8_t *base, uint32_t layer,
                             uint32_t numel, int32_t gs) {
    uint32_t stride = Q8_0_TENSOR_BYTES(numel, gs);
    const uint8_t *p = base + layer * stride;
    out->q = (const int8_t *)p;
    out->s = (const float *)(p + numel);
    out->numel = numel;
}

static void setup_q8_weights(Q8Weights *w, const Q8Config *cfg, int32_t gs, int shared_classifier) {
    uint32_t dim       = (uint32_t)cfg->dim;
    uint32_t hidden    = (uint32_t)cfg->hidden_dim;
    uint32_t layers    = (uint32_t)cfg->n_layers;
    uint32_t heads     = (uint32_t)cfg->n_heads;
    uint32_t kv_heads  = (uint32_t)cfg->n_kv_heads;
    uint32_t vocab     = (uint32_t)cfg->vocab_size;
    uint32_t head_size = dim / heads;

    const uint8_t *ptr = (const uint8_t *)ML_WEIGHTS_BASE;

    /* fp32, NOT quantized -- first in the file, same order as
     * memory_map_weights()'s fptr walk. */
    w->rms_att_weight = (float *)ptr; ptr += (uint32_t)sizeof(float) * layers * dim;
    w->rms_ffn_weight = (float *)ptr; ptr += (uint32_t)sizeof(float) * layers * dim;
    w->rms_final_weight = (float *)ptr; ptr += (uint32_t)sizeof(float) * dim;

    /* quantized: token embedding table (1 tensor) */
    {
        uint32_t numel = vocab * dim;
        w->q_tokens.q = (const int8_t *)ptr;
        w->q_tokens.s = (const float *)(ptr + numel);
        w->q_tokens.numel = numel;
        ptr += Q8_0_TENSOR_BYTES(numel, (uint32_t)gs);
    }

    w->wq_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(dim * (heads * head_size), (uint32_t)gs);
    w->wk_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(dim * (kv_heads * head_size), (uint32_t)gs);
    w->wv_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(dim * (kv_heads * head_size), (uint32_t)gs);
    w->wo_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES((heads * head_size) * dim, (uint32_t)gs);
    w->w1_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(dim * hidden, (uint32_t)gs);
    w->w2_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(hidden * dim, (uint32_t)gs);
    w->w3_base = ptr; ptr += layers * Q8_0_TENSOR_BYTES(dim * hidden, (uint32_t)gs);

    if (shared_classifier) {
        w->wcls = w->q_tokens;
    } else {
        uint32_t numel = dim * vocab;
        w->wcls.q = (const int8_t *)ptr;
        w->wcls.s = (const float *)(ptr + numel);
        w->wcls.numel = numel;
        ptr += Q8_0_TENSOR_BYTES(numel, (uint32_t)gs);
    }
}

/* ===================================================================
 * RunState: activations + KV cache + quantized-activation scratch.
 * Static allocation (same T032 pattern as llama2.c) -- pointers computed
 * into the fixed ML_RUNSTATE_BASE region, NOT C globals, so this
 * program's own .bss never has to hold the KV cache.
 *
 * hidden_dim WARNING (model_load.h): every hidden_dim-sized field below
 * MUST be sized from the loaded cfg->hidden_dim, never hardcoded --
 * model.q8.bin's hidden_dim is 192, not stories260K's 172.
 * =================================================================== */

typedef struct {
    float *x, *xb, *xb2, *hb, *hb2, *q, *k, *v, *att, *logits;
    int8_t *xq_q; float *xq_s;   /* quantized dim-sized activation scratch */
    int8_t *hq_q; float *hq_s;   /* quantized hidden_dim-sized activation scratch */
    float *key_cache, *value_cache;
} Q8RunState;

/* Rounds an SDRAM byte offset up to 4-byte alignment. Mandatory between an
 * int8 array and the next float array below -- FemtoRV/SDRAM give no
 * guarantee of tolerating a misaligned float load (same caution llama2.c
 * documents for the tokenizer's packed records). */
static uint32_t align4(uint32_t off) {
    return (off + 3u) & ~3u;
}

/* Total bytes RunState needs for this model+gs. Kept in lockstep with
 * setup_q8_runstate() below -- same fields, same order, same alignment. */
static uint64_t q8_runstate_bytes(const Q8Config *cfg, int32_t gs) {
    uint64_t dim     = (uint64_t)cfg->dim;
    uint64_t hidden  = (uint64_t)cfg->hidden_dim;
    uint64_t heads   = (uint64_t)cfg->n_heads;
    uint64_t kv_dim  = (dim * (uint64_t)cfg->n_kv_heads) / (uint64_t)cfg->n_heads;
    uint64_t seq     = (uint64_t)cfg->seq_len;
    uint64_t layers  = (uint64_t)cfg->n_layers;
    uint64_t vocab   = (uint64_t)cfg->vocab_size;
    uint64_t ugs     = (uint64_t)gs;

    uint64_t off = 0;
    off += dim * 4;                 /* x */
    off += dim * 4;                 /* xb */
    off += dim * 4;                 /* xb2 */
    off += hidden * 4;              /* hb */
    off += hidden * 4;              /* hb2 */
    off += dim * 4;                 /* q */
    off += dim;                     /* xq_q */
    off = (off + 3u) & ~3u;
    off += (dim / ugs) * 4;         /* xq_s */
    off += hidden;                  /* hq_q */
    off = (off + 3u) & ~3u;
    off += (hidden / ugs) * 4;      /* hq_s */
    off += heads * seq * 4;         /* att */
    off += vocab * 4;               /* logits */
    off += 2ull * layers * seq * kv_dim * 4; /* key_cache + value_cache */
    return off;
}

static void setup_q8_runstate(Q8RunState *s, const Q8Config *cfg, int32_t gs) {
    uint32_t dim     = (uint32_t)cfg->dim;
    uint32_t hidden  = (uint32_t)cfg->hidden_dim;
    uint32_t heads   = (uint32_t)cfg->n_heads;
    uint32_t kv_dim  = (dim * (uint32_t)cfg->n_kv_heads) / (uint32_t)cfg->n_heads;
    uint32_t seq     = (uint32_t)cfg->seq_len;
    uint32_t layers  = (uint32_t)cfg->n_layers;
    uint32_t vocab   = (uint32_t)cfg->vocab_size;
    uint32_t ugs     = (uint32_t)gs;

    uint8_t *base = (uint8_t *)ML_RUNSTATE_BASE;
    uint32_t off = 0;

    s->x   = (float *)(base + off); off += dim * 4;
    s->xb  = (float *)(base + off); off += dim * 4;
    s->xb2 = (float *)(base + off); off += dim * 4;
    s->hb  = (float *)(base + off); off += hidden * 4;
    s->hb2 = (float *)(base + off); off += hidden * 4;
    s->q   = (float *)(base + off); off += dim * 4;

    s->xq_q = (int8_t *)(base + off); off += dim;
    off = align4(off);
    s->xq_s = (float *)(base + off); off += (dim / ugs) * 4;

    s->hq_q = (int8_t *)(base + off); off += hidden;
    off = align4(off);
    s->hq_s = (float *)(base + off); off += (hidden / ugs) * 4;

    s->att = (float *)(base + off); off += heads * seq * 4;
    s->logits = (float *)(base + off); off += vocab * 4;
    s->key_cache   = (float *)(base + off); off += layers * seq * kv_dim * 4;
    s->value_cache = (float *)(base + off); off += layers * seq * kv_dim * 4;
    s->k = s->key_cache;   /* re-pointed per (layer,pos) inside forward() */
    s->v = s->value_cache;
}

/* ===================================================================
 * Neural net blocks. rmsnorm/softmax are byte-identical to llama2.c's
 * (and to runq_host.c's -- quantization touches only the matmul inputs,
 * not these). matmul_q8/RoPE below are new for the quantized path.
 * =================================================================== */

static void rmsnorm(float *o, const float *x, const float *weight, int size) {
    float ss = 0.0f;
    for (int j = 0; j < size; j++) ss += x[j] * x[j];
    ss /= (float)size;
    ss += 1e-5f;
    ss = 1.0f / sqrtf(ss);
    for (int j = 0; j < size; j++) o[j] = weight[j] * (ss * x[j]);
}

static void softmax(float *x, int size) {
    float max_val = x[0];
    for (int i = 1; i < size; i++) if (x[i] > max_val) max_val = x[i];
    float sum = 0.0f;
    for (int i = 0; i < size; i++) { x[i] = expf(x[i] - max_val); sum += x[i]; }
    for (int i = 0; i < size; i++) x[i] /= sum;
}

/* W (d,n) @ x (n,) -> xout (d,), both quantized. Verbatim arithmetic port
 * of runq_host.c's matmul() (its --dump-mm debug parameters/branch
 * dropped -- they only ever print, never alter `val`/`ival`). This is
 * the function the accelerator (feature 004's RTL work, later phases)
 * exists to replace; by far the most time is spent here. */
static void matmul_q8(float *xout, const Q8Tensor *x, const Q8Tensor *w, int n, int d, int gs) {
    for (int i = 0; i < d; i++) {
        float val = 0.0f;
        int32_t ival = 0;
        int in = i * n;

        int j;
        for (j = 0; j <= n - gs; j += gs) {
            for (int k = 0; k < gs; k++) {
                ival += ((int32_t) x->q[j + k]) * ((int32_t) w->q[in + j + k]);
            }
            float contrib = ((float) ival) * w->s[(in + j) / gs] * x->s[j / gs];
            val += contrib;
            ival = 0;
        }

        xout[i] = val;
    }
}

static float *forward_q8(const Q8Config *cfg, const Q8Weights *w, Q8RunState *s, int32_t gs,
                          int token, int pos) {
    int dim = cfg->dim;
    int kv_dim = (cfg->dim * cfg->n_kv_heads) / cfg->n_heads;
    int kv_mul = cfg->n_heads / cfg->n_kv_heads;
    int hidden_dim = cfg->hidden_dim;
    int head_size = dim / cfg->n_heads;

    float *x = s->x;

    /* Dequantize this token's embedding row on demand: x[j] = q[i]*s[i/GS]
     * for i = token*dim+j -- same formula runq_host.c's dequantize()
     * applies to the WHOLE table once at startup; see file header note 2
     * on why computing only this row here is value-identical. */
    {
        uint32_t base_idx = (uint32_t)token * (uint32_t)dim;
        const int8_t *tq = w->q_tokens.q;
        const float  *ts = w->q_tokens.s;
        for (int j = 0; j < dim; j++) {
            uint32_t idx = base_idx + (uint32_t)j;
            x[j] = (float)tq[idx] * ts[idx / (uint32_t)gs];
        }
    }

    for (int l = 0; l < cfg->n_layers; l++) {

        prof_begin(PROF_RMSNORM);
        rmsnorm(s->xb, x, w->rms_att_weight + (uint32_t)l * dim, dim);
        prof_end(PROF_RMSNORM);

        uint32_t loff = (uint32_t)l * cfg->seq_len * kv_dim;
        s->k = s->key_cache + loff + (uint32_t)pos * kv_dim;
        s->v = s->value_cache + loff + (uint32_t)pos * kv_dim;

        prof_begin(PROF_QUANT);
        quantize_activations(s->xq_q, s->xq_s, s->xb, dim, gs);
        prof_end(PROF_QUANT);

        Q8Tensor xq_t = { s->xq_q, s->xq_s, (uint32_t)dim };
        Q8Tensor wq_l, wk_l, wv_l;
        q8_layer_tensor(&wq_l, w->wq_base, (uint32_t)l, (uint32_t)(dim * dim), gs);
        q8_layer_tensor(&wk_l, w->wk_base, (uint32_t)l, (uint32_t)(dim * kv_dim), gs);
        q8_layer_tensor(&wv_l, w->wv_base, (uint32_t)l, (uint32_t)(dim * kv_dim), gs);

        prof_begin(PROF_MATMUL);
        matmul_q8(s->q, &xq_t, &wq_l, dim, dim, gs);
        matmul_q8(s->k, &xq_t, &wk_l, dim, kv_dim, gs);
        matmul_q8(s->v, &xq_t, &wv_l, dim, kv_dim, gs);
        prof_end(PROF_MATMUL);

        /* RoPE: no table lookup for this format -- see file header. */
        prof_begin(PROF_ROPE);
        for (int i = 0; i < dim; i += 2) {
            int head_dim = i % head_size;
            float freq = 1.0f / powf(10000.0f, head_dim / (float)head_size);
            float val = pos * freq;
            float fcr = cosf(val);
            float fci = sinf(val);
            int rotn = i < kv_dim ? 2 : 1; /* 2 = rotate q & k, 1 = q only */
            for (int v = 0; v < rotn; v++) {
                float *vec = v == 0 ? s->q : s->k;
                float v0 = vec[i], v1 = vec[i + 1];
                vec[i]     = v0 * fcr - v1 * fci;
                vec[i + 1] = v0 * fci + v1 * fcr;
            }
        }
        prof_end(PROF_ROPE);

        /* s->k/s->v already alias this (layer,pos)'s cache row (see file
         * header note 1), so no memcpy into the cache is needed here. */

        prof_begin(PROF_ATTENTION);
        for (int h = 0; h < cfg->n_heads; h++) {
            float *q = s->q + (uint32_t)h * head_size;
            float *att = s->att + (uint32_t)h * cfg->seq_len;

            for (int t = 0; t <= pos; t++) {
                const float *k = s->key_cache + loff + (uint32_t)t * kv_dim
                                  + (uint32_t)(h / kv_mul) * head_size;
                float score = 0.0f;
                for (int i = 0; i < head_size; i++) score += q[i] * k[i];
                score /= sqrtf((float)head_size);
                att[t] = score;
            }

            softmax(att, pos + 1);

            float *xb = s->xb + (uint32_t)h * head_size;
            memset(xb, 0, (size_t)head_size * sizeof(float));
            for (int t = 0; t <= pos; t++) {
                const float *v = s->value_cache + loff + (uint32_t)t * kv_dim
                                  + (uint32_t)(h / kv_mul) * head_size;
                float a = att[t];
                for (int i = 0; i < head_size; i++) xb[i] += a * v[i];
            }
        }
        prof_end(PROF_ATTENTION);

        prof_begin(PROF_QUANT);
        quantize_activations(s->xq_q, s->xq_s, s->xb, dim, gs);
        prof_end(PROF_QUANT);

        Q8Tensor wo_l;
        q8_layer_tensor(&wo_l, w->wo_base, (uint32_t)l, (uint32_t)(dim * dim), gs);

        prof_begin(PROF_MATMUL);
        matmul_q8(s->xb2, &xq_t, &wo_l, dim, dim, gs);
        prof_end(PROF_MATMUL);

        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        prof_begin(PROF_RMSNORM);
        rmsnorm(s->xb, x, w->rms_ffn_weight + (uint32_t)l * dim, dim);
        prof_end(PROF_RMSNORM);

        prof_begin(PROF_QUANT);
        quantize_activations(s->xq_q, s->xq_s, s->xb, dim, gs);
        prof_end(PROF_QUANT);

        Q8Tensor w1_l, w3_l;
        q8_layer_tensor(&w1_l, w->w1_base, (uint32_t)l, (uint32_t)(dim * hidden_dim), gs);
        q8_layer_tensor(&w3_l, w->w3_base, (uint32_t)l, (uint32_t)(dim * hidden_dim), gs);

        prof_begin(PROF_MATMUL);
        matmul_q8(s->hb,  &xq_t, &w1_l, dim, hidden_dim, gs);
        matmul_q8(s->hb2, &xq_t, &w3_l, dim, hidden_dim, gs);
        prof_end(PROF_MATMUL);

        /* SwiGLU: silu(w1(x)) * w3(x). Elementwise, cheap -- "other"
         * residual per profile.h's coverage design, same as llama2.c. */
        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= (1.0f / (1.0f + expf(-val)));
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        prof_begin(PROF_QUANT);
        quantize_activations(s->hq_q, s->hq_s, s->hb, hidden_dim, gs);
        prof_end(PROF_QUANT);

        Q8Tensor hq_t = { s->hq_q, s->hq_s, (uint32_t)hidden_dim };
        Q8Tensor w2_l;
        q8_layer_tensor(&w2_l, w->w2_base, (uint32_t)l, (uint32_t)(hidden_dim * dim), gs);

        prof_begin(PROF_MATMUL);
        matmul_q8(s->xb, &hq_t, &w2_l, hidden_dim, dim, gs);
        prof_end(PROF_MATMUL);

        for (int i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    prof_begin(PROF_RMSNORM);
    rmsnorm(x, x, w->rms_final_weight, dim);
    prof_end(PROF_RMSNORM);

    prof_begin(PROF_QUANT);
    quantize_activations(s->xq_q, s->xq_s, x, dim, gs);
    prof_end(PROF_QUANT);

    {
        Q8Tensor xq_t = { s->xq_q, s->xq_s, (uint32_t)dim };
        prof_begin(PROF_MATMUL);
        matmul_q8(s->logits, &xq_t, &w->wcls, dim, cfg->vocab_size, gs);
        prof_end(PROF_MATMUL);
    }

    return s->logits;
}

/* ===================================================================
 * Tokenizer: identical to llama2.c's -- the tokenizer file format and
 * BPE algorithm are unaffected by weight quantization. Parsed directly
 * out of the raw bytes ml_load_tokenizer_q8() placed at ML_TOKENIZER_BASE.
 * =================================================================== */

typedef struct {
    const char *str;
    uint16_t len;
    uint16_t id;
} vocab_entry_t;

static vocab_entry_t g_vocab[MAX_VOCAB];   /* index == token id */
static vocab_entry_t g_sorted[MAX_VOCAB];  /* sorted by content, for encode() lookups */
static float g_vocab_score[MAX_VOCAB];
static uint32_t g_vocab_size;

static int vocab_cmp(const char *a, int alen, const char *b, int blen) {
    int n = alen < blen ? alen : blen;
    for (int i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (ca != cb) return (int)ca - (int)cb;
    }
    return alen - blen;
}

static int str_lookup(const char *str, int len) {
    int lo = 0, hi = (int)g_vocab_size - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        int c = vocab_cmp(g_sorted[mid].str, g_sorted[mid].len, str, len);
        if (c == 0) return g_sorted[mid].id;
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

static int build_tokenizer(uint32_t vocab_size) {
    if (vocab_size > MAX_VOCAB) return -1;

    const uint8_t *base = (const uint8_t *)ML_TOKENIZER_BASE;
    uint32_t max_len = rd_u32le(base);
    if (max_len > MAX_TOKEN_LEN) return -1;

    g_vocab_size = vocab_size;
    uint32_t off = 4;
    for (uint32_t i = 0; i < vocab_size; i++) {
        float score = rd_f32le(base + off); off += 4;
        uint32_t len = rd_u32le(base + off); off += 4;
        g_vocab_score[i] = score;
        g_vocab[i].str = (const char *)(base + off);
        g_vocab[i].len = (uint16_t)len;
        g_vocab[i].id  = (uint16_t)i;
        off += len;
    }

    for (uint32_t i = 0; i < vocab_size; i++) g_sorted[i] = g_vocab[i];

    for (uint32_t i = 1; i < vocab_size; i++) {
        vocab_entry_t key = g_sorted[i];
        int j = (int)i - 1;
        while (j >= 0 && vocab_cmp(g_sorted[j].str, g_sorted[j].len, key.str, key.len) > 0) {
            g_sorted[j + 1] = g_sorted[j];
            j--;
        }
        g_sorted[j + 1] = key;
    }
    return 0;
}

static int encode(const char *text, int bos, int eos, int *tokens) {
    int n_tokens = 0;
    char str_buffer[STRBUF_LEN];
    int str_len = 0;

    if (bos) tokens[n_tokens++] = 1;

    if (text[0] != '\0') {
        int dummy_prefix = str_lookup(" ", 1);
        tokens[n_tokens++] = dummy_prefix;
    }

    for (const char *c = text; *c != '\0'; c++) {
        if ((*c & 0xC0) != 0x80) str_len = 0;
        str_buffer[str_len++] = *c;
        if (((*(c + 1)) & 0xC0) == 0x80 && str_len < 4) continue;

        int id = str_lookup(str_buffer, str_len);
        if (id != -1) {
            tokens[n_tokens++] = id;
        } else {
            for (int i = 0; i < str_len; i++)
                tokens[n_tokens++] = (unsigned char)str_buffer[i] + 3;
        }
        str_len = 0;
    }

    for (;;) {
        float best_score = -1e10f;
        int best_id = -1, best_idx = -1;
        for (int i = 0; i < n_tokens - 1; i++) {
            int l1 = g_vocab[tokens[i]].len, l2 = g_vocab[tokens[i + 1]].len;
            if (l1 + l2 > STRBUF_LEN - 1) continue;
            memcpy(str_buffer, g_vocab[tokens[i]].str, (size_t)l1);
            memcpy(str_buffer + l1, g_vocab[tokens[i + 1]].str, (size_t)l2);
            int id = str_lookup(str_buffer, l1 + l2);
            if (id != -1 && g_vocab_score[id] > best_score) {
                best_score = g_vocab_score[id];
                best_id = id;
                best_idx = i;
            }
        }
        if (best_idx == -1) break;
        tokens[best_idx] = best_id;
        for (int i = best_idx + 1; i < n_tokens - 1; i++) tokens[i] = tokens[i + 1];
        n_tokens--;
    }

    if (eos) tokens[n_tokens++] = 2;
    return n_tokens;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int is_print_or_space(unsigned char c) {
    return (c >= 32 && c < 127) || c == '\n' || c == '\t' || c == '\r';
}

static void decode_piece(int prev_token, int token, const char **out_ptr, int *out_len) {
    const char *piece = g_vocab[token].str;
    int len = g_vocab[token].len;

    if (prev_token == 1 && len > 0 && piece[0] == ' ') { piece++; len--; }

    if (len == 6 && piece[0] == '<' && piece[1] == '0' && piece[2] == 'x' && piece[5] == '>') {
        int hi = hex_digit(piece[3]), lo = hex_digit(piece[4]);
        if (hi >= 0 && lo >= 0) {
            static char byte_buf[1];
            byte_buf[0] = (char)((hi << 4) | lo);
            *out_ptr = byte_buf;
            *out_len = 1;
            return;
        }
    }
    *out_ptr = piece;
    *out_len = len;
}

static void safe_print_piece(const char *p, int len) {
    if (!p || len <= 0) return;
    if (len == 1 && !is_print_or_space((unsigned char)p[0])) return;
    for (int i = 0; i < len; i++) putchar((unsigned char)p[i]);
}

/* ===================================================================
 * Sampler: identical to llama2.c's -- xorshift64 RNG + argmax/multinomial/
 * top-p, bit-for-bit matching run.c/runq_host.c for the same seed.
 * =================================================================== */

static uint32_t random_u32(uint64_t *state) {
    *state ^= *state >> 12;
    *state ^= *state << 25;
    *state ^= *state >> 27;
    return (uint32_t)((*state * 0x2545F4914F6CDD1Dull) >> 32);
}

static float random_f32(uint64_t *state) {
    return (float)(random_u32(state) >> 8) / 16777216.0f;
}

static int sample_argmax(const float *p, int n) {
    int mi = 0; float mp = p[0];
    for (int i = 1; i < n; i++) if (p[i] > mp) { mi = i; mp = p[i]; }
    return mi;
}

static int sample_mult(const float *p, int n, float coin) {
    float cdf = 0.0f;
    for (int i = 0; i < n; i++) { cdf += p[i]; if (coin < cdf) return i; }
    return n - 1;
}

typedef struct { float prob; int index; } prob_idx_t;
static prob_idx_t g_probindex[MAX_VOCAB];

static int sample_topp(const float *p, int n, float topp, float coin) {
    int n0 = 0;
    float cutoff = (1.0f - topp) / (float)(n - 1);
    for (int i = 0; i < n; i++) {
        if (p[i] >= cutoff) { g_probindex[n0].index = i; g_probindex[n0].prob = p[i]; n0++; }
    }

    for (int i = 1; i < n0; i++) {
        prob_idx_t key = g_probindex[i];
        int j = i - 1;
        while (j >= 0 && g_probindex[j].prob < key.prob) { g_probindex[j + 1] = g_probindex[j]; j--; }
        g_probindex[j + 1] = key;
    }

    float cumulative = 0.0f;
    int last_idx = n0 - 1;
    for (int i = 0; i < n0; i++) {
        cumulative += g_probindex[i].prob;
        if (cumulative > topp) { last_idx = i; break; }
    }

    float r = coin * cumulative;
    float cdf = 0.0f;
    for (int i = 0; i <= last_idx; i++) {
        cdf += g_probindex[i].prob;
        if (r < cdf) return g_probindex[i].index;
    }
    return g_probindex[last_idx].index;
}

static int sample_token(float *logits, int n, uint64_t *rng) {
    if (GEN_TEMPERATURE_X100 == 0) return sample_argmax(logits, n);

    float temperature = GEN_TEMPERATURE_X100 / 100.0f;
    for (int i = 0; i < n; i++) logits[i] /= temperature;
    softmax(logits, n);

    float coin = random_f32(rng);
    float topp = GEN_TOPP_X100 / 100.0f;
    if (topp <= 0.0f || topp >= 1.0f) return sample_mult(logits, n, coin);
    return sample_topp(logits, n, topp, coin);
}

/* ===================================================================
 * main(): banner -> mount -> load Q8_0 model+tokenizer -> set up weight/
 * RunState pointers -> generate, streaming each token as produced ->
 * print achieved rate -> optional profile report.
 * =================================================================== */

int main(void) {
    printf("\r\n");
    printf("runq (int8 Q8_0) on FemtoRV (RV32IMFC / petitbateau)\r\n");

    prof_enable(MEASURE_MODE);
    prof_reset();

    ml_status_t st = ml_mount();
    if (st != ML_OK) {
        printf("SD mount failed: %s\r\n", ml_strerror(st));
        return 1;
    }

    Q8Config cfg;
    uint8_t shared_classifier;
    int32_t gs;
    ml_report_t rep;

    st = ml_load_model_q8("/model.q8.bin", &cfg, &shared_classifier, &gs, &rep);
    if (st != ML_OK) {
        printf("model load failed: %s\r\n", ml_strerror(st));
        return 1;
    }
    ml_print_report("model", &rep);

    st = ml_load_tokenizer_q8("/tokenizer.bin", &cfg, &rep);
    if (st != ML_OK) {
        printf("tokenizer load failed: %s\r\n", ml_strerror(st));
        return 1;
    }
    ml_print_report("tokenizer", &rep);

    printf("dim=%d hidden=%d layers=%d heads=%d kv_heads=%d vocab=%d seq_len=%d gs=%d shared_cls=%d\r\n",
           cfg.dim, cfg.hidden_dim, cfg.n_layers, cfg.n_heads,
           cfg.n_kv_heads, cfg.vocab_size, cfg.seq_len, (int)gs, (int)shared_classifier);

    if (build_tokenizer((uint32_t)cfg.vocab_size) != 0) {
        printf("REFUSING: tokenizer vocab_size=%d or max_token_length exceeds this build's "
               "static limits (MAX_VOCAB=%d, MAX_TOKEN_LEN=%d)\r\n",
               cfg.vocab_size, MAX_VOCAB, MAX_TOKEN_LEN);
        return 1;
    }

    /* Verify the RunState (activations + KV cache + quantized-activation
     * scratch) fits the fixed 960KB budget BEFORE touching any of it. */
    uint64_t need = q8_runstate_bytes(&cfg, gs);
    printf("RunState needs %d bytes (limit %d bytes)\r\n",
           (int)need, (int)ML_RUNSTATE_LIMIT);
    if (need > ML_RUNSTATE_LIMIT) {
        printf("REFUSING: activations + KV cache do not fit in the %d byte budget "
               "at 0x%x -- reduce seq_len or layers\r\n",
               (int)ML_RUNSTATE_LIMIT, ML_RUNSTATE_BASE);
        return 1;
    }

    Q8Weights w;
    setup_q8_weights(&w, &cfg, gs, shared_classifier);
    Q8RunState s;
    setup_q8_runstate(&s, &cfg, gs);

    printf("prompt: %s\r\n", GEN_PROMPT);

    int prompt_tokens[MAX_PROMPT_TOKENS];
    int n_prompt = encode(GEN_PROMPT, 1, 0, prompt_tokens);
    if (n_prompt < 1) {
        printf("encode() produced no tokens for the prompt\r\n");
        return 1;
    }

    int steps = GEN_NUM_TOKENS;
    if (steps <= 0 || steps > cfg.seq_len) steps = cfg.seq_len;

    uint32_t seed = GEN_SEED;
    if (seed == 0) seed = (uint32_t)cycles();
    uint64_t rng_state = seed ? seed : 0x2545F4914F6CDD1Dull;

    prof_run_begin();

    int token = prompt_tokens[0];
    int pos = 0;
    uint64_t t_start = 0;

    while (pos < steps) {
        float *logits = forward_q8(&cfg, &w, &s, gs, token, pos);

        int next;
        if (pos < n_prompt - 1) {
            next = prompt_tokens[pos + 1];
        } else {
            prof_begin(PROF_SAMPLE);
            next = sample_token(logits, cfg.vocab_size, &rng_state);
            prof_end(PROF_SAMPLE);
        }
        pos++;

        if (next == 1) break; /* BOS token delimits sequences, per run.c */

        const char *piece; int plen;
        decode_piece(token, next, &piece, &plen);
        safe_print_piece(piece, plen);

        token = next;
        if (t_start == 0) t_start = cycles(); /* skip first (slower, cold-cache) iteration */
    }
    printf("\r\n");

    uint64_t t_end = cycles();
    if (pos > 1 && t_start != 0) {
        uint64_t elapsed = t_end - t_start;
        if (elapsed == 0) elapsed = 1;
        uint64_t rate_x100 = ((uint64_t)(pos - 1) * 100ull * CPU_HZ) / elapsed;
        uint32_t elapsed_tenths = (uint32_t)((elapsed * 10ull) / CPU_HZ);
        printf("achieved %d.%d tok/s (%d tokens in %d.%d s)\r\n",
               (int)(rate_x100 / 100), (int)(rate_x100 % 100),
               (int)(pos - 1), (int)(elapsed_tenths / 10),
               (int)(elapsed_tenths % 10));
    }

    prof_run_end((uint32_t)pos);
    if (MEASURE_MODE) prof_report();

    return 0;
}
