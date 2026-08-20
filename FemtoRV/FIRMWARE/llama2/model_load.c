/*
 * model_load.c -- load a llama2.c model + tokenizer from SD card into
 * SDRAM. See model_load.h for the memory layout and the API this file
 * implements exactly.
 *
 * SD/FAT access follows the pattern used in examples/sd_dir.c: raw sector
 * I/O via sd_init()/sd_readsector()/sd_writesector(), FAT access via the
 * fat_io_lib fl_* calls. This is a standalone program (no GPU, no
 * RetroKernel) so output goes only through printf()/putchar()/puts().
 *
 * Weight layout confirmed against the real tools/model.bin (dim=64,
 * hidden_dim=172, n_layers=5, n_heads=8, n_kv_heads=4, vocab_size=512,
 * seq_len=512): the format INCLUDES the freq_cis_real/freq_cis_imag
 * tables between rms_final and (optional) classifier. With those tables:
 *   264128 floats * 4 bytes = 1,056,512 bytes  (matches file_size - 28
 *   header bytes = 1,056,540 - 28 = 1,056,512 exactly).
 * Without the freq_cis tables the total is only 260032 floats = 1,040,128
 * bytes, which does NOT match. So this loader's weight_bytes() below
 * counts freq_cis_real/freq_cis_imag as part of the weight region.
 */

#include <femtorv32.h>
#include "model_load.h"

/* SD card raw sector I/O (see examples/sd_dir.c). */
extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);
extern int sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

/* fat_io_lib file API (see examples/sd_dir.c). */
typedef int (*fn_diskio_read)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
typedef int (*fn_diskio_write)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
extern void fl_init(void);
extern int  fl_attach_media(fn_diskio_read rd, fn_diskio_write wr);
extern void *fl_fopen(const char *path, const char *mode);
extern int  fl_fread(void *buffer, int size, int count, void *file);
extern void fl_fclose(void *file);
extern int  fl_fseek(void *file, long offset, int origin);
extern long fl_ftell(void *file);

#define FAT_INIT_OK 0

#ifndef SEEK_SET
#define SEEK_SET 0
#endif
#ifndef SEEK_END
#define SEEK_END 2
#endif

#define CPU_HZ            25000000u
#define HEADER_BYTES      28u        /* 7 * int32 */
#define LOAD_CHUNK_BYTES  8192u      /* streamed to SDRAM this many bytes at a time */

static int g_mounted = 0;

/* ---------------------------------------------------------------- errors */

const char *ml_strerror(ml_status_t s) {
    switch (s) {
    case ML_OK:                 return "ok";
    case ML_ERR_NO_CARD:        return "SD card absent or initialization failed";
    case ML_ERR_NO_FS:          return "SD card filesystem unreadable (not FAT16/32?)";
    case ML_ERR_NO_FILE:        return "file not found on SD card";
    case ML_ERR_TRUNCATED:      return "file is shorter than its header implies";
    case ML_ERR_BAD_HEADER:     return "model header fields are out of sane range";
    case ML_ERR_TOO_BIG:        return "model would overflow its memory region";
    case ML_ERR_READ:           return "read failed part-way through the file (card removed?)";
    case ML_ERR_VOCAB_MISMATCH: return "tokenizer token count does not match model vocab_size";
    case ML_ERR_WRONG_FORMAT:   return "file format does not match what this loader expects (Q8_0 vs legacy fp32)";
    default:                    return "unknown error";
    }
}

/* ---------------------------------------------------------------- mount */

ml_status_t ml_mount(void) {
    if (g_mounted)
        return ML_OK;
    if (sd_init())
        return ML_ERR_NO_CARD;
    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector, (fn_diskio_write)sd_writesector) != FAT_INIT_OK)
        return ML_ERR_NO_FS;
    g_mounted = 1;
    return ML_OK;
}

/* ---------------------------------------------------------------- helpers */

