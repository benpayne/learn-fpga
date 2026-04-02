// retrokernel.h — User program API for RetroKernel
// Include this in programs loaded by the kernel to access syscalls
// (console I/O, file I/O, audio, etc.)

#ifndef RETROKERNEL_H
#define RETROKERNEL_H

#include <femtorv32.h>

// Undefine FAT library macros that conflict with our syscall names
#undef fopen
#undef fclose
#undef fread
#undef fwrite
#undef fseek
#undef mkdir
#undef remove

// Syscall table lives at this fixed address, set up by the kernel
#define SYSCALL_TABLE   0x80FE00

typedef struct {
    // Console (0-7)
    void (*putc)(char c);
    char (*getc)(void);
    void (*puts)(const char *s);
    void (*set_fg)(int color);
    void (*set_bg)(int color);
    void (*cls)(void);
    void (*putdec)(uint32_t v);
    void (*puthex8)(uint8_t v);

    // File I/O (8-15)
    int  (*fopen)(const char *path, const char *mode);
    void (*fclose)(int fd);
    int  (*fread)(int fd, void *buf, int size);
    int  (*fwrite)(int fd, const void *buf, int size);
    int  (*fseek)(int fd, int offset, int whence);
    int  (*load_file)(const char *path, void *dest, uint32_t max);
    int  (*save_file)(const char *path, const void *data, uint32_t size);
    int  (*list_dir)(const char *path);

    // Directory (16-19)
    int  (*chdir)(const char *path);
    const char *(*getcwd)(void);
    uint16_t (*getkey)(void);    // keycode<<8 | ascii
    void *reserved19;

    // Audio (20-23)
    void *note_on;
    void *note_off;
    void *set_instr;
    void *all_off;
} rk_syscall_table_t;

// Convenience macro — get the syscall table pointer
#define RK  ((rk_syscall_table_t *)SYSCALL_TABLE)

// ---- Console shortcuts ----
#define rk_putc(c)       RK->putc(c)
#define rk_getc()        RK->getc()
#define rk_puts(s)       RK->puts(s)
#define rk_set_fg(c)     RK->set_fg(c)
#define rk_set_bg(c)     RK->set_bg(c)
#define rk_cls()         RK->cls()
#define rk_putdec(v)     RK->putdec(v)
#define rk_puthex8(v)    RK->puthex8(v)

// ---- File I/O shortcuts ----
#define rk_fopen(p,m)    RK->fopen(p,m)
#define rk_fclose(fd)    RK->fclose(fd)
#define rk_fread(fd,b,s) RK->fread(fd,b,s)
#define rk_fwrite(fd,b,s) RK->fwrite(fd,b,s)
#define rk_fseek(fd,o,w) RK->fseek(fd,o,w)
#define rk_load_file(p,d,m) RK->load_file(p,d,m)
#define rk_save_file(p,d,s) RK->save_file(p,d,s)
#define rk_list_dir(p)   RK->list_dir(p)

// ---- Directory shortcuts ----
#define rk_chdir(p)      RK->chdir(p)
#define rk_getcwd()      RK->getcwd()

// ---- Key input ----
#define rk_getkey()      RK->getkey()
// Returns: keycode<<8 | ascii
// Normal keys: high byte=0, low byte=ascii
// Special keys: high byte=PS2_KEY_*, low byte=0
#define RK_KEY_UP     0x90
#define RK_KEY_DOWN   0x91
#define RK_KEY_LEFT   0x92
#define RK_KEY_RIGHT  0x93
#define RK_KEY_HOME   0x94
#define RK_KEY_END    0x95
#define RK_KEY_PGUP   0x96
#define RK_KEY_PGDN   0x97
#define RK_KEY_DELETE 0x99

#endif // RETROKERNEL_H
