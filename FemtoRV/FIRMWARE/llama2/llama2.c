/*
 * llama2.c - port of karpathy's llama2.c inference engine to FemtoRV
 * (RV32IMFC, petitbateau) with model weights and vocabulary loaded from
 * SD card into SDRAM by model_load.c, and output streamed over serial.
 *
 * Memory layout (see specs/003-llama2-minimal-soc/data-model.md and
 * model_load.h):
 *   0x800000 - 0x8FFFFF   1MB   this program (code + small static data)
 *   0x900000 - 0x9FFFFF   1MB   model weights            (ml_load_model)
 *   0xA00000 - 0xA0FFFF   64KB  tokenizer                (ml_load_tokenizer)
 *   0xA10000 - ~0xAFFFFF  960KB activations + KV cache   (this file, T032)
 *
 * The weights, tokenizer bytes, and RunState buffers are NOT ordinary C
 * globals: they are reached purely by pointer arithmetic into the fixed
 * SDRAM regions above (cast from the ML_*_BASE addresses in model_load.h).
 * There is no malloc anywhere in this file (T032) -- every buffer is
 * either a small bounded static array (tokenizer vocab index, sampler
 * scratch space) sized generously below, or a pointer computed into one
 * of the fixed regions once the real model's dimensions are known.
 *
 * *** Legacy weight format ***
 * tools/model.bin (stories260K: dim=64, hidden_dim=172, n_layers=5,
 * n_heads=8, n_kv_heads=4, vocab_size=512, seq_len=512) is the OLD
 * llama2.c export that includes precomputed freq_cis_real/freq_cis_imag
 * RoPE tables after rms_final_weight (model_load.c's weight_bytes() and
 * its file header comment confirm the arithmetic only matches with the
 * tables included). Because of this, RoPE below is a TABLE LOOKUP, not a
 * call to powf/sinf/cosf -- this removes the transcendental calls that
 * would otherwise be the second-biggest hotspot on this CPU after matmul.
 *
 * Reference ported from (and adapted away from, for RoPE + memory model):
 *   https://github.com/karpathy/llama2.c/blob/master/run.c
 */

#include <femtorv32.h>
#include <math.h>
#include <string.h>
#include "model_load.h"
#include "profile.h"

/* ===================================================================
 * User-editable run parameters. No command line on this target, so
 * everything generate()-related is a compile-time constant here.
 * =================================================================== */

#define GEN_PROMPT             "Once upon a time"
#define GEN_NUM_TOKENS         110     /* generate at most this many tokens; clamped to seq_len */
#define GEN_TEMPERATURE_X100   100     /* temperature * 100 (0 = greedy argmax, 100 = 1.00) */
#define GEN_TOPP_X100           90     /* top-p * 100 (<=0 or >=100 disables nucleus sampling) */
#define GEN_SEED               2026u   /* RNG seed; 0 => derive from cycles() at startup */
#define MEASURE_MODE             1     /* 1 = turn on profiling and print prof_report() at exit (T043) */

/* Board clock, used to convert cycles() into tokens/sec and ms (matches
 * model_load.c's CPU_HZ). */
#define CPU_HZ 25000000u

/* ===================================================================
 * Static capacity limits for tokenizer bookkeeping (NOT for weights or
 * activations -- those are sized from the real, loaded ModelConfig via
 * pointer arithmetic below). These bound small metadata tables that
 * live in this program's own bss; stories260K needs vocab=512,
 * max_token_length=7, so the margins here are generous.
 * =================================================================== */

#define MAX_VOCAB       600
#define MAX_TOKEN_LEN    32
#define STRBUF_LEN      (MAX_TOKEN_LEN * 2 + 4)
#define MAX_PROMPT_TOKENS ((int)sizeof(GEN_PROMPT) + 4) /* BOS + dummy-prefix + bytes + EOS + slack */

