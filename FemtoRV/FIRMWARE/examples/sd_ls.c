// sd_ls.c - list what is on the SD card, over serial.
//
// The serial-only sibling of sd_dir.c: same sd_init() / fl_attach_media()
// / fl_listdirectory() sequence, but with the GPU writes removed and
// linked at 0x800000 (upload_sdram.ld) instead of 0x810000, so it runs
// under the BIOS monitor on the minimal LLM profile rather than needing
// the RetroKernel shell and a GPU that this profile does not build.
//
// Upload with the monitor's XMODEM 'L' command, run with 'G 800000'.

#include <femtorv32.h>

// SD card block driver (LIBFEMTORV32)
extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);
extern int sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

// FAT16/FAT32 filesystem (fat_io_lib)
typedef int (*fn_diskio_read)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
typedef int (*fn_diskio_write)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
extern void fl_init(void);
extern int  fl_attach_media(fn_diskio_read rd, fn_diskio_write wr);
extern void fl_listdirectory(const char *path);

#define FAT_INIT_OK 0

// There is no argv for SDRAM-linked programs (see femtorv32.S _start),
// so the directory to list is a compile-time constant.
#define LIST_PATH "/"

static void outs(const char *s) {
    while (*s) { if (*s == '\n') putchar('\r'); putchar(*s++); }
}

int main(void) {
    outs("\n");
    outs("SD card listing\n");
    outs("===============\n\n");

    outs("initializing card... ");
    if (sd_init()) {
        outs("FAILED\n");
        outs("  no card, or the PMOD is not seated on P2.\n");
        return 1;
    }
    outs("ok\n");

    outs("mounting filesystem... ");
    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector,
                        (fn_diskio_write)sd_writesector) != FAT_INIT_OK) {
        outs("FAILED\n");
        outs("  card is not FAT16/FAT32 formatted.\n");
        return 1;
    }
    outs("ok\n");

    // fl_listdirectory prints straight to the UART via printf, already
    // CRLF-terminated, one line per entry: name + size, or name + <DIR>.
    fl_listdirectory(LIST_PATH);

    outs("\nDone.\n");
    return 0;
}
