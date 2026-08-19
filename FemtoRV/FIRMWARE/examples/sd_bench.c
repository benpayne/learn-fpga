// sd_bench.c - SD card read throughput benchmark (serial only, no GPU)
//
// The single highest-value measurement in the llama2-minimal-soc project:
// the SD card is bit-banged in software (each SPI clock edge is a separate
// IO write), so nobody knows yet whether it can load a ~1MB model file in
// a reasonable time. This program reads a file end-to-end at a few
// candidate chunk sizes and reports measured KB/s for each, plus a
// projection for the real model size against the 60-second acceptance
// threshold (SC-005).
//
// Uses the sd_init()/fl_attach_media()/fl_fopen()/fl_fread() pattern from
// sd_dir.c. Runs from SDRAM (linked at 0x800000 via upload_sdram.ld),
// uploaded via the BIOS monitor's XMODEM 'L' command and started with
// 'G 800000'.

#include <femtorv32.h>

// SD card functions
extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);
extern int sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

// FAT library
typedef int (*fn_diskio_read)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
typedef int (*fn_diskio_write)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
extern void fl_init(void);
extern int fl_attach_media(fn_diskio_read rd, fn_diskio_write wr);
extern void *fl_fopen(const char *path, const char *mode);
extern int fl_fread(void *buffer, int size, int count, void *file);
extern void fl_fclose(void *file);

#define FAT_INIT_OK 0

// File to benchmark. There is no argv for SDRAM-linked programs (see
// femtorv32.S _start), so edit this and rebuild to point at a different
// file. Defaults to the model file's eventual location; any file of
// reasonable size on the card works for this test.
#define BENCH_FILE      "/model.bin"

// Actual llama2 model size (SC-005 target payload), used only for the
// final load-time projection.
#define MODEL_BYTES     1056540UL

#define CLOCK_HZ         25000000UL  // Colorlight i5 system clock
#define ACCEPT_SEC       60UL        // SC-005 acceptance threshold

// Scratch buffer in SDRAM for the reads. Capped well below the model size
// range so a much larger test file can't run us into other memory use.
#define SDRAM_BUF        ((uint8_t *)0x900000)
#define SDRAM_BUF_BYTES  (2UL * 1024UL * 1024UL)

static const int chunk_sizes[] = { 512, 4096, 32768 };
#define NUM_CHUNKS (sizeof(chunk_sizes) / sizeof(chunk_sizes[0]))

// ---- output helpers ----
// The terminal expects CRLF line endings (every other serial-only/GPU
// example in this tree translates '\n' -> "\r\n" explicitly), so route
// all text through outs()/crlf() instead of the raw puts()/printf "\n".

static void crlf(void) { putchar('\r'); putchar('\n'); }

static void outs(const char *s) {
    for (const char *p = s; *p; p++) {
        if (*p == '\n') crlf();
        else putchar(*p);
    }
}

static void print_dec3(uint32_t v) {
    // zero-padded 3-digit decimal (for millisecond fractions)
    putchar('0' + (v / 100) % 10);
    putchar('0' + (v / 10) % 10);
    putchar('0' + v % 10);
}

// bytes_per_sec -> "NNN.N KB/s"
static void print_kbps(uint64_t bytes_per_sec) {
    uint32_t whole = (uint32_t)(bytes_per_sec / 1024);
    uint32_t frac  = (uint32_t)(((bytes_per_sec % 1024) * 10) / 1024);
    printf("%d.%d KB/s", (int)whole, (int)frac);
}

// elapsed cycles -> "N.NNN sec"
static void print_elapsed(uint64_t elapsed_cycles) {
    uint32_t ms = (uint32_t)(elapsed_cycles / (CLOCK_HZ / 1000UL));
    printf("%d.", (int)(ms / 1000));
    print_dec3(ms % 1000);
    outs(" sec");
}

int main(void) {
    outs("SD Card Throughput Benchmark"); crlf();
    outs("============================="); crlf(); crlf();

    outs("Initializing SD card..."); crlf();
    if (sd_init()) {
        outs("ERROR: SD card init failed (no card detected / SPI bring-up failed)"); crlf();
        return 1;
    }
    outs("SD card OK"); crlf();

    outs("Mounting filesystem..."); crlf();
    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector, (fn_diskio_write)sd_writesector) != FAT_INIT_OK) {
        outs("ERROR: Failed to mount filesystem (card may not be FAT16/FAT32 formatted)"); crlf();
        return 1;
    }
    outs("Filesystem mounted OK"); crlf(); crlf();

    printf("Benchmark file: %s", BENCH_FILE); crlf(); crlf();

    uint64_t best_bps = 0;
    int best_chunk = 0;
    int any_success = 0;

    for (unsigned i = 0; i < NUM_CHUNKS; i++) {
        int chunk = chunk_sizes[i];

        void *f = fl_fopen(BENCH_FILE, "r");
        if (!f) {
            printf("ERROR: file not found: %s", BENCH_FILE); crlf();
            outs("(create/copy the file onto the SD card and re-run)"); crlf();
            return 1;
        }

        uint32_t total = 0;
        uint64_t t0 = cycles();

        for (;;) {
            if (total + (uint32_t)chunk > SDRAM_BUF_BYTES) break; // stay in scratch buffer
            int n = fl_fread(SDRAM_BUF + total, 1, chunk, f);
            if (n <= 0) break;
            total += (uint32_t)n;
            if ((uint32_t)n < (uint32_t)chunk) break; // short read == EOF
        }

        uint64_t t1 = cycles();
        fl_fclose(f);

        uint64_t elapsed = t1 - t0;
        uint64_t bps = elapsed ? ((uint64_t)total * CLOCK_HZ) / elapsed : 0;

        printf("chunk=%d bytes: read %d bytes in ", chunk, (int)total);
        print_elapsed(elapsed);
        outs(" (");
        print_kbps(bps);
        outs(")"); crlf();

        if (total > 0) {
            any_success = 1;
            if (bps > best_bps) {
                best_bps = bps;
                best_chunk = chunk;
            }
        }
    }

    crlf();

    if (!any_success) {
        outs("ERROR: no bytes were read from the benchmark file (zero-length file?)"); crlf();
        return 1;
    }

    outs("---------------------------------------------"); crlf();
    outs("Best throughput: ");
    print_kbps(best_bps);
    printf(" at chunk size %d", best_chunk); crlf();

    // Project time to load the real model (MODEL_BYTES) at the best rate.
    uint64_t proj_us = best_bps ? (MODEL_BYTES * 1000000ULL) / best_bps : 0;
    uint32_t proj_sec_whole = (uint32_t)(proj_us / 1000000ULL);
    uint32_t proj_ms        = (uint32_t)((proj_us / 1000ULL) % 1000ULL);

    printf("Projected load time for %d bytes (llama2 model, SC-005): ", (int)MODEL_BYTES);
    printf("%d.", (int)proj_sec_whole);
    print_dec3(proj_ms);
    outs(" sec"); crlf();

    if (proj_us <= ACCEPT_SEC * 1000000ULL) {
        outs("=> UNDER the 60-second target (SC-005 satisfied at this rate)"); crlf();
    } else {
        outs("=> OVER the 60-second target (SC-005 at risk -- see research.md R6 escalation options)"); crlf();
    }

    return 0;
}
