/*
 * run_host.c - host (desktop) fp32 reference implementation of the same
 * inference engine as ../llama2.c, the FemtoRV port. Builds with plain
 * gcc; no FemtoRV headers, no SDRAM, no SD card.
 *
 * WHY THIS FILE EXISTS: feature 004 quantizes the model to int8 and needs
 * a full-precision baseline to measure the quantized model's output
 * quality against (KL divergence over the two models' predicted token
 * distributions, computed by tools/kl_compare.py from the logit dumps
 * this program and tools/runq_host.c produce -- see specs/004-int8-matmul-
 * accel/tasks.md T011-T013). This program is also the thing that must be
 * matched bit-for-bit: ../llama2.c on the FPGA produced known-good text
 * for prompt "Once upon a time" with seed 2026, and this host port must
 * reproduce that exact text, because it is the same arithmetic run on
 * the same model file, just fed from a local file instead of SD/SDRAM.
 *
 * Ported from ../llama2.c (see that file's header comment for background
 * on the legacy weight format and table-based RoPE) by:
 *   - replacing the fixed ML_WEIGHTS_BASE / ML_TOKENIZER_BASE / ML_RUNSTATE_BASE
 *     SDRAM regions with malloc'd host buffers and plain fread() from
 *     tools/model.bin and tools/tokenizer.bin
 *   - replacing FemtoRV's printf/putchar serial output with normal stdio
 *   - replacing cycles()/CPU_HZ timing with clock_gettime()
 *   - dropping the profiler hooks (prof_begin/prof_end/prof_report) --
 *     they measured FemtoRV cycle counts per code region, which has no
 *     host-side equivalent worth keeping
 *
 * The neural net math itself (rmsnorm, softmax, matmul, table-based RoPE,
 * attention, sampler) is copied verbatim from llama2.c: same operand
 * order, same accumulation order, same float32 throughout (no double
 * anywhere). Do not "clean up" the arithmetic here -- the whole point of
 * this file is to match, not to be idiomatic.
 *
 * *** Legacy weight format (see ../llama2.c's header comment for the
 * full derivation) ***: tools/model.bin is the OLD llama2.c export --
 * 28-byte header (7x int32: dim, hidden_dim, n_layers, n_heads,
 * n_kv_heads, vocab_size, seq_len; a negative vocab_size means an
 * unshared classifier), NO magic number, and it INCLUDES precomputed
 * freq_cis_real/freq_cis_imag RoPE tables (seq_len*head_size/2 floats
 * each) between rms_final_weight and the (optional) classifier weights.
 *
 * *** Logit dump format (--dump-logits FILE) ***
 * A sibling program, tools/runq_host.c, adds the same flag for the
 * quantized model so tools/kl_compare.py can diff the two models'
 * predicted distributions position-by-position. This exact layout is a
 * cross-file contract with runq_host.c -- do not change it here without
 * changing it there too. Little-endian (native on x86; a plain fwrite is
 * fine), no padding:
 *   int32   magic       = 0x4C4F4754   ('LOGT')
 *   int32   n_positions                -- number of rows that follow
 *   int32   vocab_size                 -- length of each row
 *   float32 logits[n_positions * vocab_size]   -- row-major, raw
 *                                                 pre-softmax logits
 *                                                 straight out of
 *                                                 forward()
 * Rows are in generation order and INCLUDE the positions consumed by the
 * prompt (i.e. one row per call to forward(), regardless of whether that
 * position's next token was teacher-forced from the prompt or sampled) --
 * kl_compare.py must skip the first (n_prompt - 1) rows itself if it only
 * wants sampled positions.
 * Written as one fwrite of the header followed by one fwrite per position
 * as it is produced (so a killed run still leaves a readable prefix if
 * n_positions in the header is patched up at the end -- which this
 * program does: it seeks back and rewrites n_positions once generation
 * finishes).
 *
 * Reference ported from (by way of ../llama2.c's adaptation):
 *   https://github.com/karpathy/llama2.c/blob/master/run.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

/* ===================================================================
 * User-editable run parameters -- same defaults as ../llama2.c, but
 * every one of these is now overridable from the command line so the
 * same binary can be used for both the byte-exact FPGA-matching check
 * and for the KL-divergence sweeps in tools/kl_compare.py.
 * =================================================================== */