/* ===================================================================
 * Little-endian unaligned reads. tools/tokenizer.bin packs
 * {float score; int32 len; char bytes[len]} records back to back, so
 * every record after the first is very likely NOT 4-byte aligned in
 * SDRAM. FemtoRV has no guarantee of tolerating misaligned loads, so
 * every multi-byte field from that region is assembled byte-by-byte.
 * (Weights and RunState never need this: their arrays are all
 * fixed-size float32 runs, so 4-byte alignment holds throughout.)
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
 * Weight pointers: set up once, purely by pointer arithmetic into the
 * region ml_load_model() already filled at ML_WEIGHTS_BASE. Layout
 * (all fp32, confirmed against the real model.bin by model_load.c):
 *   token_embedding[vocab*dim] rms_att_weight[layers*dim]
 *   wq[layers*dim*heads*head_size] wk/wv[layers*dim*kv_heads*head_size]
 *   wo[layers*heads*head_size*dim] rms_ffn_weight[layers*dim]
 *   w1[layers*hidden*dim] w2[layers*dim*hidden] w3[layers*hidden*dim]
 *   rms_final_weight[dim] freq_cis_real[seq*head_size/2]
 *   freq_cis_imag[seq*head_size/2] (classifier shared with embedding)
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

static void setup_weights(Weights *w, const ModelConfig *cfg) {
    uint64_t dim = (uint64_t)cfg->dim;
    uint64_t hidden = (uint64_t)cfg->hidden_dim;
    uint64_t layers = (uint64_t)cfg->n_layers;
    uint64_t heads = (uint64_t)cfg->n_heads;
    uint64_t kv_heads = (uint64_t)cfg->n_kv_heads;
    uint64_t vocab = (uint64_t)cfg->vocab_size;
    uint64_t seq = (uint64_t)cfg->seq_len;
    uint64_t head_size = dim / heads;

    float *ptr = (float *)ML_WEIGHTS_BASE;

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
 * RunState: activations + KV cache. Static allocation (T032) -- these
 * are NOT C globals, they are pointers computed into the fixed
 * ML_RUNSTATE_BASE region so the program's own linked bss (which the
 * linker caps at 1MB together with .text, see llama2.ld) never has to
 * hold the ~640KB KV cache.
 * =================================================================== */

typedef struct {
    float *x, *xb, *xb2, *hb, *hb2, *q, *k, *v, *att, *logits;
    float *key_cache, *value_cache;
} RunState;

/* Total bytes RunState needs for this model. Kept in lockstep with
 * setup_runstate() below -- same fields, same order. */
static uint64_t runstate_bytes(const ModelConfig *cfg) {
    uint64_t dim = (uint64_t)cfg->dim;
    uint64_t hidden = (uint64_t)cfg->hidden_dim;
    uint64_t heads = (uint64_t)cfg->n_heads;
    uint64_t kv_dim = (dim * (uint64_t)cfg->n_kv_heads) / (uint64_t)cfg->n_heads;
    uint64_t seq = (uint64_t)cfg->seq_len;
    uint64_t layers = (uint64_t)cfg->n_layers;
    uint64_t vocab = (uint64_t)cfg->vocab_size;

    uint64_t floats = 0;
    floats += dim;               /* x */
    floats += dim;               /* xb */
    floats += dim;               /* xb2 */
    floats += hidden;            /* hb */
    floats += hidden;            /* hb2 */
    floats += dim;               /* q */
    floats += heads * seq;       /* att */
    floats += vocab;             /* logits */
    floats += 2ull * layers * seq * kv_dim; /* key_cache + value_cache */
    return floats * 4u;
}

static void setup_runstate(RunState *s, const ModelConfig *cfg) {
    uint64_t dim = (uint64_t)cfg->dim;
    uint64_t hidden = (uint64_t)cfg->hidden_dim;
    uint64_t heads = (uint64_t)cfg->n_heads;
    uint64_t kv_dim = (dim * (uint64_t)cfg->n_kv_heads) / (uint64_t)cfg->n_heads;
    uint64_t seq = (uint64_t)cfg->seq_len;
    uint64_t layers = (uint64_t)cfg->n_layers;
    uint64_t vocab = (uint64_t)cfg->vocab_size;

    uint8_t *base = (uint8_t *)ML_RUNSTATE_BASE;
    uint64_t off = 0;

    s->x   = (float *)(base + off); off += dim * 4;
    s->xb  = (float *)(base + off); off += dim * 4;
    s->xb2 = (float *)(base + off); off += dim * 4;
    s->hb  = (float *)(base + off); off += hidden * 4;
    s->hb2 = (float *)(base + off); off += hidden * 4;
    s->q   = (float *)(base + off); off += dim * 4;
    s->att = (float *)(base + off); off += heads * seq * 4;
    s->logits = (float *)(base + off); off += vocab * 4;
    s->key_cache   = (float *)(base + off); off += layers * seq * kv_dim * 4;
    s->value_cache = (float *)(base + off); off += layers * seq * kv_dim * 4;
    s->k = s->key_cache;   /* re-pointed per (layer,pos) inside forward() */
    s->v = s->value_cache;
}

