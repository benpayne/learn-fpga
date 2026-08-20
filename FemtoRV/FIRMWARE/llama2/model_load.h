/*
 * model_load.h -- load a llama2.c model + tokenizer from SD card into SDRAM.
 *
 * Memory layout (see specs/003-llama2-minimal-soc/data-model.md entity 2):
 *   0x800000  program image        (1 MB)
 *   0x900000  model weights        (2 MB)
 *   0xB00000  tokenizer            (64 KB)
 *   0xB10000  activations/KV cache (~960 KB)
 *   0xC00000  free                 (3 MB)
 *   0xF00000  stack (grows down)
 *
 * NOTE on the weights region: stories260K's weights are 1,056,512 bytes --
 * just OVER 1 MB, because the legacy export format carries the precomputed
 * freq_cis tables. A 1 MB region was tried first and the FR-008 bounds
 * check correctly refused to load rather than overrunning the tokenizer.
 * 2 MB leaves headroom for a larger model without another map change.
 *
 * *** Feature 004 (int8 MatMul accel) update ***
 * The Q8_0 checkpoint (tools/model.q8.bin) is only 299,008 bytes -- 26.6%
 * of the legacy fp32 file's 1,056,540 bytes, per q8_format.h's sizing
 * (default GS=64). It is loaded into the SAME ML_WEIGHTS_BASE region with
 * the SAME ML_WEIGHTS_LIMIT (2 MB); the region was deliberately NOT shrunk
 * to fit the smaller file, because it is the REGION SIZE that bounds how
 * big a model this firmware can load, not the amount of SDRAM available
 * (research R5) -- shrinking it would only make a future larger model fail
 * sooner, for no memory actually reclaimed (the next region, the tokenizer,
 * starts at a fixed address regardless). ml_load_model_q8() (below) is the
 * loader for this format; it streams ONLY the tensor data (i.e. bytes
 * AFTER the 256-byte header) to ML_WEIGHTS_BASE, exactly as the legacy
 * loader already streams only the bytes after ITS 28-byte header -- so
 * pointer arithmetic against ML_WEIGHTS_BASE never needs a header-size
 * offset on this target, matching runq_host.c's read_checkpoint().
 *
 * *** hidden_dim WARNING ***
 * model.q8.bin has hidden_dim=192 (NOT 172, the legacy stories260K value).
 * Every RunState buffer sized off hidden_dim (hb, hb2, the w1/w2/w3 matmul
 * shapes, hq in runq.c) MUST read hidden_dim from the loaded Q8Config, the
 * same way dim/n_layers/etc. already are -- never hardcode 172 or assume
 * the two model files share dimensions. Getting this wrong does not fail
 * loudly: it silently misaligns every buffer after the first mis-sized
 * one, producing corrupted-but-plausible-looking activations rather than
 * a crash (research R5 / this file's recurring failure mode).
 */
#ifndef MODEL_LOAD_H
#define MODEL_LOAD_H

#include <stdint.h>
#include "q8_format.h"

#define ML_WEIGHTS_BASE   0x900000u
#define ML_WEIGHTS_LIMIT  0x200000u   /* 2 MB -- see note above */
#define ML_TOKENIZER_BASE 0xB00000u
#define ML_TOKENIZER_LIMIT 0x10000u   /* 64 KB */
#define ML_RUNSTATE_BASE  0xB10000u
#define ML_RUNSTATE_LIMIT 0xF0000u    /* 960 KB */

/* Model header: 7 little-endian int32 at the start of model.bin.
 * A NEGATIVE vocab_size signals unshared classifier weights; the loader
 * stores the absolute value here and sets shared_weights accordingly. */
typedef struct {
    int32_t dim;
    int32_t hidden_dim;
    int32_t n_layers;
    int32_t n_heads;
    int32_t n_kv_heads;
    int32_t vocab_size;    /* always positive after load */
    int32_t seq_len;
    int     shared_weights;/* 1 if classifier shares the embedding table */
} ModelConfig;

