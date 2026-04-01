#ifndef KERNEL_H
#define KERNEL_H

#include <femtorv32.h>

// ---- Memory layout ----
#define KERNEL_BASE     0x800000
#define KERNEL_SIZE     0x010000   // 64KB for kernel
#define PROGRAM_BASE    0x810000   // Programs load here
#define PROGRAM_MAX     0xF00000   // ~7MB for programs
#define STACK_TOP       0xFFFFF0   // Stack starts here

// Argument passing area (last 256 bytes of kernel space)
// Layout: [argc (4B)] [argv[0] ptr] [argv[1] ptr] ... [argv[n]=NULL] [string data...]
#define ARGS_BASE       0x80FF00   // 256 bytes for argument strings + pointers
#define ARGS_MAX_SIZE   256

// Syscall table — function pointer array at fixed address
// User programs call these via: ((syscall_table_t *)SYSCALL_TABLE)->func(args)
#define SYSCALL_TABLE   0x80FE00   // 256 bytes = 64 function pointers

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

// Backspace: move cursor left, write space, move left again
static inline void con_backspace(void) {
    // Read current cursor col, move back, overwrite with space, move back
    // GPU doesn't handle 0x08 as backspace — must use cursor register
    uint32_t col = GPU_READ(GPU_REG_CURSOR_COL);
    if (col > 0) {
        GPU_WRITE(GPU_REG_CURSOR_COL, col - 1);
        GPU_WRITE(GPU_REG_CHAR_DATA, ' ');
        GPU_WRITE(GPU_REG_CURSOR_COL, col - 1);
    }
    // Also send backspace to UART
    putchar('\b'); putchar(' '); putchar('\b');
}

// Hex output
static inline void con_hex8(uint8_t v) {
    int hi = (v >> 4) & 0xF, lo = v & 0xF;
    con_putc(hi < 10 ? '0' + hi : 'a' + hi - 10);
    con_putc(lo < 10 ? '0' + lo : 'a' + lo - 10);
}

// Decimal output
void con_dec(uint32_t v);

// ---- Syscall table layout ----
// Each entry is a function pointer. User programs call through this table.
typedef struct {
    // Console (0-7)
    void (*putc)(char c);                                   // 0
    char (*getc)(void);                                     // 1
    void (*puts)(const char *s);                            // 2
    void (*set_fg)(int color);                              // 3
    void (*set_bg)(int color);                              // 4
    void (*cls)(void);                                      // 5
    void (*putdec)(uint32_t v);                             // 6
    void (*puthex8)(uint8_t v);                             // 7

    // File I/O (8-15)
    int  (*fopen)(const char *path, const char *mode);      // 8  returns fd
    void (*fclose)(int fd);                                 // 9
    int  (*fread)(int fd, void *buf, int size);             // 10
    int  (*fwrite)(int fd, const void *buf, int size);      // 11
    int  (*fseek)(int fd, int offset, int whence);          // 12
    int  (*load_file)(const char *path, void *dest, uint32_t max); // 13
    int  (*save_file)(const char *path, const void *data, uint32_t size); // 14
    int  (*list_dir)(const char *path);                     // 15

    // Directory (16-19)
    int  (*chdir)(const char *path);                        // 16
    const char *(*getcwd)(void);                            // 17
    uint16_t (*getkey)(void);                               // 18 keycode<<8|ascii
    void *reserved19;                                       // 19

    // Audio (20-23)
    void *note_on;                                          // 20
    void *note_off;                                         // 21
    void *set_instr;                                        // 22
    void *all_off;                                          // 23
} syscall_table_t;

// ---- Functions ----
// os_main.c
void kernel_init(void);

// os_shell.c
void shell_loop(void);
void shell_exec(const char *line);
void shell_run_script(const char *path);
char get_char(void);      // Blocking read — ASCII only (PS2 + UART)
uint16_t get_key(void);   // Blocking read — returns keycode<<8 | ascii

// os_file.c
int  fs_init(void);
int  fs_list_dir(const char *path);
int  fs_chdir(const char *path);
const char *fs_getcwd(void);
int  fs_load_file(const char *path, void *dest, uint32_t max_size);
int  fs_save_file(const char *path, const void *data, uint32_t size);
int  fs_mkdir(const char *path);
int  fs_remove(const char *path);
int  fs_copy(const char *src, const char *dst);
int  fs_file_size(const char *path);

// os_syscall.c
void syscall_init(void);

// os_loader.c
int  load_and_run(const char *path, const char *args);

#endif