/* ===================================================================
 * Neural net blocks. Straight port of run.c's rmsnorm/softmax/matmul,
 * instrumented per T043. profile.h requires categories to be mutually
 * exclusive (see its top comment), so matmul/attention/rmsnorm/rope
 * regions below never nest: e.g. the q/k/v matmuls are timed as
 * PROF_MATMUL and END before the PROF_ATTENTION region (dot products
 * over the KV cache) begins.
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

/* W (d,n) @ x (n,) -> xout (d,). By far the most amount of time is
 * spent inside this function -- the reason it is its own PROF_MATMUL
 * category. */
static void matmul(float *xout, const float *x, const float *w, int n, int d) {
    for (int i = 0; i < d; i++) {
        float val = 0.0f;
        const float *wi = w + (uint32_t)i * n;
        for (int j = 0; j < n; j++) val += wi[j] * x[j];
        xout[i] = val;
    }
}

/* Table-based RoPE (legacy format): freq_cis_real/imag are indexed by
 * [pos][head_dim/2] and shared across every head at a given position,
 * regardless of n_heads vs n_kv_heads (GQA doesn't change the rotation,
 * only which K/V head a query head reads back during attention). */
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

        prof_begin(PROF_RMSNORM);
        rmsnorm(s->xb, x, w->rms_att_weight + (uint32_t)l * dim, dim);
        prof_end(PROF_RMSNORM);

        uint32_t loff = (uint32_t)l * cfg->seq_len * kv_dim;
        s->k = s->key_cache + loff + (uint32_t)pos * kv_dim;
        s->v = s->value_cache + loff + (uint32_t)pos * kv_dim;

        prof_begin(PROF_MATMUL);
        matmul(s->q, s->xb, w->wq + (uint32_t)l * dim * dim, dim, dim);
        matmul(s->k, s->xb, w->wk + (uint32_t)l * dim * kv_dim, dim, kv_dim);
        matmul(s->v, s->xb, w->wv + (uint32_t)l * dim * kv_dim, dim, kv_dim);
        prof_end(PROF_MATMUL);

        prof_begin(PROF_ROPE);
        rope_rotate(s, w, cfg, pos, head_size);
        prof_end(PROF_ROPE);

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

        prof_begin(PROF_MATMUL);
        matmul(s->xb2, s->xb, w->wo + (uint32_t)l * dim * dim, dim, dim);
        prof_end(PROF_MATMUL);

        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        prof_begin(PROF_RMSNORM);
        rmsnorm(s->xb, x, w->rms_ffn_weight + (uint32_t)l * dim, dim);
        prof_end(PROF_RMSNORM);

        prof_begin(PROF_MATMUL);
        matmul(s->hb,  s->xb, w->w1 + (uint32_t)l * dim * hidden_dim, dim, hidden_dim);
        matmul(s->hb2, s->xb, w->w3 + (uint32_t)l * dim * hidden_dim, dim, hidden_dim);
        prof_end(PROF_MATMUL);

        /* SwiGLU: silu(w1(x)) * w3(x). Elementwise, cheap -- left as
         * "other" residual per profile.h's coverage design. */
        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= (1.0f / (1.0f + expf(-val)));
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        prof_begin(PROF_MATMUL);
        matmul(s->xb, s->hb, w->w2 + (uint32_t)l * dim * hidden_dim, hidden_dim, dim);
        prof_end(PROF_MATMUL);

        for (int i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    prof_begin(PROF_RMSNORM);
    rmsnorm(x, x, w->rms_final_weight, dim);
    prof_end(PROF_RMSNORM);

    prof_begin(PROF_MATMUL);
    matmul(s->logits, x, w->wcls, dim, cfg->vocab_size);
    prof_end(PROF_MATMUL);

    return s->logits;
}

/* ===================================================================
 * Tokenizer: parsed directly out of the raw bytes ml_load_tokenizer()
 * already placed at ML_TOKENIZER_BASE. No malloc, no null-terminated
 * strings -- every vocab entry is kept as {pointer, length} straight
 * into that SDRAM region, and all comparisons are length-aware so
 * nothing needs a copy just to compare or print.
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

/* strcmp-equivalent total order over (ptr,len) pairs with no null
 * terminators: shorter-is-a-prefix sorts first, exactly like strcmp
 * would once it hit the shorter string's '\0'. */
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

/* Returns 0 on success, -1 if the real tokenizer exceeds the static
 * bounds above (MAX_VOCAB / MAX_TOKEN_LEN). */
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

    /* Insertion sort by content: vocab_size <= MAX_VOCAB (600), so the
     * worst-case O(n^2) here is well under a million short compares --
     * negligible next to a multi-minute generation run, and it avoids
     * pulling in qsort's function-pointer indirection for a one-time
     * startup cost. */
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

