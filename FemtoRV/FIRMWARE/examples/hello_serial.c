// hello_serial.c - the smallest thing that proves the board is alive.
//
// Serial only, deliberately: this is built for the minimal LLM profile
// (colorlight_i5_llm), which has no GPU and no PS2 keyboard. The existing
// hello.c writes to both the GPU and the UART and links at 0x810000 as a
// RetroKernel program -- neither of which exists in this profile.
//
// Runs from SDRAM (linked at 0x800000 via upload_sdram.ld), uploaded with
// the BIOS monitor's XMODEM 'L' command and started with 'G 800000'.

#include <femtorv32.h>

#define CLOCK_HZ 25000000UL

// The terminal wants CRLF, and printf("\n") alone leaves the cursor in
// column N. Every serial-only example in this tree translates explicitly.
static void outs(const char *s) {
    while (*s) { if (*s == '\n') putchar('\r'); putchar(*s++); }
}

int main(void) {
    outs("\n");
    outs("Hello, world -- from a RISC-V core I built.\n");
    outs("\n");
    outs("  FemtoRV petitbateau (RV32IMFC) on a Colorlight i5 / ECP5\n");
    outs("  25 MHz, 8 MB SDRAM, running from SDRAM at 0x800000\n");
    outs("\n");

    // Prove the clock is really what we claim: count cycles across a
    // one-second wall-clock wait and print the ratio. A wrong PLL or a
    // wrong CLOCK_HZ shows up here rather than silently skewing every
    // benchmark in the tree.
    uint64_t t0 = cycles();
    milliwait(1000);
    uint64_t t1 = cycles();
    uint32_t measured = (uint32_t)(t1 - t0);

    // LIBFEMTOC's printf handles only %s %x %d %u %c -- no width or flag
    // characters (acc_test.c:547 documents this). "%02u" would emit a bare
    // '0' and then the literal "2u". Split the fraction out and pad the
    // leading zero by hand, the same way sdram_memtest.c does.
    uint32_t mhz_whole = measured / 1000000u;
    uint32_t mhz_frac  = (measured % 1000000u) / 10000u;   /* 2 decimal digits */
    printf("  cycle counter: %u ticks in 1000 ms -> %u.", measured, mhz_whole);
    if (mhz_frac < 10u) putchar('0');
    printf("%u MHz\r\n", mhz_frac);
    outs("\n");

    // Something to point at across the room. D1-D4 walk twice; the LEDs
    // are the only output this profile has that is not the serial port.
    outs("  walking the LEDs...\n");
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 4; i++) { LEDS(1 << i); milliwait(120); }
        for (int i = 2; i > 0; i--) { LEDS(1 << i); milliwait(120); }
    }
    LEDS(0);

    outs("\n");
    outs("Done.\n");
    return 0;
}