#define DEFAULT_PROMPT          "Once upon a time"
#define DEFAULT_NUM_TOKENS      110     /* generate at most this many tokens; clamped to seq_len */
#define DEFAULT_TEMPERATURE_X100 100    /* temperature * 100 (0 = greedy argmax, 100 = 1.00) */
#define DEFAULT_TOPP_X100         90    /* top-p * 100 (<=0 or >=100 disables nucleus sampling) */
#define DEFAULT_SEED           2026u    /* RNG seed; 0 => derive from time() at startup */

#define MAX_VOCAB       4096
#define MAX_TOKEN_LEN    64
#define STRBUF_LEN      (MAX_TOKEN_LEN * 2 + 4)

#define HEADER_BYTES 28u   /* 7 * int32, legacy llama2.c export */

/* ===================================================================
 * Little-endian unaligned reads -- kept for parity with llama2.c even
 * though host buffers are always well-aligned; harmless either way.
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

static int32_t rd_i32le(const uint8_t *p) {
    return (int32_t)rd_u32le(p);
}

/* ===================================================================
 * Model config + file loading. Legacy format only (see file header).
 * =================================================================== */

typedef struct {
    int32_t dim;
    int32_t hidden_dim;
    int32_t n_layers;
    int32_t n_heads;
    int32_t n_kv_heads;
    int32_t vocab_size;    /* always positive after load */
    int32_t seq_len;
    int     shared_weights;
} ModelConfig;

static int in_range(int32_t v, int32_t lo, int32_t hi) { return v >= lo && v <= hi; }

/* Size in bytes of the weight region described by cfg, NOT counting the
 * 28-byte header. Mirrors model_load.c's weight_bytes() exactly. */
static uint64_t weight_bytes(const ModelConfig *cfg) {
    uint64_t dim       = (uint64_t)cfg->dim;
    uint64_t hidden    = (uint64_t)cfg->hidden_dim;
    uint64_t layers    = (uint64_t)cfg->n_layers;
    uint64_t heads     = (uint64_t)cfg->n_heads;
    uint64_t kv_heads  = (uint64_t)cfg->n_kv_heads;
    uint64_t vocab     = (uint64_t)cfg->vocab_size;
    uint64_t seq       = (uint64_t)cfg->seq_len;
    uint64_t head_size = dim / heads;

    uint64_t floats = 0;
    floats += vocab * dim;
    floats += layers * dim;
    floats += layers * dim * (heads * head_size);
    floats += layers * dim * (kv_heads * head_size);
    floats += layers * dim * (kv_heads * head_size);
    floats += layers * (heads * head_size) * dim;
    floats += layers * dim;
    floats += layers * hidden * dim;
    floats += layers * dim * hidden;
    floats += layers * hidden * dim;
    floats += dim;
    floats += seq * (head_size / 2);
    floats += seq * (head_size / 2);
    if (!cfg->shared_weights)
        floats += vocab * dim;

    return floats * 4u;
}

/* Reads model.bin's header + weight blob into a freshly malloc'd buffer.
 * Returns the buffer (weights start at offset 0, header already
 * consumed/validated) or NULL on error (message already printed). */
