/* sdput.c -- write a staged buffer from SDRAM onto the SD card.
 *
 * Why this exists: the minimal LLM profile (feature 003/004) has no
 * RetroKernel, so there is no shell and no `cp`. The BIOS monitor can
 * XMODEM a file into memory but cannot put it on the card, and running
 * llama2 needs model.q8.bin present as a FAT file because runq.c loads it
 * through fl_fopen(). Without this the only route onto the card is
 * physically moving it to another machine.
 *
 * fat_io_lib's write support is already built into libfemtorv32
 * (fat_write.o), so this is a small wrapper rather than new machinery.
 *
 * Usage, from the monitor:
 *     L C00000            <- XMODEM the file into the staging area
 *     L 800000            <- XMODEM this program
 *     G 800000
 *
 * The length is NOT passed in. A Q8_0 checkpoint describes its own size:
 * the 256-byte header carries the config and group size, and
 * q8_checkpoint_bytes() derives the exact total from them. Deriving the
 * length from the data means a truncated upload is detected rather than
 * silently written short -- the failure this whole feature keeps
 * rediscovering is the one that looks like success.
 */

#include <femtorv32.h>
#include <stdint.h>
#include "../llama2/q8_format.h"

#define STAGE_ADDR   0xC00000u        /* free SDRAM: above ML_RUNSTATE, below the stack */
#define DEST_PATH    "/model.q8.bin"
#define COPY_CHUNK   4096u

extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);
extern int sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

typedef int (*fn_diskio_read)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
typedef int (*fn_diskio_write)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
extern void fl_init(void);
extern int  fl_attach_media(fn_diskio_read rd, fn_diskio_write wr);
extern void *fl_fopen(const char *path, const char *mode);
extern int  fl_fread(void *buffer, int size, int count, void *file);
extern int  fl_fwrite(const void *data, int size, int count, void *file);
extern void fl_fclose(void *file);

#define FAT_INIT_OK 0

int main(void) {
    const uint8_t *stage = (const uint8_t *)STAGE_ADDR;
    const Q8Header *hdr  = (const Q8Header *)STAGE_ADDR;

    printf("\nsdput: stage 0x%x -> %s\n", STAGE_ADDR, DEST_PATH);

    if (hdr->magic != Q8_0_MAGIC) {
        printf("FAIL: no Q8_0 magic at 0x%x (found 0x%x, expected 0x%x)\n",
               STAGE_ADDR, hdr->magic, Q8_0_MAGIC);
        printf("Upload the file with 'L %x' before running this.\n", STAGE_ADDR);
        return 1;
    }

    int32_t gs = hdr->group_size;
    uint32_t total = q8_checkpoint_bytes(&hdr->config, gs, hdr->shared_classifier);

    printf("header OK: dim=%d hidden=%d layers=%d vocab=%d gs=%d shared=%d\n",
           hdr->config.dim, hdr->config.hidden_dim, hdr->config.n_layers,
           hdr->config.vocab_size, gs, hdr->shared_classifier);
    printf("size derived from header: %u bytes\n", total);

    if (sd_init()) { printf("FAIL: sd_init\n"); return 1; }
    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector,
                        (fn_diskio_write)sd_writesector) != FAT_INIT_OK) {
        printf("FAIL: fl_attach_media\n");
        return 1;
    }

    void *f = fl_fopen(DEST_PATH, "w");
    if (!f) { printf("FAIL: fl_fopen(%s,\"w\")\n", DEST_PATH); return 1; }

    uint32_t off = 0;
    while (off < total) {
        uint32_t n = (total - off < COPY_CHUNK) ? (total - off) : COPY_CHUNK;
        if (fl_fwrite(stage + off, 1, (int)n, f) != (int)n) {
            printf("\nFAIL: short write at offset %u\n", off);
            fl_fclose(f);
            return 1;
        }
        off += n;
        if ((off & 0xFFFFu) == 0 || off == total)
            printf("  wrote %u / %u\n", off, total);
    }
    fl_fclose(f);

    /* Read back and compare. A write that reports success and produced the
     * wrong bytes is exactly the failure mode this project keeps hitting,
     * so the file is verified rather than trusted. */
    printf("verifying...\n");
    f = fl_fopen(DEST_PATH, "r");
    if (!f) { printf("FAIL: reopen for verify\n"); return 1; }

    static uint8_t buf[COPY_CHUNK];
    uint32_t bad = 0, checked = 0;
    off = 0;
    while (off < total) {
        uint32_t n = (total - off < COPY_CHUNK) ? (total - off) : COPY_CHUNK;
        int got = fl_fread(buf, 1, (int)n, f);
        if (got != (int)n) { printf("FAIL: short read at %u (got %d)\n", off, got); fl_fclose(f); return 1; }
        for (uint32_t i = 0; i < n; i++) { if (buf[i] != stage[off + i]) bad++; }
        checked += n;
        off += n;
    }
    fl_fclose(f);

    if (bad) { printf("FAIL: %u of %u bytes differ after readback\n", bad, checked); return 1; }
    printf("OK: %s written and verified, %u bytes\n", DEST_PATH, checked);
    return 0;
}