static int32_t le_i32(const uint8_t *p) {
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                      ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

static int in_range(int32_t v, int32_t lo, int32_t hi) {
    return v >= lo && v <= hi;
}

/* Fills bytes/elapsed_ms/kb_per_sec_x10 from a cycle count. Throughput is
 * computed straight from cycles (bytes*10*CPU_HZ / (cycles*1024)) rather
 * than routing through elapsed_ms, so a sub-millisecond transfer still
 * yields a sane (if imprecise) rate instead of a divide-by-zero. */
static void fill_report(ml_report_t *rep, uint32_t bytes, uint64_t elapsed_cycles) {
    if (!rep)
        return;
    uint64_t dc = elapsed_cycles ? elapsed_cycles : 1;
    rep->bytes = bytes;
    rep->elapsed_ms = (uint32_t)((dc * 1000u) / CPU_HZ);
    rep->kb_per_sec_x10 = (uint32_t)(((uint64_t)bytes * 10ull * CPU_HZ) / (dc * 1024ull));
}

/* Size in bytes of the weight region described by cfg, NOT counting the
 * 28-byte header. See file header comment: includes freq_cis_real/imag,
 * and includes a trailing classifier[vocab*dim] only when unshared. */
static uint32_t weight_bytes(const ModelConfig *cfg) {
    uint32_t dim       = (uint32_t)cfg->dim;
    uint32_t hidden    = (uint32_t)cfg->hidden_dim;
    uint32_t layers    = (uint32_t)cfg->n_layers;
    uint32_t heads     = (uint32_t)cfg->n_heads;
    uint32_t kv_heads  = (uint32_t)cfg->n_kv_heads;
    uint32_t vocab     = (uint32_t)cfg->vocab_size;
    uint32_t seq       = (uint32_t)cfg->seq_len;
    uint32_t head_size = dim / heads;

    uint32_t floats = 0;
    floats += vocab * dim;                          /* token_embedding_table */
    floats += layers * dim;                          /* rms_att_weight */
    floats += layers * dim * (heads * head_size);     /* wq */
    floats += layers * dim * (kv_heads * head_size);  /* wk */
    floats += layers * dim * (kv_heads * head_size);  /* wv */
    floats += layers * (heads * head_size) * dim;     /* wo */
    floats += layers * dim;                           /* rms_ffn_weight */
    floats += layers * hidden * dim;                  /* w1 */
    floats += layers * dim * hidden;                  /* w2 */
    floats += layers * hidden * dim;                  /* w3 */
    floats += dim;                                     /* rms_final_weight */
    floats += seq * (head_size / 2);                   /* freq_cis_real */
    floats += seq * (head_size / 2);                   /* freq_cis_imag */
    if (!cfg->shared_weights)
        floats += vocab * dim;                         /* classifier (unshared only) */

    return floats * 4u;
}

/* Streams `total` bytes from the (already positioned) open file to `dst`
 * in LOAD_CHUNK_BYTES pieces. Returns ML_OK or ML_ERR_READ. */
static ml_status_t stream_to(void *file, uint8_t *dst, uint32_t total) {
    uint32_t remaining = total;
    while (remaining > 0) {
        uint32_t chunk = remaining < LOAD_CHUNK_BYTES ? remaining : LOAD_CHUNK_BYTES;
        int got = fl_fread(dst, 1, (int)chunk, file);
        if (got != (int)chunk)
            return ML_ERR_READ;
        dst += chunk;
        remaining -= chunk;
    }
    return ML_OK;
}

/* ---------------------------------------------------------------- model */

ml_status_t ml_load_model(const char *path, ModelConfig *cfg, ml_report_t *rep) {
    ml_status_t st = ml_mount();
    if (st != ML_OK)
        return st;

    void *f = fl_fopen(path, "r");
    if (!f)
        return ML_ERR_NO_FILE;

    uint8_t hdr[HEADER_BYTES];
    if (fl_fread(hdr, 1, (int)HEADER_BYTES, f) != (int)HEADER_BYTES) {
        fl_fclose(f);
        return ML_ERR_TRUNCATED;
    }

    /* research R4: a Q8_0 file's first 4 bytes are its magic, which would
     * otherwise be silently misread as this format's `dim` field (0x3432
     * of it, anyway) and likely fail in_range() below in a confusing way,
     * or -- worse -- occasionally pass it by chance. Reject loudly and
     * specifically instead. */
    if ((uint32_t)le_i32(hdr + 0) == Q8_0_MAGIC) {
        fl_fclose(f);
        return ML_ERR_WRONG_FORMAT;
    }

    int32_t dim       = le_i32(hdr + 0);
    int32_t hidden    = le_i32(hdr + 4);
    int32_t n_layers  = le_i32(hdr + 8);
    int32_t n_heads   = le_i32(hdr + 12);
    int32_t n_kv_heads= le_i32(hdr + 16);
    int32_t vocab_raw = le_i32(hdr + 20);
    int32_t seq_len   = le_i32(hdr + 24);

    if (!in_range(dim, 1, 4096) ||
        !in_range(hidden, 1, 65536) ||
        !in_range(n_layers, 1, 64) ||
        !in_range(n_heads, 1, 1024) ||
        !in_range(n_kv_heads, 1, 1024) ||
        !in_range(vocab_raw, -65536, 65536) || vocab_raw == 0 ||
        !in_range(seq_len, 1, 8192) ||
        (dim % n_heads) != 0) {
        fl_fclose(f);
        return ML_ERR_BAD_HEADER;
    }

    ModelConfig c;
    c.dim            = dim;
    c.hidden_dim      = hidden;
    c.n_layers        = n_layers;
    c.n_heads         = n_heads;
    c.n_kv_heads      = n_kv_heads;
    c.shared_weights  = (vocab_raw > 0) ? 1 : 0;
    c.vocab_size      = (vocab_raw < 0) ? -vocab_raw : vocab_raw;
    c.seq_len         = seq_len;

    uint32_t wbytes = weight_bytes(&c);

    /* Refuse BEFORE loading anything if it can't fit. */
    if (wbytes > ML_WEIGHTS_LIMIT) {
        fl_fclose(f);
        return ML_ERR_TOO_BIG;
    }

    /* Verify the file is exactly as long as the header implies. */
    if (fl_fseek(f, 0, SEEK_END) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }
    long file_len = fl_ftell(f);
    if (file_len < 0 || (uint32_t)file_len != HEADER_BYTES + wbytes) {
        fl_fclose(f);
        return ML_ERR_TRUNCATED;
    }
    if (fl_fseek(f, (long)HEADER_BYTES, SEEK_SET) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }

    uint64_t t0 = cycles();
    st = stream_to(f, (uint8_t *)ML_WEIGHTS_BASE, wbytes);
    uint64_t t1 = cycles();

    fl_fclose(f);
    if (st != ML_OK)
        return st;

    *cfg = c;
    fill_report(rep, wbytes, t1 - t0);
    return ML_OK;
}

/* -------------------------------------------------------------- Q8_0 model */

static int is_pow2(int32_t v) {
    return v > 0 && (v & (v - 1)) == 0;
}

ml_status_t ml_load_model_q8(const char *path, Q8Config *cfg,
                              uint8_t *shared_classifier, int32_t *group_size,
                              ml_report_t *rep) {
    ml_status_t st = ml_mount();
    if (st != ML_OK)
        return st;

    void *f = fl_fopen(path, "r");
    if (!f)
        return ML_ERR_NO_FILE;

    Q8Header hdr;
    if (fl_fread(&hdr, 1, (int)sizeof(hdr), f) != (int)sizeof(hdr)) {
        fl_fclose(f);
        return ML_ERR_TRUNCATED;
    }

    /* research R4: the other half of the format guard -- a legacy fp32
     * file has no magic at all, so this MUST be checked before trusting
     * anything else in the header (a legacy header's first bytes are its
     * `dim` field, essentially arbitrary w.r.t. Q8_0_MAGIC). */
    if (hdr.magic != Q8_0_MAGIC) {
        fl_fclose(f);
        return ML_ERR_WRONG_FORMAT;
    }
    if (hdr.version != Q8_0_VERSION) {
        fl_fclose(f);
        return ML_ERR_BAD_HEADER;
    }

    Q8Config c = hdr.config;
    int32_t gs = hdr.group_size;

    if (!in_range(c.dim, 1, 4096) ||
        !in_range(c.hidden_dim, 1, 65536) ||
        !in_range(c.n_layers, 1, 64) ||
        !in_range(c.n_heads, 1, 1024) ||
        !in_range(c.n_kv_heads, 1, 1024) ||
        !in_range(c.vocab_size, 1, 65536) ||
        !in_range(c.seq_len, 1, 8192) ||
        (c.dim % c.n_heads) != 0 ||
        !is_pow2(gs) ||
        (c.dim % gs) != 0 || (c.hidden_dim % gs) != 0) {
        /* FR-009 (data-model entity 4): every tensor's element count MUST
         * be an exact multiple of GS, and GS itself MUST be a supported
         * power of two -- reject explicitly here rather than let quantize()
         * or matmul_q8() silently compute a partial/garbage last group. */
        fl_fclose(f);
        return ML_ERR_BAD_HEADER;
    }

    uint8_t sc = hdr.shared_classifier ? 1 : 0;
    uint32_t total_bytes = q8_checkpoint_bytes(&c, gs, sc);  /* includes the 256-byte header */
    uint32_t tensor_bytes = total_bytes - Q8_0_HEADER_BYTES;

    /* Refuse BEFORE loading anything if it can't fit -- SAME region/limit
     * as the legacy loader (see model_load.h's file-header note on why). */
    if (tensor_bytes > ML_WEIGHTS_LIMIT) {
        fl_fclose(f);
        return ML_ERR_TOO_BIG;
    }

    /* Verify the file is exactly as long as the header implies. */
    if (fl_fseek(f, 0, SEEK_END) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }
    long file_len = fl_ftell(f);
    if (file_len < 0 || (uint32_t)file_len != total_bytes) {
        fl_fclose(f);
        return ML_ERR_TRUNCATED;
    }
    if (fl_fseek(f, (long)Q8_0_HEADER_BYTES, SEEK_SET) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }

    uint64_t t0 = cycles();
    st = stream_to(f, (uint8_t *)ML_WEIGHTS_BASE, tensor_bytes);
    uint64_t t1 = cycles();

    fl_fclose(f);
    if (st != ML_OK)
        return st;

    *cfg = c;
    *shared_classifier = sc;
    *group_size = gs;
    fill_report(rep, tensor_bytes, t1 - t0);
    return ML_OK;
}

/* ------------------------------------------------------------ tokenizer */

/* Shared implementation: both formats' tokenizer file is identical (the
 * tokenizer is fp32 vocab/scores, unaffected by weight quantization), so
 * only the expected vocab_size differs by caller. */
static ml_status_t load_tokenizer_impl(const char *path, uint32_t vocab_size, ml_report_t *rep) {
    ml_status_t st = ml_mount();
    if (st != ML_OK)
        return st;

    void *f = fl_fopen(path, "r");
    if (!f)
        return ML_ERR_NO_FILE;

    if (fl_fseek(f, 0, SEEK_END) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }
    long file_len = fl_ftell(f);
    if (file_len < 4) {   /* must at least hold max_token_length */
        fl_fclose(f);
        return ML_ERR_TRUNCATED;
    }
    if ((uint32_t)file_len > ML_TOKENIZER_LIMIT) {
        fl_fclose(f);
        return ML_ERR_TOO_BIG;
    }
    if (fl_fseek(f, 0, SEEK_SET) != 0) {
        fl_fclose(f);
        return ML_ERR_READ;
    }

    uint64_t t0 = cycles();
    st = stream_to(f, (uint8_t *)ML_TOKENIZER_BASE, (uint32_t)file_len);
    uint64_t t1 = cycles();
    fl_fclose(f);
    if (st != ML_OK)
        return st;

    /* Walk the copy in SDRAM: int32 max_token_length, then per token
     * { float32 score; int32 len; char bytes[len] }. This is the single
     * most important check in the program -- a mismatched model/tokenizer
     * pair would otherwise produce fluent but WRONG text. */
    const uint8_t *p = (const uint8_t *)ML_TOKENIZER_BASE;
    uint32_t total = (uint32_t)file_len;
    uint32_t off = 4;
    uint32_t count = 0;

    while (off < total) {
        if (off + 8 > total)
            return ML_ERR_TRUNCATED;   /* score+len header doesn't fit */
        int32_t len = le_i32(p + off + 4);
        if (len < 0 || off + 8 + (uint32_t)len > total)
            return ML_ERR_TRUNCATED;
        off += 8 + (uint32_t)len;
        count++;
    }

    if (count != vocab_size)
        return ML_ERR_VOCAB_MISMATCH;

    fill_report(rep, total, t1 - t0);
    return ML_OK;
}

ml_status_t ml_load_tokenizer(const char *path, const ModelConfig *cfg, ml_report_t *rep) {
    return load_tokenizer_impl(path, (uint32_t)cfg->vocab_size, rep);
}

ml_status_t ml_load_tokenizer_q8(const char *path, const Q8Config *cfg, ml_report_t *rep) {
    return load_tokenizer_impl(path, (uint32_t)cfg->vocab_size, rep);
}

/* ---------------------------------------------------------------- report */

void ml_print_report(const char *what, const ml_report_t *rep) {
    if (!rep)
        return;
    printf("%s: %d bytes in %d ms (%d.%d KB/s)\r\n",
           what,
           (int)rep->bytes,
           (int)rep->elapsed_ms,
           (int)(rep->kb_per_sec_x10 / 10),
           (int)(rep->kb_per_sec_x10 % 10));
}
