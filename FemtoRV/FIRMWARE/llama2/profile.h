/*
 * profile.h -- per-category cycle accounting for llama2 inference.
 * Categories must be mutually exclusive; "other" is a computed residual
 * so the >=90% coverage claim (FR-020) is proven, not estimated.
 */
#ifndef PROFILE_H
#define PROFILE_H

#include <stdint.h>

typedef enum {
    PROF_MATMUL = 0,
    PROF_ATTENTION,
    PROF_RMSNORM,
    PROF_ROPE,
    PROF_SAMPLE,
    PROF_ATT_SCORE, /* attention sub-timers (feature 004 R48): score dots,   */
    PROF_ATT_SOFT,  /* softmax, and the weighted sum. PROF_ATTENTION still   */
    PROF_ATT_SUM,   /* wraps all three, so the totals stay comparable.       */
    PROF_QUANT,     /* activation quantization (runq.c only, feature 004 R2) --
                     * new scalar work the int8 path adds before every matmul;
                     * unused (always 0) by the fp32 llama2.c binary. */
    PROF_NCAT
} prof_cat_t;

void     prof_reset(void);
void     prof_enable(int on);      /* measurement mode flag (T043) */
int      prof_enabled(void);
void     prof_begin(prof_cat_t c);
void     prof_end(prof_cat_t c);
void     prof_run_begin(void);     /* marks start of the whole run   */
void     prof_run_end(uint32_t tokens_generated);
void     prof_report(void);        /* prints the report (entity 7)   */
uint64_t prof_total_cycles(void);

#endif