static uint8_t *load_model(const char *path, ModelConfig *cfg) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "model load failed: cannot open %s\n", path); return NULL; }

    uint8_t hdr[HEADER_BYTES];
    if (fread(hdr, 1, HEADER_BYTES, f) != HEADER_BYTES) {
        fprintf(stderr, "model load failed: file shorter than its header implies\n");
        fclose(f);
        return NULL;
    }

    int32_t dim        = rd_i32le(hdr + 0);
    int32_t hidden     = rd_i32le(hdr + 4);
    int32_t n_layers   = rd_i32le(hdr + 8);
    int32_t n_heads    = rd_i32le(hdr + 12);
    int32_t n_kv_heads = rd_i32le(hdr + 16);
    int32_t vocab_raw  = rd_i32le(hdr + 20);
    int32_t seq_len    = rd_i32le(hdr + 24);

    if (!in_range(dim, 1, 4096) ||
        !in_range(hidden, 1, 65536) ||
        !in_range(n_layers, 1, 64) ||
        !in_range(n_heads, 1, 1024) ||
        !in_range(n_kv_heads, 1, 1024) ||
        !in_range(vocab_raw, -65536, 65536) || vocab_raw == 0 ||
        !in_range(seq_len, 1, 8192) ||
        (dim % n_heads) != 0) {
        fprintf(stderr, "model load failed: header fields out of sane range\n");
        fclose(f);
        return NULL;
    }

    ModelConfig c;
    c.dim           = dim;
    c.hidden_dim     = hidden;
    c.n_layers       = n_layers;
    c.n_heads        = n_heads;
    c.n_kv_heads     = n_kv_heads;
    c.shared_weights = (vocab_raw > 0) ? 1 : 0;
    c.vocab_size     = (vocab_raw < 0) ? -vocab_raw : vocab_raw;
    c.seq_len        = seq_len;

    uint64_t wbytes = weight_bytes(&c);

    if (fseek(f, 0, SEEK_END) != 0) { fprintf(stderr, "model load failed: seek error\n"); fclose(f); return NULL; }
    long file_len = ftell(f);
    if (file_len < 0 || (uint64_t)file_len != HEADER_BYTES + wbytes) {
        fprintf(stderr, "model load failed: file is %ld bytes, expected %llu "
                "(header + weights) -- wrong model file or format?\n",
                file_len, (unsigned long long)(HEADER_BYTES + wbytes));
        fclose(f);
        return NULL;
    }
    if (fseek(f, (long)HEADER_BYTES, SEEK_SET) != 0) {
        fprintf(stderr, "model load failed: seek error\n");
        fclose(f);
        return NULL;
    }

    uint8_t *buf = (uint8_t *)malloc((size_t)wbytes);
    if (!buf) { fprintf(stderr, "model load failed: out of memory (%llu bytes)\n", (unsigned long long)wbytes); fclose(f); return NULL; }

    if (fread(buf, 1, (size_t)wbytes, f) != (size_t)wbytes) {
        fprintf(stderr, "model load failed: short read on weights\n");
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);

    *cfg = c;
    return buf;
}

/* Reads the whole tokenizer file into a malloc'd buffer, validating its
 * internal structure (score/len/bytes records) the same way
 * model_load.c does, and checks the record count against cfg->vocab_size. */
static uint8_t *load_tokenizer(const char *path, const ModelConfig *cfg, uint32_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "tokenizer load failed: cannot open %s\n", path); return NULL; }

    if (fseek(f, 0, SEEK_END) != 0) { fprintf(stderr, "tokenizer load failed: seek error\n"); fclose(f); return NULL; }
    long file_len = ftell(f);
    if (file_len < 4) {
        fprintf(stderr, "tokenizer load failed: file shorter than its header implies\n");
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) { fprintf(stderr, "tokenizer load failed: seek error\n"); fclose(f); return NULL; }

    uint8_t *buf = (uint8_t *)malloc((size_t)file_len);
    if (!buf) { fprintf(stderr, "tokenizer load failed: out of memory\n"); fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)file_len, f) != (size_t)file_len) {
        fprintf(stderr, "tokenizer load failed: short read\n");
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);

    uint32_t total = (uint32_t)file_len;
    uint32_t off = 4;
    uint32_t count = 0;
    while (off < total) {
        if (off + 8 > total) { fprintf(stderr, "tokenizer load failed: truncated record\n"); free(buf); return NULL; }
        int32_t len = rd_i32le(buf + off + 4);
        if (len < 0 || off + 8 + (uint32_t)len > total) { fprintf(stderr, "tokenizer load failed: truncated record\n"); free(buf); return NULL; }
        off += 8 + (uint32_t)len;
        count++;
    }
    if (count != (uint32_t)cfg->vocab_size) {
        fprintf(stderr, "tokenizer load failed: token count %u != model vocab_size %d "
                "(mismatched model/tokenizer pair)\n", count, cfg->vocab_size);
        free(buf);
        return NULL;
    }

    *out_len = total;
    return buf;
}

/* ===================================================================
 * Weight pointers: same layout/order as ../llama2.c's setup_weights(),
 * just pointing into the malloc'd buffer from load_model() instead of
 * a fixed SDRAM address.
 * =================================================================== */

