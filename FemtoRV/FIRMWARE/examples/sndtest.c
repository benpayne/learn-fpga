// sndtest.c — Test sampled audio ring buffer
// Generates a 440Hz sine wave directly (no file needed)
// Outputs debug info to GPU to diagnose issues

#include <femtorv32.h>

// Sine table (256 entries, signed 16-bit)
static const int16_t sine_table[256] = {
        0,   804,  1608,  2410,  3212,  4011,  4808,  5602,
     6393,  7179,  7962,  8739,  9512, 10278, 11039, 11793,
    12539, 13279, 14010, 14732, 15446, 16151, 16846, 17530,
    18204, 18868, 19519, 20159, 20787, 21403, 22005, 22594,
    23170, 23731, 24279, 24811, 25329, 25832, 26319, 26790,
    27245, 27683, 28105, 28510, 28898, 29268, 29621, 29956,
    30273, 30571, 30852, 31113, 31356, 31580, 31785, 31971,
    32137, 32285, 32412, 32521, 32609, 32678, 32728, 32757,
    32767, 32757, 32728, 32678, 32609, 32521, 32412, 32285,
    32137, 31971, 31785, 31580, 31356, 31113, 30852, 30571,
    30273, 29956, 29621, 29268, 28898, 28510, 28105, 27683,
    27245, 26790, 26319, 25832, 25329, 24811, 24279, 23731,
    23170, 22594, 22005, 21403, 20787, 20159, 19519, 18868,
    18204, 17530, 16846, 16151, 15446, 14732, 14010, 13279,
    12539, 11793, 11039, 10278,  9512,  8739,  7962,  7179,
     6393,  5602,  4808,  4011,  3212,  2410,  1608,   804,
        0,  -804, -1608, -2410, -3212, -4011, -4808, -5602,
    -6393, -7179, -7962, -8739, -9512,-10278,-11039,-11793,
   -12539,-13279,-14010,-14732,-15446,-16151,-16846,-17530,
   -18204,-18868,-19519,-20159,-20787,-21403,-22005,-22594,
   -23170,-23731,-24279,-24811,-25329,-25832,-26319,-26790,
   -27245,-27683,-28105,-28510,-28898,-29268,-29621,-29956,
   -30273,-30571,-30852,-31113,-31356,-31580,-31785,-31971,
   -32137,-32285,-32412,-32521,-32609,-32678,-32728,-32757,
   -32767,-32757,-32728,-32678,-32609,-32521,-32412,-32285,
   -32137,-31971,-31785,-31580,-31356,-31113,-30852,-30571,
   -30273,-29956,-29621,-29268,-28898,-28510,-28105,-27683,
   -27245,-26790,-26319,-25832,-25329,-24811,-24279,-23731,
   -23170,-22594,-22005,-21403,-20787,-20159,-19519,-18868,
   -18204,-17530,-16846,-16151,-15446,-14732,-14010,-13279,
   -12539,-11793,-11039,-10278, -9512, -8739, -7962, -7179,
    -6393, -5602, -4808, -4011, -3212, -2410, -1608,  -804,
};

static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }

static void out_puts(const char *s) {
    while (*s) {
        if (*s == '\n') { gpu_putc('\r'); gpu_putc('\n'); putchar('\r'); putchar('\n'); }
        else { gpu_putc(*s); putchar(*s); }
        s++;
    }
}

static void out_hex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) {
        int n = (v >> i) & 0xF;
        char c = n < 10 ? '0' + n : 'a' + n - 10;
        gpu_putc(c); putchar(c);
    }
}

static void out_dec(int v) {
    if (v == 0) { gpu_putc('0'); putchar('0'); return; }
    if (v < 0) { gpu_putc('-'); putchar('-'); v = -v; }
    char buf[11]; int n = 0;
    while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
    while (n > 0) { gpu_putc(buf[n-1]); putchar(buf[n-1]); n--; }
}

// Fill half-buffer with 440Hz sine wave
// phase is a 16.16 fixed-point accumulator
static uint32_t fill_sine(int base, uint32_t phase) {
    // 440Hz at 48kHz: phase_inc = 440/48000 * 256 * 65536 = ~245366
    // Simpler: 440 * 256 / 48000 * 65536 = phase_inc per sample in 16.16
    // phase_inc = (440 << 16) / (48000 / 256) = (440 * 65536) / 187.5 ≈ 153722
    // Actually: we want (440/48000)*256 samples per cycle
    // phase_inc in 8.16 fixed: (440 * 256 * 65536) / 48000 = 153722
    uint32_t phase_inc = 153722;  // 440Hz

    SBUF_SET_ADDR(base);
    for (int i = 0; i < 512; i++) {
        uint8_t idx = (phase >> 16) & 0xFF;
        int16_t sample = sine_table[idx] >> 1;  // -6dB to avoid clipping
        SBUF_WRITE_SAMPLE(sample);
        phase += phase_inc;
    }
    return phase;
}

int main(void) {
    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("Sample buffer test\n");

    // Step 1: Reset buffer
    out_puts("1. Reset...");
    SBUF_CONTROL(SBUF_RESET);
    out_puts("OK\n");

    // Step 2: Read status
    out_puts("2. Status: 0x");
    uint32_t status = SBUF_READ_STATUS();
    out_hex(status);
    out_puts("\n");

    // Step 3: Fill both halves with sine wave
    out_puts("3. Fill buffer...");
    uint32_t phase = 0;
    phase = fill_sine(0, phase);
    phase = fill_sine(512, phase);
    out_puts("OK\n");

    // Step 4: Enable playback
    out_puts("4. Enable...");
    SBUF_CONTROL(SBUF_ENABLE);
    out_puts("OK\n");

    // Step 5: Read status after enable
    out_puts("5. Status: 0x");
    status = SBUF_READ_STATUS();
    out_hex(status);
    out_puts("\n");

    // Step 6: Poll for 3 seconds, showing status changes
    out_puts("6. Playing 3s...\n");
    int last_half = -1;
    int fills = 0;
    int loops = 0;
    int timeout = 75000000;  // 3 seconds at 25MHz

    IO_OUT(IO_TIMER, 0xFFFFFFFF);  // Start timer
    uint32_t start = IO_IN(IO_TIMER);

    while ((IO_IN(IO_TIMER) - start) < timeout) {
        status = SBUF_READ_STATUS();
        int current_half = (status >> 10) & 1;
        loops++;

        if (current_half != last_half && last_half >= 0) {
            // Refill the half we just finished reading
            int fill_base = current_half ? 0 : 512;
            phase = fill_sine(fill_base, phase);
            fills++;
        }
        last_half = current_half;
    }

    // Step 7: Stop
    SBUF_CONTROL(0);

    out_puts("7. Done. fills=");
    out_dec(fills);
    out_puts(" loops=");
    out_dec(loops);
    out_puts("\n");

    // Show final status
    out_puts("   Final status: 0x");
    out_hex(SBUF_READ_STATUS());
    out_puts("\n");

    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("Test complete\n");
    return 0;
}
