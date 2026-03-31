#ifndef KERNEL_H
#define KERNEL_H

#include <femtorv32.h>

// ---- Memory layout ----
#define KERNEL_BASE     0x800000
#define KERNEL_SIZE     0x010000   // 64KB for kernel
#define PROGRAM_BASE    0x810000   // Programs load here
#define PROGRAM_MAX     0xF00000   // ~7MB for programs
#define STACK_TOP       0xFFFFF0   // Stack starts here

// ---- Syscall numbers ----
// Process
#define SYS_EXIT        0x00
#define SYS_EXEC        0x01

// Console
#define SYS_PUTCHAR     0x10
#define SYS_GETCHAR     0x11
#define SYS_PUTS        0x12
#define SYS_GETS        0x13
#define SYS_KBHIT       0x14
#define SYS_SET_COLOR   0x15
#define SYS_CLS         0x16
#define SYS_SET_CURSOR  0x17

// File I/O
#define SYS_OPEN        0x20
#define SYS_CLOSE       0x21
#define SYS_READ        0x22
#define SYS_WRITE       0x23
#define SYS_SEEK        0x24
#define SYS_OPENDIR     0x26
#define SYS_READDIR     0x27
#define SYS_CLOSEDIR    0x28
#define SYS_CHDIR       0x29
#define SYS_GETCWD      0x2A
#define SYS_UNLINK      0x2B

// Memory
#define SYS_MALLOC      0x30
#define SYS_FREE        0x31
#define SYS_MEMINFO     0x32

// Audio
#define SYS_NOTE_ON     0x40
#define SYS_NOTE_OFF    0x41
#define SYS_SET_INSTR   0x42
#define SYS_ALL_OFF     0x43

// Timer
#define SYS_TICKS       0x60
#define SYS_DELAY       0x61

// ---- Directory entry ----
struct dirent {
    char     name[13];   // 8.3 null-terminated
    uint8_t  is_dir;     // 1 if directory
    uint32_t size;       // File size in bytes
};

// ---- Kernel state ----
#define MAX_OPEN_FILES  8
#define MAX_PATH        128
#define INPUT_BUF_SIZE  128

// ---- Console helpers (BIOS calls) ----
// These call through to the BIOS/hardware directly since we ARE the kernel

static inline void con_putc(char c) {
    if (c == '\n') {
        // CR before LF on GPU (scroll timing issue)
        GPU_WRITE(GPU_REG_CHAR_DATA, '\r');
        GPU_WRITE(GPU_REG_CHAR_DATA, '\n');
        putchar('\r');
        putchar('\n');
    } else {
        GPU_WRITE(GPU_REG_CHAR_DATA, c);
        putchar(c);
    }
}

static inline void con_puts(const char *s) {
    while (*s) { con_putc(*s); s++; }
}

static inline void con_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }
static inline void con_set_bg(int c) { GPU_WRITE(GPU_REG_BG_COLOR, c); }

static inline void con_clear(void) {
    GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN | GPU_CTRL_80COL);
    wait_cycles(5000);
}

// Hex output
static inline void con_hex8(uint8_t v) {
    int hi = (v >> 4) & 0xF, lo = v & 0xF;
    con_putc(hi < 10 ? '0' + hi : 'a' + hi - 10);
    con_putc(lo < 10 ? '0' + lo : 'a' + lo - 10);
}

// Decimal output
void con_dec(uint32_t v);

// ---- Functions ----
// os_main.c
void kernel_init(void);

// os_shell.c
void shell_loop(void);

// os_file.c
int  fs_init(void);
int  fs_list_dir(const char *path);
int  fs_chdir(const char *path);
const char *fs_getcwd(void);
int  fs_load_file(const char *path, void *dest, uint32_t max_size);
int  fs_file_size(const char *path);

// os_loader.c
int  load_and_run(const char *path, const char *args);

#endif