typedef struct {
    float *token_embedding;
    float *rms_att_weight;
    float *wq, *wk, *wv, *wo;
    float *rms_ffn_weight;
    float *w1, *w2, *w3;
    float *rms_final_weight;
    float *freq_cis_real, *freq_cis_imag;
    float *wcls;
} Weights;

static void setup_weights(Weights *w, const ModelConfig *cfg, uint8_t *weights_buf) {
    uint64_t dim = (uint64_t)cfg->dim;
    uint64_t hidden = (uint64_t)cfg->hidden_dim;
    uint64_t layers = (uint64_t)cfg->n_layers;
    uint64_t heads = (uint64_t)cfg->n_heads;
    uint64_t kv_heads = (uint64_t)cfg->n_kv_heads;
    uint64_t vocab = (uint64_t)cfg->vocab_size;
    uint64_t seq = (uint64_t)cfg->seq_len;
    uint64_t head_size = dim / heads;

    float *ptr = (float *)weights_buf;

    w->token_embedding = ptr; ptr += vocab * dim;
    w->rms_att_weight  = ptr; ptr += layers * dim;
    w->wq = ptr; ptr += layers * dim * (heads * head_size);
    w->wk = ptr; ptr += layers * dim * (kv_heads * head_size);
    w->wv = ptr; ptr += layers * dim * (kv_heads * head_size);
    w->wo = ptr; ptr += layers * (heads * head_size) * dim;
    w->rms_ffn_weight = ptr; ptr += layers * dim;
    w->w1 = ptr; ptr += layers * hidden * dim;
    w->w2 = ptr; ptr += layers * dim * hidden;
    w->w3 = ptr; ptr += layers * hidden * dim;
    w->rms_final_weight = ptr; ptr += dim;
    w->freq_cis_real = ptr; ptr += seq * (head_size / 2);
    w->freq_cis_imag = ptr; ptr += seq * (head_size / 2);
    w->wcls = cfg->shared_weights ? w->token_embedding : ptr;
}

/* ===================================================================
 * RunState: activations + KV cache. Plain malloc, one block per array
 * (no need to pack into a fixed region on the host).
 * =================================================================== */

typedef struct {
    float *x, *xb, *xb2, *hb, *hb2, *q, *k, *v, *att, *logits;
    float *key_cache, *value_cache;
} RunState;

static void setup_runstate(RunState *s, const ModelConfig *cfg) {
    uint64_t dim = (uint64_t)cfg->dim;
    uint64_t hidden = (uint64_t)cfg->hidden_dim;
    uint64_t heads = (uint64_t)cfg->n_heads;
    uint64_t kv_dim = (dim * (uint64_t)cfg->n_kv_heads) / (uint64_t)cfg->n_heads;
    uint64_t seq = (uint64_t)cfg->seq_len;
    uint64_t layers = (uint64_t)cfg->n_layers;
    uint64_t vocab = (uint64_t)cfg->vocab_size;

    s->x   = (float *)malloc(dim * sizeof(float));
    s->xb  = (float *)malloc(dim * sizeof(float));
    s->xb2 = (float *)malloc(dim * sizeof(float));
    s->hb  = (float *)malloc(hidden * sizeof(float));
    s->hb2 = (float *)malloc(hidden * sizeof(float));
    s->q   = (float *)malloc(dim * sizeof(float));
    s->att = (float *)malloc(heads * seq * sizeof(float));
    s->logits = (float *)malloc(vocab * sizeof(float));
    s->key_cache   = (float *)malloc(layers * seq * kv_dim * sizeof(float));
    s->value_cache = (float *)malloc(layers * seq * kv_dim * sizeof(float));

    if (!s->x || !s->xb || !s->xb2 || !s->hb || !s->hb2 || !s->q || !s->att ||
        !s->logits || !s->key_cache || !s->value_cache) {
        fprintf(stderr, "run_host: out of memory allocating RunState\n");
        exit(1);
    }

    s->k = s->key_cache;
    s->v = s->value_cache;
}

static void free_runstate(RunState *s) {
    free(s->x); free(s->xb); free(s->xb2); free(s->hb); free(s->hb2);
    free(s->q); free(s->att); free(s->logits);
    free(s->key_cache); free(s->value_cache);
}

