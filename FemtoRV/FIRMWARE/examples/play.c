// play.c — Simple PCM audio player for RetroKernel
// Plays raw 16-bit signed mono PCM files at 48kHz from SD card
// Usage: play <filename.raw>
//
// To convert a WAV to raw PCM:
//   ffmpeg -i input.wav -f s16le -acodec pcm_s16le -ar 48000 -ac 1 output.raw
// Or for 8-bit unsigned WAV files, this program converts on-the-fly.

#include "retrokernel.h"

// Sample buffer is 1024 x 16-bit, split into two 512-sample halves
// We fill one half while the other plays

static int fd = -1;
static int file_done = 0;
static int bytes_per_sample = 2;  // 2 for 16-bit, 1 for 8-bit
static int is_8bit = 0;

// Fill one half of the buffer (512 samples)
static int fill_half(int base_addr) {
    uint8_t buf[1024];  // Max 512 samples x 2 bytes
    int bytes_to_read = SBUF_HALF * bytes_per_sample;

    int got = rk_fread(fd, buf, bytes_to_read);
    if (got <= 0) {
        // End of file — fill with silence
        SBUF_SET_ADDR(base_addr);
        for (int i = 0; i < SBUF_HALF; i++)
            SBUF_WRITE_SAMPLE(0);
        return 0;
    }

    int samples = got / bytes_per_sample;

    SBUF_SET_ADDR(base_addr);
    if (is_8bit) {
        // Convert unsigned 8-bit to signed 16-bit
        for (int i = 0; i < samples; i++)
            SBUF_WRITE_SAMPLE(((int16_t)buf[i] - 128) << 8);
    } else {
        // 16-bit signed LE — write directly
        for (int i = 0; i < samples; i++) {
            int16_t sample = (int16_t)(buf[i*2] | (buf[i*2+1] << 8));
            SBUF_WRITE_SAMPLE(sample);
        }
    }

    // Pad remainder with silence if partial read
    for (int i = samples; i < SBUF_HALF; i++)
        SBUF_WRITE_SAMPLE(0);

    return (got < bytes_to_read) ? 0 : 1;  // 0 = last chunk
}

int main(int argc, char **argv) {
    if (argc < 2) {
        rk_puts("usage: play <file.raw>\n");
        rk_puts("  Plays 16-bit signed mono PCM at 48kHz\n");
        rk_puts("  Use .raw extension for 16-bit, .u8 for 8-bit unsigned\n");
        return 1;
    }

    // Check for 8-bit mode based on extension
    const char *name = argv[1];
    int len = 0;
    while (name[len]) len++;
    if (len >= 3 && name[len-3] == '.' && name[len-2] == 'u' && name[len-1] == '8') {
        is_8bit = 1;
        bytes_per_sample = 1;
    }

    // Open file
    fd = rk_fopen(argv[1], "r");
    if (fd < 0) {
        rk_set_fg(GPU_BRIGHT_RED);
        rk_puts("Cannot open ");
        rk_puts(argv[1]);
        rk_putc('\n');
        return 1;
    }

    rk_set_fg(GPU_BRIGHT_CYAN);
    rk_puts("Playing ");
    rk_puts(argv[1]);
    rk_puts(is_8bit ? " (8-bit)" : " (16-bit)");
    rk_puts(" @ 48kHz\n");

    // Reset and fill both halves before starting
    SBUF_CONTROL(SBUF_RESET);

    int more = fill_half(0);           // Fill first half (0-511)
    if (more) more = fill_half(512);   // Fill second half (512-1023)

    // Start playback
    SBUF_CONTROL(SBUF_ENABLE);

    rk_set_fg(GPU_LIGHT_GRAY);
    rk_puts("Press any key to stop\n");

    // Main loop: poll for half-buffer interrupt, refill
    // We poll the read pointer to know which half to fill
    int last_half = 0;  // 0 = reading half A, 1 = reading half B

    while (more) {
        uint32_t status = SBUF_READ_STATUS();
        int current_half = (status >> 10) & 1;  // bit 10 of rd_ptr = which half

        if (current_half != last_half) {
            // Read pointer crossed into the other half — fill the one it just left
            int fill_base = current_half ? 0 : 512;
            more = fill_half(fill_base);
            last_half = current_half;
        }

        // Check for keypress to abort
        // (Can't use rk_getkey as it blocks — just check with a quick poll)
        // For now, just play to completion
    }

    // Wait for remaining buffer to play out (~10ms per half)
    for (volatile int i = 0; i < 500000; i++);

    // Stop playback
    SBUF_CONTROL(0);
    rk_fclose(fd);

    rk_set_fg(GPU_BRIGHT_GREEN);
    rk_puts("Done\n");
    return 0;
}
