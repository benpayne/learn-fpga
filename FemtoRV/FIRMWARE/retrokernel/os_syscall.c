// RetroKernel - Syscall table
// Provides function pointer table at SYSCALL_TABLE for user programs

#include "kernel.h"
#include "fat_io_lib/fat_filelib.h"

// ---- File descriptor table ----
// Maps small integer fds to FAT library file pointers
static void *fd_table[MAX_OPEN_FILES];

static void fd_init(void) {
    for (int i = 0; i < MAX_OPEN_FILES; i++)
        fd_table[i] = 0;
}

static int fd_alloc(void *fp) {
    for (int i = 0; i < MAX_OPEN_FILES; i++) {
        if (!fd_table[i]) {
            fd_table[i] = fp;
            return i;
        }
    }
    return -1;
}

// ---- Syscall wrappers ----

// get_char is defined in os_shell.c — reads from both PS2 (via ISR) and UART

static int sys_fopen(const char *path, const char *mode) {
    // Build full path relative to cwd
    char fullpath[MAX_PATH];
    int fp = 0;

    if (path[0] == '/') {
        while (path[fp] && fp < MAX_PATH - 1) { fullpath[fp] = path[fp]; fp++; }
    } else {
        const char *cwd = fs_getcwd();
        int i = 0;
        while (cwd[i] && fp < MAX_PATH - 1) fullpath[fp++] = cwd[i++];
        if (fp > 0 && fullpath[fp-1] != '/') fullpath[fp++] = '/';
        i = 0;
        while (path[i] && fp < MAX_PATH - 1) fullpath[fp++] = path[i++];
    }
    fullpath[fp] = '\0';

    void *f = fl_fopen(fullpath, mode);
    if (!f) return -1;

    int fd = fd_alloc(f);
    if (fd < 0) {
        fl_fclose(f);
        return -1;
    }
    return fd;
}

static void sys_fclose(int fd) {
    if (fd < 0 || fd >= MAX_OPEN_FILES || !fd_table[fd]) return;
    fl_fclose(fd_table[fd]);
    fd_table[fd] = 0;
}

static int sys_fread(int fd, void *buf, int size) {
    if (fd < 0 || fd >= MAX_OPEN_FILES || !fd_table[fd]) return -1;
    return fl_fread(buf, 1, size, fd_table[fd]);
}

static int sys_fwrite(int fd, const void *buf, int size) {
    if (fd < 0 || fd >= MAX_OPEN_FILES || !fd_table[fd]) return -1;
    return fl_fwrite(buf, 1, size, fd_table[fd]);
}

static int sys_fseek(int fd, int offset, int whence) {
    if (fd < 0 || fd >= MAX_OPEN_FILES || !fd_table[fd]) return -1;
    return fl_fseek(fd_table[fd], offset, whence);
}

// ---- Table setup ----

void syscall_init(void) {
    fd_init();

    volatile syscall_table_t *tbl = (volatile syscall_table_t *)SYSCALL_TABLE;

    // Console
    tbl->putc    = con_putc;
    tbl->getc    = get_char;
    tbl->puts    = con_puts;
    tbl->set_fg  = con_set_fg;
    tbl->set_bg  = con_set_bg;
    tbl->cls     = con_clear;
    tbl->putdec  = con_dec;
    tbl->puthex8 = con_hex8;

    // File I/O
    tbl->fopen     = sys_fopen;
    tbl->fclose    = sys_fclose;
    tbl->fread     = sys_fread;
    tbl->fwrite    = sys_fwrite;
    tbl->fseek     = sys_fseek;
    tbl->load_file = fs_load_file;
    tbl->save_file = fs_save_file;
    tbl->list_dir  = fs_list_dir;

    // Directory
    tbl->chdir  = fs_chdir;
    tbl->getcwd = fs_getcwd;
    tbl->getkey = get_key;
}