/* ===================================================================
 * Neural net blocks -- verbatim from ../llama2.c (see that file's
 * comment about profile.h regions; the prof_begin/prof_end calls are
 * simply omitted here, the arithmetic in between is untouched).
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

static void matmul(float *xout, const float *x, const float *w, int n, int d) {
    for (int i = 0; i < d; i++) {
        float val = 0.0f;
        const float *wi = w + (uint32_t)i * n;
        for (int j = 0; j < n; j++) val += wi[j] * x[j];
        xout[i] = val;
    }
}

static void rope_rotate(RunState *s, const Weights *w, const ModelConfig *cfg,
                         int pos, int head_size) {
    const float *fcr_row = w->freq_cis_real + (uint32_t)pos * (head_size / 2);
    const float *fci_row = w->freq_cis_imag + (uint32_t)pos * (head_size / 2);

    for (int h = 0; h < cfg->n_heads; h++) {
        float *q = s->q + (uint32_t)h * head_size;
        for (int i = 0; i < head_size; i += 2) {
            float fcr = fcr_row[i / 2], fci = fci_row[i / 2];
            float q0 = q[i], q1 = q[i + 1];
            q[i]     = q0 * fcr - q1 * fci;
            q[i + 1] = q0 * fci + q1 * fcr;
        }
    }
    for (int h = 0; h < cfg->n_kv_heads; h++) {
        float *k = s->k + (uint32_t)h * head_size;
        for (int i = 0; i < head_size; i += 2) {
            float fcr = fcr_row[i / 2], fci = fci_row[i / 2];
            float k0 = k[i], k1 = k[i + 1];
            k[i]     = k0 * fcr - k1 * fci;
            k[i + 1] = k0 * fci + k1 * fcr;
        }
    }
}

static float *forward(const ModelConfig *cfg, const Weights *w, RunState *s,
                       int token, int pos) {
    int dim = cfg->dim;
    int kv_dim = (cfg->dim * cfg->n_kv_heads) / cfg->n_heads;
    int kv_mul = cfg->n_heads / cfg->n_kv_heads;
    int hidden_dim = cfg->hidden_dim;
    int head_size = dim / cfg->n_heads;

    float *x = s->x;
    const float *content_row = w->token_embedding + (uint32_t)token * dim;
    memcpy(x, content_row, (size_t)dim * sizeof(float));

    for (int l = 0; l < cfg->n_layers; l++) {

        rmsnorm(s->xb, x, w->rms_att_weight + (uint32_t)l * dim, dim);

        uint32_t loff = (uint32_t)l * cfg->seq_len * kv_dim;
        s->k = s->key_cache + loff + (uint32_t)pos * kv_dim;
        s->v = s->value_cache + loff + (uint32_t)pos * kv_dim;

        matmul(s->q, s->xb, w->wq + (uint32_t)l * dim * dim, dim, dim);
        matmul(s->k, s->xb, w->wk + (uint32_t)l * dim * kv_dim, dim, kv_dim);
        matmul(s->v, s->xb, w->wv + (uint32_t)l * dim * kv_dim, dim, kv_dim);

        rope_rotate(s, w, cfg, pos, head_size);

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

        matmul(s->xb2, s->xb, w->wo + (uint32_t)l * dim * dim, dim, dim);

        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        rmsnorm(s->xb, x, w->rms_ffn_weight + (uint32_t)l * dim, dim);

        matmul(s->hb,  s->xb, w->w1 + (uint32_t)l * dim * hidden_dim, dim, hidden_dim);
        matmul(s->hb2, s->xb, w->w3 + (uint32_t)l * dim * hidden_dim, dim, hidden_dim);

        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= (1.0f / (1.0f + expf(-val)));
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        matmul(s->xb, s->hb, w->w2 + (uint32_t)l * dim * hidden_dim, hidden_dim, dim);

        for (int i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    rmsnorm(x, x, w->rms_final_weight, dim);

    matmul(s->logits, x, w->wcls, dim, cfg->vocab_size);

    return s->logits;
}

/* ===================================================================
 * Tokenizer -- verbatim from ../llama2.c, reading from the malloc'd
 * tokenizer buffer instead of ML_TOKENIZER_BASE.
 * =================================================================== */

