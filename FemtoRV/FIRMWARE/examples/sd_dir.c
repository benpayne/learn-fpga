// sd_dir.c - List SD card directory contents using FAT library
// Runs from SDRAM, uses full FAT16/FAT32 filesystem support

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
extern void fl_listdirectory(const char *path);
extern void *fl_fopen(const char *path, const char *mode);
extern int fl_fread(void *buffer, int size, int count, void *file);
extern void fl_fclose(void *file);

#define FAT_INIT_OK 0

// Dual output (GPU + UART)
static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_clear(void) { GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN | GPU_CTRL_80COL); wait_cycles(5000); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }
static inline void gpu_set_bg(int c) { GPU_WRITE(GPU_REG_BG_COLOR, c); }

static void out_puts(const char *s) {
    while (*s) {
        if (*s == '\n') { gpu_putc('\r'); gpu_putc('\n'); putchar('\r'); putchar('\n'); }
        else { gpu_putc(*s); putchar(*s); }
        s++;
    }
}

int main(void) {
    gpu_clear();
    gpu_set_fg(GPU_BRIGHT_CYAN); gpu_set_bg(GPU_BLACK);
    out_puts("SD Card Directory Listing\n");
    out_puts("=========================\n\n");

    // Initialize SD card
    gpu_set_fg(GPU_YELLOW);
    out_puts("Initializing SD card...\n");

    if (sd_init()) {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("ERROR: SD card init failed\n");
        return 1;
    }
    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("SD card OK\n");

    // Initialize FAT filesystem
    out_puts("Mounting filesystem...\n");
    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector, (fn_diskio_write)sd_writesector) != FAT_INIT_OK) {
        gpu_set_fg(GPU_BRIGHT_RED);
        out_puts("ERROR: Failed to mount filesystem\n");
        out_puts("Card may not be FAT16/FAT32 formatted\n");
        return 1;
    }

    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("Filesystem mounted OK\n\n");

    // List root directory
    gpu_set_fg(GPU_WHITE);
    out_puts("Root directory:\n");
    gpu_set_fg(GPU_LIGHT_GRAY);
    out_puts("---\n");

    // fl_listdirectory prints to stdout (UART) via printf
    // We need to also capture for GPU... for now it goes to UART only
    fl_listdirectory("/");

    out_puts("---\n");
    gpu_set_fg(GPU_BRIGHT_GREEN);
    out_puts("\nDone.\n");

    return 0;
}