/* BPE-encode text into tokens[]. tokens[] must hold at least
 * MAX_PROMPT_TOKENS entries. bos/eos add the BOS(=1)/EOS(=2) markers. */
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
        if ((*c & 0xC0) != 0x80) str_len = 0;    /* not a UTF-8 continuation byte */
        str_buffer[str_len++] = *c;
        if (((*(c + 1)) & 0xC0) == 0x80 && str_len < 4) continue;

        int id = str_lookup(str_buffer, str_len);
        if (id != -1) {
            tokens[n_tokens++] = id;
        } else {
            /* byte_fallback: individual bytes start at vocab index 3 */
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
            if (l1 + l2 > STRBUF_LEN - 1) continue; /* can't happen for MAX_TOKEN_LEN-bounded vocab */
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

/* decode(): resolves token -> printable piece, following run.c's
 * conventions: strip a leading space right after BOS, and turn raw
 * byte-fallback tokens ("<0x1B>") back into the single byte they
 * represent. *out_ptr/*out_len describe the bytes to print (NOT
 * null-terminated -- see safe_print_piece). */
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
 * Sampler: xorshift64 RNG + argmax/multinomial/top-p, matching run.c
 * bit-for-bit so the same seed reproduces the same sequence.
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
 * main(): banner -> mount -> load model+tokenizer -> set up weight/
 * RunState pointers -> generate, streaming each token as produced ->
 * print achieved rate -> optional profile report.
 * =================================================================== */

int main(void) {
    printf("\r\n");
    printf("llama2.c on FemtoRV (RV32IMFC / petitbateau)\r\n");

    prof_enable(MEASURE_MODE);
    prof_reset();

    ml_status_t st = ml_mount();
    if (st != ML_OK) {
        printf("SD mount failed: %s\r\n", ml_strerror(st));
        return 1;
    }

    ModelConfig cfg;
    ml_report_t rep;

    st = ml_load_model("/model.bin", &cfg, &rep);
    if (st != ML_OK) {
        printf("model load failed: %s\r\n", ml_strerror(st));
        return 1;
    }
    ml_print_report("model", &rep);

    st = ml_load_tokenizer("/tokenizer.bin", &cfg, &rep);
    if (st != ML_OK) {
        printf("tokenizer load failed: %s\r\n", ml_strerror(st));
        return 1;
    }
    ml_print_report("tokenizer", &rep);

    printf("dim=%d hidden=%d layers=%d heads=%d kv_heads=%d vocab=%d seq_len=%d\r\n",
           cfg.dim, cfg.hidden_dim, cfg.n_layers, cfg.n_heads,
           cfg.n_kv_heads, cfg.vocab_size, cfg.seq_len);

    if (build_tokenizer((uint32_t)cfg.vocab_size) != 0) {
        printf("REFUSING: tokenizer vocab_size=%d or max_token_length exceeds this build's "
               "static limits (MAX_VOCAB=%d, MAX_TOKEN_LEN=%d)\r\n",
               cfg.vocab_size, MAX_VOCAB, MAX_TOKEN_LEN);
        return 1;
    }

    /* T032: verify the RunState (activations + KV cache) fits the fixed
     * 960KB budget BEFORE touching any of it. */
    uint64_t need = runstate_bytes(&cfg);
    printf("RunState needs %d bytes (limit %d bytes)\r\n",
           (int)need, (int)ML_RUNSTATE_LIMIT);
    if (need > ML_RUNSTATE_LIMIT) {
        printf("REFUSING: activations + KV cache do not fit in the %d byte budget "
               "at 0x%x -- reduce seq_len or layers\r\n",
               (int)ML_RUNSTATE_LIMIT, ML_RUNSTATE_BASE);
        return 1;
    }

    Weights w;
    setup_weights(&w, &cfg);
    RunState s;
    setup_runstate(&s, &cfg);

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
        float *logits = forward(&cfg, &w, &s, token, pos);

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
        safe_print_piece(piece, plen);   /* emitted AS IT IS PRODUCED (T034) */

        token = next;
        if (t_start == 0) t_start = cycles(); /* skip first (slower, cold-cache) iteration */
    }
    printf("\r\n");

    uint64_t t_end = cycles();
    if (pos > 1 && t_start != 0) {
        uint64_t elapsed = t_end - t_start;
        if (elapsed == 0) elapsed = 1;
        uint64_t rate_x100 = ((uint64_t)(pos - 1) * 100ull * CPU_HZ) / elapsed;
        /* Report elapsed in tenths of a second, NOT raw cycles: a 90 s run at
         * 25 MHz is 2.27e9 cycles, which overflows the signed 32-bit int that
         * printf's %d takes and printed as a negative number. */
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
