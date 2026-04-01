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

// Build a full path from cwd + relative path into dest buffer
// Returns length of resulting path
static int build_path(char *dest, const char *path) {
    int fp = 0;
    if (path[0] == '/') {
        while (path[fp] && fp < MAX_PATH - 1) { dest[fp] = path[fp]; fp++; }
    } else {
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) dest[fp++] = cwd[i++];
        if (fp > 0 && dest[fp-1] != '/') dest[fp++] = '/';
        i = 0;
        while (path[i] && fp < MAX_PATH - 1) dest[fp++] = path[i++];
    }
    dest[fp] = '\0';
    return fp;
}

// Verify a directory exists by trying to open it
static int dir_exists(const char *path) {
    FL_DIR dirstat;
    if (fl_opendir(path, &dirstat)) {
        fl_closedir(&dirstat);
        return 1;
    }
    return 0;
}

int fs_chdir(const char *path) {
    if (!fs_mounted) return 0;

    if (path[0] == '.' && path[1] == '.' && (path[2] == '\0' || path[2] == '/')) {
        // Go up
        int len = 0;
        while (cwd[len]) len++;
        if (len > 1) {
            if (cwd[len-1] == '/') len--;
            while (len > 0 && cwd[len-1] != '/') len--;
            if (len == 0) len = 1;
            cwd[len] = '\0';
        }
        return 1;
    }

    // Build candidate path
    char newpath[MAX_PATH];
    int len = build_path(newpath, path);

    // Ensure trailing /
    if (len > 1 && newpath[len-1] != '/') { newpath[len] = '/'; newpath[len+1] = '\0'; len++; }

    // Verify directory exists (root always exists)
    if (len > 1 && !dir_exists(newpath)) {
        return 0;
    }

    // Set cwd
    int i = 0;
    while (newpath[i] && i < MAX_PATH - 1) { cwd[i] = newpath[i]; i++; }
    cwd[i] = '\0';
    return 1;
}

// Returns: 1=created, 0=failed, -1=already exists
int fs_mkdir(const char *path) {
    if (!fs_mounted) return 0;

    char fullpath[MAX_PATH];
    build_path(fullpath, path);

    if (dir_exists(fullpath))
        return -1;  // Already exists

    return fl_createdirectory(fullpath);
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

    int total = fl_fread(dest, 1, max_size, f);
    fl_fclose(f);
    return total;
}

int fs_save_file(const char *path, const void *data, uint32_t size) {
    if (!fs_mounted) return -1;

    // Build full path
    char fullpath[MAX_PATH];
    int fp = 0;

    if (path[0] == '/') {
        while (path[fp] && fp < MAX_PATH - 1) { fullpath[fp] = path[fp]; fp++; }
    } else {
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) fullpath[fp++] = cwd[i++];
        if (fp > 0 && fullpath[fp-1] != '/') fullpath[fp++] = '/';
        i = 0;
        while (path[i] && fp < MAX_PATH - 1) fullpath[fp++] = path[i++];
    }
    fullpath[fp] = '\0';

    void *f = fl_fopen(fullpath, "w");
    if (!f) return -1;

    int written = fl_fwrite(data, 1, size, f);
    fl_fclose(f);
    return written;
}

int fs_remove(const char *path) {
    if (!fs_mounted) return 0;

    char fullpath[MAX_PATH];
    build_path(fullpath, path);

    return fl_remove(fullpath) == 0 ? 1 : 0;
}

int fs_copy(const char *src, const char *dst) {
    if (!fs_mounted) return -1;

    // Load source file into temp buffer
    uint8_t *buf = (uint8_t *)0x900000;
    int size = fs_load_file(src, buf, 0x500000); // 5MB max
    if (size < 0) return -1;

    // Save to destination
    return fs_save_file(dst, buf, size);
}

int fs_file_size(const char *path) {
    // Quick hack: load file and count bytes
    // TODO: use fl_fstat or similar
    return -1;
}
