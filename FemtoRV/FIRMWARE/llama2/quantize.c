/*
 * quantize.c -- implements quantize.h. Verbatim port of upstream
 * llama2.c's runq.c quantize() (also reproduced unchanged in
 * tools/runq_host.c, the golden reference this must match bit-for-bit).
 * See quantize.h for why fabs()/round() (double) are used instead of the
 * float-suffixed forms.
 */

#include "quantize.h"
#include <math.h>

void quantize_activations(int8_t *q, float *s, const float *x, int n, int gs) {
    int num_groups = n / gs;
    float Q_MAX = 127.0f;

    for (int group = 0; group < num_groups; group++) {

        /* find the max absolute value in the current group */
        float wmax = 0.0f;
        for (int i = 0; i < gs; i++) {
            float val = fabs(x[group * gs + i]);
            if (val > wmax) {
                wmax = val;
            }
        }

        /* calculate and write the scaling factor */
        float scale = wmax / Q_MAX;
        s[group] = scale;

        /* calculate and write the quantized values */
        for (int i = 0; i < gs; i++) {
            float quant_value = x[group * gs + i] / scale; /* scale */
            int8_t quantized = (int8_t) round(quant_value); /* round and clamp */
            q[group * gs + i] = quantized;
        }
    }
}