/* Error codes. Each maps to a distinct operator-visible failure (FR-012). */
typedef enum {
    ML_OK = 0,
    ML_ERR_NO_CARD,        /* SD card absent or init failed          */
    ML_ERR_NO_FS,          /* card present but filesystem unreadable */
    ML_ERR_NO_FILE,        /* file not found on the card             */
    ML_ERR_TRUNCATED,      /* file shorter than its header implies   */
    ML_ERR_BAD_HEADER,     /* header fields out of sane bounds       */
    ML_ERR_TOO_BIG,        /* would overflow its memory region       */
    ML_ERR_READ,           /* read failed part-way (card removed?)   */
    ML_ERR_VOCAB_MISMATCH, /* tokenizer count != model vocab_size    */
    ML_ERR_WRONG_FORMAT    /* Q8_0 magic present/absent where the caller
                             * required the opposite (research R4) -- the
                             * silent-wrong-output failure mode this loader
                             * exists to prevent. Loud and distinct from
                             * ML_ERR_BAD_HEADER on purpose: a wrong format
                             * is a caller/file mismatch, not a corrupt file. */
} ml_status_t;

const char *ml_strerror(ml_status_t s);

/* Load report (FR-012a, data-model entity 8). */
typedef struct {
    uint32_t bytes;
    uint32_t elapsed_ms;
    uint32_t kb_per_sec_x10;   /* KB/s * 10 -- printf has no %f */
} ml_report_t;

/* Mount the card. Must be called once before the loaders. */
ml_status_t ml_mount(void);

/* Load weights to ML_WEIGHTS_BASE. Fills cfg and rep (rep may be NULL).
 * Legacy fp32 format (28-byte header, no magic). REJECTS a Q8_0 file
 * (detected by its magic occupying this format's first 4 header bytes)
 * with ML_ERR_WRONG_FORMAT rather than misinterpreting the magic as
 * garbage config fields (research R4). */
ml_status_t ml_load_model(const char *path, ModelConfig *cfg, ml_report_t *rep);

/* Load a Q8_0 quantized checkpoint (q8_format.h) to ML_WEIGHTS_BASE, SAME
 * region/limit as the legacy loader above (see the file-header note on
 * why the region isn't shrunk). Streams only the tensor data -- the bytes
 * AFTER the 256-byte header -- so pointer arithmetic on the target never
 * needs a header offset (matches runq_host.c's read_checkpoint()).
 *
 * REQUIRES the file to start with Q8_0_MAGIC; returns ML_ERR_WRONG_FORMAT
 * immediately (before trusting any other header field) if it does not --
 * this is the autodetect/reject-loudly half of feature 004's format
 * guard, the other half being ml_load_model()'s check above (research R4).
 *
 * Fills *cfg, *shared_classifier, *group_size straight from the header
 * (group_size is a FILE PARAMETER, not a compile-time constant -- research
 * R3 -- so callers MUST read it from here, never assume GS=64). */
ml_status_t ml_load_model_q8(const char *path, Q8Config *cfg,
                              uint8_t *shared_classifier, int32_t *group_size,
                              ml_report_t *rep);

/* Load tokenizer to ML_TOKENIZER_BASE. Verifies token count == cfg->vocab_size
 * and returns ML_ERR_VOCAB_MISMATCH otherwise -- this catches a mismatched
 * model/tokenizer pair, which otherwise yields fluent but WRONG text. */
ml_status_t ml_load_tokenizer(const char *path, const ModelConfig *cfg,
                              ml_report_t *rep);

/* Same as ml_load_tokenizer(), for a Q8Config -- the tokenizer file format
 * itself does not change between feature 003 and 004 (it is always fp32
 * vocab/scores), only which config's vocab_size it is checked against. */
ml_status_t ml_load_tokenizer_q8(const char *path, const Q8Config *cfg,
                                 ml_report_t *rep);

/* Print a human-readable load report to serial. */
void ml_print_report(const char *what, const ml_report_t *rep);

#endif