typedef struct {
    const char *str;
    uint16_t len;
    uint16_t id;
} vocab_entry_t;

static vocab_entry_t g_vocab[MAX_VOCAB];
static vocab_entry_t g_sorted[MAX_VOCAB];
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

static int build_tokenizer(const uint8_t *base, uint32_t vocab_size) {
    if (vocab_size > MAX_VOCAB) return -1;

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
 * Sampler -- verbatim from ../llama2.c.
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

static int sample_token(float *logits, int n, uint64_t *rng, int temperature_x100, int topp_x100) {
    if (temperature_x100 == 0) return sample_argmax(logits, n);

    float temperature = temperature_x100 / 100.0f;
    for (int i = 0; i < n; i++) logits[i] /= temperature;
    softmax(logits, n);

    float coin = random_f32(rng);
    float topp = topp_x100 / 100.0f;
    if (topp <= 0.0f || topp >= 1.0f) return sample_mult(logits, n, coin);
    return sample_topp(logits, n, topp, coin);
}

/* ===================================================================
 * Command-line options.
 * =================================================================== */

typedef struct {
    const char *model_path;
    const char *tokenizer_path;
    const char *prompt;
    int num_tokens;
    int temperature_x100;
    int topp_x100;
    uint32_t seed;
    const char *dump_logits_path;
} Options;

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "  -m PATH         model.bin path (default: model.bin)\n"
        "  -z PATH         tokenizer.bin path (default: tokenizer.bin)\n"
        "  -p PROMPT       prompt text (default: \"%s\")\n"
        "  -n N            max tokens to generate (default: %d)\n"
        "  -t TEMP_X100    temperature * 100, 0 = greedy (default: %d)\n"
        "  -x TOPP_X100    top-p * 100, <=0 or >=100 disables nucleus sampling (default: %d)\n"
        "  -s SEED         RNG seed, 0 = derive from time() (default: %u)\n"
        "  --dump-logits PATH   write per-position pre-softmax logit vectors to PATH\n"
        "                       (format documented in this file's header comment)\n",
        argv0, DEFAULT_PROMPT, DEFAULT_NUM_TOKENS, DEFAULT_TEMPERATURE_X100,
        DEFAULT_TOPP_X100, DEFAULT_SEED);
}

/* ===================================================================
 * main()
 * =================================================================== */

