/*
 * model_load.h -- load a llama2.c model + tokenizer from SD card into SDRAM.
 *
 * Memory layout (see specs/003-llama2-minimal-soc/data-model.md entity 2):
 *   0x800000  program image        (1 MB)
 *   0x900000  model weights        (1 MB)
 *   0xA00000  tokenizer            (64 KB)
 *   0xA10000  activations/KV cache (~960 KB)
 *   0xF00000  stack (grows down)
 */
#ifndef MODEL_LOAD_H
#define MODEL_LOAD_H

#include <stdint.h>

#define ML_WEIGHTS_BASE   0x900000u
#define ML_WEIGHTS_LIMIT  0x100000u   /* 1 MB */
#define ML_TOKENIZER_BASE 0xA00000u
#define ML_TOKENIZER_LIMIT 0x10000u   /* 64 KB */
#define ML_RUNSTATE_BASE  0xA10000u
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
    ML_ERR_VOCAB_MISMATCH  /* tokenizer count != model vocab_size    */
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

/* Load weights to ML_WEIGHTS_BASE. Fills cfg and rep (rep may be NULL). */
ml_status_t ml_load_model(const char *path, ModelConfig *cfg, ml_report_t *rep);

/* Load tokenizer to ML_TOKENIZER_BASE. Verifies token count == cfg->vocab_size
 * and returns ML_ERR_VOCAB_MISMATCH otherwise -- this catches a mismatched
 * model/tokenizer pair, which otherwise yields fluent but WRONG text. */
ml_status_t ml_load_tokenizer(const char *path, const ModelConfig *cfg,
                              ml_report_t *rep);

/* Print a human-readable load report to serial. */
void ml_print_report(const char *what, const ml_report_t *rep);

#endif
