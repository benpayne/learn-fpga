// RetroKernel - Filesystem (FAT16/FAT32 via fat_io_lib)

#include "kernel.h"

// FAT library
#include "fat_io_lib/fat_filelib.h"

typedef int (*fn_diskio_read)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
typedef int (*fn_diskio_write)(uint32_t sector, uint8_t *buffer, uint32_t sector_count);

// SD card
extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);
extern int sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

#define FAT_INIT_OK 0

static int fs_mounted = 0;
static char cwd[MAX_PATH] = "/";

int fs_init(void) {
    if (sd_init()) return 0;

    fl_init();
    if (fl_attach_media((fn_diskio_read)sd_readsector,
                        (fn_diskio_write)sd_writesector) != FAT_INIT_OK) {
        return 0;
    }

    fs_mounted = 1;
    return 1;
}

int fs_list_dir(const char *path) {
    if (!fs_mounted) {
        con_puts("no filesystem mounted\n");
        return 0;
    }

    // Build full path
    char fullpath[MAX_PATH];
    int fp = 0;

    if (path[0] == '.' && (path[1] == '\0' || path[1] == '/')) {
        // Use cwd
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) fullpath[fp++] = cwd[i++];
    } else if (path[0] == '/') {
        while (path[fp] && fp < MAX_PATH - 1) { fullpath[fp] = path[fp]; fp++; }
    } else {
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) fullpath[fp++] = cwd[i++];
        if (fp > 0 && fullpath[fp-1] != '/') fullpath[fp++] = '/';
        i = 0;
        while (path[i] && fp < MAX_PATH - 1) fullpath[fp++] = path[i++];
    }
    fullpath[fp] = '\0';

    // Use fl_opendir/fl_readdir for directory listing with dual output
    FL_DIR dirstat;
    fl_dirent dirent;

    if (!fl_opendir(fullpath, &dirstat)) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("ls: cannot open ");
        con_puts(fullpath);
        con_putc('\n');
        return 0;
    }

    int files = 0, dirs = 0;
    uint32_t total_size = 0;

    while (fl_readdir(&dirstat, &dirent) == 0) {
        if (dirent.is_dir) {
            con_set_fg(GPU_BRIGHT_CYAN);
            con_puts(dirent.filename);
            con_puts("/\n");
            dirs++;
        } else {
            con_set_fg(GPU_WHITE);
            con_puts(dirent.filename);
            // Pad to column 20
            int len = 0;
            const char *p = dirent.filename;
            while (*p++) len++;
            while (len < 20) { con_putc(' '); len++; }
            con_set_fg(GPU_LIGHT_GRAY);
            con_dec(dirent.size);
            con_putc('\n');
            files++;
            total_size += dirent.size;
        }
    }

    fl_closedir(&dirstat);

    con_set_fg(GPU_LIGHT_GRAY);
    con_dec(files);
    con_puts(" file(s), ");
    con_dec(dirs);
    con_puts(" dir(s), ");
    con_dec(total_size);
    con_puts(" bytes\n");

    return 1;
}

int fs_chdir(const char *path) {
    if (!fs_mounted) return 0;

    if (path[0] == '/') {
        // Absolute path
        // Verify it exists by trying to list it
        // For now just set it
        int i = 0;
        while (path[i] && i < MAX_PATH - 1) { cwd[i] = path[i]; i++; }
        cwd[i] = '\0';
        // Ensure trailing /
        if (i > 1 && cwd[i-1] != '/') { cwd[i] = '/'; cwd[i+1] = '\0'; }
    } else if (path[0] == '.' && path[1] == '.') {
        // Go up
        int len = 0;
        while (cwd[len]) len++;
        if (len > 1) {
            // Remove trailing /
            if (cwd[len-1] == '/') len--;
            // Find previous /
            while (len > 0 && cwd[len-1] != '/') len--;
            if (len == 0) len = 1;
            cwd[len] = '\0';
        }
    } else {
        // Relative path — append to cwd
        int len = 0;
        while (cwd[len]) len++;
        if (len > 0 && cwd[len-1] != '/') { cwd[len++] = '/'; }
        int i = 0;
        while (path[i] && len < MAX_PATH - 2) { cwd[len++] = path[i++]; }
        cwd[len] = '/';
        cwd[len+1] = '\0';
    }
    return 1;
}

const char *fs_getcwd(void) {
    return cwd;
}

int fs_load_file(const char *path, void *dest, uint32_t max_size) {
    if (!fs_mounted) return -1;

    // Build full path
    char fullpath[MAX_PATH];
    int fp = 0;

    if (path[0] == '/') {
        // Absolute
        while (path[fp] && fp < MAX_PATH - 1) { fullpath[fp] = path[fp]; fp++; }
    } else {
        // Relative to cwd
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) fullpath[fp++] = cwd[i++];
        if (fp > 0 && fullpath[fp-1] != '/') fullpath[fp++] = '/';
        i = 0;
        while (path[i] && fp < MAX_PATH - 1) fullpath[fp++] = path[i++];
    }
    fullpath[fp] = '\0';

    void *f = fl_fopen(fullpath, "r");
    if (!f) return -1;

    uint8_t *buf = (uint8_t *)dest;
    int total = 0;
    int c;
    while (total < (int)max_size) {
        c = fl_fgetc(f);
        if (c < 0) break;  // EOF
        buf[total++] = (uint8_t)c;
    }

    fl_fclose(f);
    return total;
}

int fs_file_size(const char *path) {
    // Quick hack: load file and count bytes
    // TODO: use fl_fstat or similar
    return -1;
}
