// play.c — PCM audio player for RetroKernel
// Loads raw 16-bit signed mono PCM file entirely to SDRAM, then plays via ring buffer.
// Usage: play <filename.raw>
//
// To convert: ffmpeg -i input.wav -f s16le -acodec pcm_s16le -ar 48000 -ac 1 output.raw

#include "retrokernel.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        rk_puts("usage: play <file.raw>\n");
        return 1;
    }

    // Load entire file to SDRAM temp buffer
    uint8_t *buf = (uint8_t *)0x900000;  // Temp area
    uint32_t max_size = 0x400000;        // 4MB max

    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts("Loading ");
    rk_puts(argv[1]);
    rk_puts("...");

    int size = rk_load_file(argv[1], buf, max_size);
    if (size <= 0) {
        rk_set_fg(GPU_BRIGHT_RED);
        rk_puts("failed\n");
        return 1;
    }

    int total_samples = size / 2;  // 16-bit samples
    rk_putdec(total_samples);
    rk_puts(" samples\n");

    // Pre-fill both halves of the ring buffer
    int16_t *samples = (int16_t *)buf;
    int pos = 0;

    SBUF_CONTROL(SBUF_RESET);

    // Fill first half (0-511)
    SBUF_SET_ADDR(0);
    for (int i = 0; i < SBUF_HALF && pos < total_samples; i++, pos++)
        SBUF_WRITE_SAMPLE(samples[pos]);
    for (int i = pos; i < SBUF_HALF; i++)
        SBUF_WRITE_SAMPLE(0);

    // Fill second half (512-1023)
    SBUF_SET_ADDR(SBUF_HALF);
    for (int i = 0; i < SBUF_HALF && pos < total_samples; i++, pos++)
        SBUF_WRITE_SAMPLE(samples[pos]);
    for (int i = pos; i < SBUF_HALF; i++)
        SBUF_WRITE_SAMPLE(0);

    // Start playback
    SBUF_CONTROL(SBUF_ENABLE);

    rk_set_fg(GPU_LIGHT_GRAY);
    rk_puts("Playing...\n");

    // Refill loop: poll read pointer to detect half-boundary crossings
    int last_half = 0;
    int done = 0;

    while (!done) {
        uint32_t status = SBUF_READ_STATUS();
        int current_half = (status >> 10) & 1;

        if (current_half != last_half) {
            // Fill the half we just finished reading
            int fill_base = current_half ? 0 : SBUF_HALF;
            SBUF_SET_ADDR(fill_base);

            for (int i = 0; i < SBUF_HALF; i++) {
                if (pos < total_samples) {
                    SBUF_WRITE_SAMPLE(samples[pos++]);
                } else {
                    SBUF_WRITE_SAMPLE(0);
                    done = 1;
                }
            }
            last_half = current_half;
        }
    }

    // Let the last buffer play out
    for (volatile int i = 0; i < 500000; i++);

    // Stop
    SBUF_CONTROL(0);

    rk_set_fg(GPU_BRIGHT_GREEN);
    rk_puts("Done\n");
    return 0;
}