int main(int argc, char **argv) {
    Options opt;
    opt.model_path = "model.bin";
    opt.tokenizer_path = "tokenizer.bin";
    opt.prompt = DEFAULT_PROMPT;
    opt.num_tokens = DEFAULT_NUM_TOKENS;
    opt.temperature_x100 = DEFAULT_TEMPERATURE_X100;
    opt.topp_x100 = DEFAULT_TOPP_X100;
    opt.seed = DEFAULT_SEED;
    opt.dump_logits_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-m") && i + 1 < argc) opt.model_path = argv[++i];
        else if (!strcmp(argv[i], "-z") && i + 1 < argc) opt.tokenizer_path = argv[++i];
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) opt.prompt = argv[++i];
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) opt.num_tokens = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) opt.temperature_x100 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-x") && i + 1 < argc) opt.topp_x100 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) opt.seed = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--dump-logits") && i + 1 < argc) opt.dump_logits_path = argv[++i];
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "unrecognized option: %s\n", argv[i]); usage(argv[0]); return 1; }
    }

    printf("llama2.c fp32 host reference (run_host)\n");

    ModelConfig cfg;
    uint8_t *weights_buf = load_model(opt.model_path, &cfg);
    if (!weights_buf) return 1;

    uint32_t tok_len;
    uint8_t *tok_buf = load_tokenizer(opt.tokenizer_path, &cfg, &tok_len);
    if (!tok_buf) { free(weights_buf); return 1; }

    printf("dim=%d hidden=%d layers=%d heads=%d kv_heads=%d vocab=%d seq_len=%d\n",
           cfg.dim, cfg.hidden_dim, cfg.n_layers, cfg.n_heads,
           cfg.n_kv_heads, cfg.vocab_size, cfg.seq_len);

    if (build_tokenizer(tok_buf, (uint32_t)cfg.vocab_size) != 0) {
        fprintf(stderr, "REFUSING: tokenizer vocab_size=%d or max_token_length exceeds this "
                "build's static limits (MAX_VOCAB=%d, MAX_TOKEN_LEN=%d)\n",
                cfg.vocab_size, MAX_VOCAB, MAX_TOKEN_LEN);
        free(weights_buf); free(tok_buf);
        return 1;
    }

    Weights w;
    setup_weights(&w, &cfg, weights_buf);
    RunState s;
    setup_runstate(&s, &cfg);

    printf("prompt: %s\n", opt.prompt);

    int max_prompt_tokens = (int)strlen(opt.prompt) + 8;
    int *prompt_tokens = (int *)malloc((size_t)max_prompt_tokens * sizeof(int));
    int n_prompt = encode(opt.prompt, 1, 0, prompt_tokens);
    if (n_prompt < 1) {
        fprintf(stderr, "encode() produced no tokens for the prompt\n");
        return 1;
    }

    int steps = opt.num_tokens;
    if (steps <= 0 || steps > cfg.seq_len) steps = cfg.seq_len;

    uint32_t seed = opt.seed;
    if (seed == 0) seed = (uint32_t)time(NULL);
    uint64_t rng_state = seed ? seed : 0x2545F4914F6CDD1Dull;

    /* Logit dump: header written now with a placeholder n_positions,
     * patched to the real count once generation finishes (see file
     * header comment). */
    FILE *dump_f = NULL;
    int32_t dump_count = 0;
    if (opt.dump_logits_path) {
        dump_f = fopen(opt.dump_logits_path, "wb");
        if (!dump_f) {
            fprintf(stderr, "warning: could not open %s for --dump-logits, continuing without it\n",
                    opt.dump_logits_path);
        } else {
            int32_t magic = (int32_t)0x4C4F4754;
            int32_t placeholder_n = 0;
            int32_t vocab32 = cfg.vocab_size;
            fwrite(&magic, sizeof(int32_t), 1, dump_f);
            fwrite(&placeholder_n, sizeof(int32_t), 1, dump_f);
            fwrite(&vocab32, sizeof(int32_t), 1, dump_f);
        }
    }

    struct timespec t_start_ts, t_end_ts;
    int have_t_start = 0;

    int token = prompt_tokens[0];
    int pos = 0;

    while (pos < steps) {
        float *logits = forward(&cfg, &w, &s, token, pos);

        if (dump_f) {
            fwrite(logits, sizeof(float), (size_t)cfg.vocab_size, dump_f);
            dump_count++;
        }

        int next;
        if (pos < n_prompt - 1) {
            next = prompt_tokens[pos + 1];
        } else {
            next = sample_token(logits, cfg.vocab_size, &rng_state,
                                 opt.temperature_x100, opt.topp_x100);
        }
        pos++;

        if (next == 1) break; /* BOS token delimits sequences, per run.c */

        const char *piece; int plen;
        decode_piece(token, next, &piece, &plen);
        safe_print_piece(piece, plen);
        fflush(stdout);

        token = next;
        if (!have_t_start) { clock_gettime(CLOCK_MONOTONIC, &t_start_ts); have_t_start = 1; }
    }
    printf("\n");

    if (dump_f) {
        /* patch n_positions (2nd header field, right after magic) now
         * that we know it. */
        fseek(dump_f, sizeof(int32_t), SEEK_SET);
        fwrite(&dump_count, sizeof(int32_t), 1, dump_f);
        fclose(dump_f);
        printf("wrote %d logit records (vocab=%d) to %s\n", dump_count, cfg.vocab_size, opt.dump_logits_path);
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end_ts);
    if (pos > 1 && have_t_start) {
        double elapsed = (t_end_ts.tv_sec - t_start_ts.tv_sec) +
                          (t_end_ts.tv_nsec - t_start_ts.tv_nsec) / 1e9;
        if (elapsed <= 0.0) elapsed = 1e-9;
        double rate = (double)(pos - 1) / elapsed;
        printf("achieved %.2f tok/s (%d tokens in %.2f s)\n", rate, pos - 1, elapsed);
    }

    free(prompt_tokens);
    free_runstate(&s);
    free(weights_buf);
    free(tok_buf);

    return 0;
}
