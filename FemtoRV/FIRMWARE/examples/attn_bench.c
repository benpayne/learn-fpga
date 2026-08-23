/* attn_bench.c -- decompose attention's cost on this SoC.
 *
 * Attention measures 663M cycles for 3.9M multiply-adds: 170 cycles per MAC
 * (research R46). On a core with hardware fp32, `score += q[i]*k[i]` should
 * be single digits. This program separates the arithmetic from the memory
 * access so the 170 can be attributed rather than guessed at, BEFORE any
 * decision about quantizing the KV cache or building an fp32 datapath.
 *
 * The SDRAM cache is 64 entries x 1 word = 256 BYTES total. A token touches
 * ~141 KB of KV cache, so the hit rate should be ~0 and every access should
 * reach SDRAM. These cases test that directly.
 *
 * Layout replicated from runq.c: key_cache[layer][pos][kv_dim], kv_dim=32
 * floats = 128 B stride, head_size=8 floats = 32 B read per position.
 */

#include <femtorv32.h>
#include <stdint.h>

#define KV_BASE     0xC00000u           /* free SDRAM, above the program */
#define KV_FLOATS   (5u*512u*32u)       /* layers*seq*kv_dim = 81,920 floats */
#define KV_DIM      32u                 /* floats per position */
#define HEAD_SIZE   8u                   /* floats read per position */
#define REPS        8u

static volatile float sink;

int main(void) {
    float *kv = (float *)KV_BASE;
    uint64_t t0, t1;

    printf("\nattn_bench: where do attention's cycles go?\n");
    printf("KV region %u floats (%u KB) at 0x%x, cache is 64 words (256 B)\n\n",
           KV_FLOATS, (KV_FLOATS*4u)/1024u, KV_BASE);

    /* fill, so we are not reading undefined SDRAM */
    for (uint32_t i = 0; i < KV_FLOATS; i++) kv[i] = (float)(int)(i & 255u);

    /* ---- A: pure arithmetic, operands resident (no SDRAM traffic) ---- */
    {
        float q[HEAD_SIZE], k[HEAD_SIZE];
        for (uint32_t i = 0; i < HEAD_SIZE; i++) { q[i] = 1.5f; k[i] = 2.25f; }
        uint32_t n = 0;
        t0 = cycles();
        for (uint32_t r = 0; r < REPS*512u; r++) {
            float s = 0.0f;
            for (uint32_t i = 0; i < HEAD_SIZE; i++) s += q[i] * k[i];
            sink = s; n += HEAD_SIZE;
        }
        t1 = cycles();
        printf("A resident-operand MAC   : %u cycles / %u MAC = %u.%u cyc/MAC\n",
               (uint32_t)(t1-t0), n, (uint32_t)((t1-t0)/n),
               (uint32_t)(((t1-t0)*10u/n) % 10u));
    }

    /* ---- B: contiguous SDRAM read, same MAC ---- */
    {
        float q[HEAD_SIZE];
        for (uint32_t i = 0; i < HEAD_SIZE; i++) q[i] = 1.5f;
        uint32_t n = 0;
        t0 = cycles();
        for (uint32_t off = 0; off + HEAD_SIZE <= KV_FLOATS; off += HEAD_SIZE) {
            const float *k = kv + off;
            float s = 0.0f;
            for (uint32_t i = 0; i < HEAD_SIZE; i++) s += q[i] * k[i];
            sink = s; n += HEAD_SIZE;
        }
        t1 = cycles();
        printf("B contiguous SDRAM MAC   : %u cycles / %u MAC = %u.%u cyc/MAC\n",
               (uint32_t)(t1-t0), n, (uint32_t)((t1-t0)/n),
               (uint32_t)(((t1-t0)*10u/n) % 10u));
    }

    /* ---- C: attention's ACTUAL pattern: 8 contiguous floats, +128 B stride ---- */
    {
        float q[HEAD_SIZE];
        for (uint32_t i = 0; i < HEAD_SIZE; i++) q[i] = 1.5f;
        uint32_t n = 0;
        t0 = cycles();
        for (uint32_t rep = 0; rep < REPS; rep++) {
            for (uint32_t p = 0; p < KV_FLOATS/KV_DIM; p++) {
                const float *k = kv + p*KV_DIM;      /* +128 B each step */
                float s = 0.0f;
                for (uint32_t i = 0; i < HEAD_SIZE; i++) s += q[i] * k[i];
                sink = s; n += HEAD_SIZE;
            }
        }
        t1 = cycles();
        printf("C strided (attention)    : %u cycles / %u MAC = %u.%u cyc/MAC\n",
               (uint32_t)(t1-t0), n, (uint32_t)((t1-t0)/n),
               (uint32_t)(((t1-t0)*10u/n) % 10u));
    }

    /* ---- D: pure strided LOADS, no arithmetic ---- */
    {
        uint32_t n = 0; float acc = 0.0f;
        t0 = cycles();
        for (uint32_t rep = 0; rep < REPS; rep++) {
            for (uint32_t p = 0; p < KV_FLOATS/KV_DIM; p++) {
                const float *k = kv + p*KV_DIM;
                acc += k[0]; acc += k[1]; acc += k[2]; acc += k[3];
                acc += k[4]; acc += k[5]; acc += k[6]; acc += k[7];
                n += HEAD_SIZE;
            }
        }
        t1 = cycles();
        sink = acc;
        printf("D strided loads only     : %u cycles / %u load = %u.%u cyc/load\n",
               (uint32_t)(t1-t0), n, (uint32_t)((t1-t0)/n),
               (uint32_t)(((t1-t0)*10u/n) % 10u));
    }

    /* ---- E: one float per 128 B stride -- worst case for the cache ---- */
    {
        uint32_t n = 0; float acc = 0.0f;
        t0 = cycles();
        for (uint32_t rep = 0; rep < REPS*8u; rep++) {
            for (uint32_t p = 0; p < KV_FLOATS/KV_DIM; p++) { acc += kv[p*KV_DIM]; n++; }
        }
        t1 = cycles();
        sink = acc;
        printf("E 1 float per 128B stride: %u cycles / %u load = %u.%u cyc/load\n",
               (uint32_t)(t1-t0), n, (uint32_t)((t1-t0)/n),
               (uint32_t)(((t1-t0)*10u/n) % 10u));
    }

    printf("\nA is the arithmetic floor. C is what attention actually does.\n");
    printf("C - A is the memory cost. B vs C isolates the stride's effect.\n");
    printf("done\n");
    return 0;
}
