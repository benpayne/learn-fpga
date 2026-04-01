// args.c - Test program for argc/argv support
// Usage: args foo bar baz
// Should print each argument

#include <femtorv32.h>

static inline void gpu_putc(char c) { GPU_WRITE(GPU_REG_CHAR_DATA, c); }
static inline void gpu_set_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }

static void out_puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            gpu_putc('\r'); gpu_putc('\n');
            putchar('\r'); putchar('\n');
        } else {
            gpu_putc(*s); putchar(*s);
        }
        s++;
    }
}

static void out_dec(int v) {
    char buf[11];
    int pos = 0;
    if (v == 0) { gpu_putc('0'); putchar('0'); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    while (pos > 0) { gpu_putc(buf[pos-1]); putchar(buf[pos-1]); pos--; }
}

int main(int argc, char **argv) {
    gpu_set_fg(GPU_BRIGHT_CYAN);
    out_puts("argc = ");
    out_dec(argc);
    out_puts("\n");

    gpu_set_fg(GPU_WHITE);
    for (int i = 0; i < argc; i++) {
        out_puts("  argv[");
        out_dec(i);
        out_puts("] = \"");
        gpu_set_fg(GPU_BRIGHT_GREEN);
        out_puts(argv[i]);
        gpu_set_fg(GPU_WHITE);
        out_puts("\"\n");
    }

    return 0;
}
