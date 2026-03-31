// RetroKernel - Shell / Command Interpreter

#include "kernel.h"
#include "ps2_keymap.h"

// ---- Input ----

static volatile int ps2_char_ready = 0;
static volatile char ps2_char_buf;
static ps2_state_t ps2;

static void irq_entry(void) __attribute__ ((interrupt ("machine")));
void irq_entry(void) {
    uint32_t flags = IO_IN(IO_INT_CONTROLLER);
    if (flags & (1 << INT_PS2_bit)) {
        uint32_t ps2_reg = IO_IN(IO_PS2);
        ps2_event_t ev = ps2_process_scancode(&ps2, ps2_reg & 0xFF);
        if (ev.type == PS2_EVENT_PRESS && ev.ascii != 0) {
            ps2_char_buf = ev.ascii;
            ps2_char_ready = 1;
        }
        CLEAR_INT(INT_PS2_bit);
    }
}

static char get_char(void) {
    while (1) {
        if (ps2_char_ready) {
            ps2_char_ready = 0;
            return ps2_char_buf;
        }
        uint32_t uart = IO_IN(IO_UART_DAT);
        if (uart & 0x100) {
            char c = uart & 0xFF;
            if (c != '\n') return c;
        }
    }
}

static char input_buf[INPUT_BUF_SIZE];

static void read_line(void) {
    int pos = 0;
    while (pos < INPUT_BUF_SIZE - 1) {
        char c = get_char();
        if (c == '\r' || c == '\n') {
            con_putc('\n');
            break;
        } else if (c == '\b' || c == 0x7F) {
            if (pos > 0) {
                pos--;
                con_putc('\b'); con_putc(' '); con_putc('\b');
            }
        } else if (c == '\t') {
            // Tab completion could go here
        } else if (c >= 0x20 && c < 0x7F) {
            input_buf[pos++] = c;
            con_putc(c);
        }
    }
    input_buf[pos] = '\0';
}

// ---- String helpers ----

static int str_eq(const char *a, const char *b) {
    while (*a && *b) { if (*a++ != *b++) return 0; }
    return *a == *b;
}

static int str_starts(const char *s, const char *prefix) {
    while (*prefix) { if (*s++ != *prefix++) return 0; }
    return 1;
}

static const char *skip_spaces(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static int str_len(const char *s) {
    int n = 0;
    while (*s++) n++;
    return n;
}

// ---- Commands ----

static void cmd_help(void) {
    con_set_fg(GPU_BRIGHT_CYAN);
    con_puts("Commands:\n");
    con_set_fg(GPU_WHITE);
    con_puts("  ls [path]     List directory\n");
    con_puts("  cd <path>     Change directory\n");
    con_puts("  pwd           Print working directory\n");
    con_puts("  cat <file>    Display file contents\n");
    con_puts("  hexdump <f>   Hex dump file\n");
    con_puts("  mem           Memory info\n");
    con_puts("  clear         Clear screen\n");
    con_puts("  ver           Version info\n");
    con_puts("  help          This help\n");
    con_puts("  reboot        Reboot to BIOS\n");
    con_puts("  load <file>   Receive file via XMODEM to SD\n");
    con_set_fg(GPU_LIGHT_GRAY);
    con_puts("  <program>     Run .bin from SD card\n");
}

static void cmd_ver(void) {
    con_set_fg(GPU_BRIGHT_CYAN);
    con_puts("RetroKernel v0.1\n");
    con_set_fg(GPU_LIGHT_GRAY);
    con_puts("  CPU:    RV32IMFC @ 25MHz\n");
    con_puts("  ROM:    16KB BRAM\n");
    con_puts("  RAM:    8MB SDRAM (cached)\n");
    con_puts("  Video:  640x400 16-color text + 4BPP graphics\n");
    con_puts("  Audio:  4-voice FM synth + I2S\n");
    con_puts("  Storage: FAT32 SD card\n");
}

static void cmd_mem(void) {
    con_set_fg(GPU_BRIGHT_CYAN);
    con_puts("Memory:\n");
    con_set_fg(GPU_WHITE);
    con_puts("  ROM:     0x000000-0x003FFF (16KB)\n");
    con_puts("  Kernel:  0x800000-0x80FFFF (64KB)\n");
    con_puts("  Program: 0x810000-0xEFFFFF (~7MB)\n");
    con_puts("  Stack:   0xFFFFF0 downward\n");
}

static void cmd_ls(const char *args) {
    args = skip_spaces(args);
    if (*args)
        fs_list_dir(args);
    else
        fs_list_dir(".");
}

static void cmd_cd(const char *args) {
    args = skip_spaces(args);
    if (!*args) {
        fs_chdir("/");
    } else {
        if (!fs_chdir(args)) {
            con_set_fg(GPU_BRIGHT_RED);
            con_puts("cd: no such directory\n");
        }
    }
}

static void cmd_pwd(void) {
    con_puts(fs_getcwd());
    con_putc('\n');
}

static void cmd_cat(const char *args) {
    args = skip_spaces(args);
    if (!*args) {
        con_puts("usage: cat <file>\n");
        return;
    }

    // Load file into a temporary buffer in SDRAM
    uint8_t *buf = (uint8_t *)0x900000;  // Use high SDRAM area as temp
    int size = fs_load_file(args, buf, 0x100000);  // Max 1MB
    if (size < 0) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("cat: cannot open ");
        con_puts(args);
        con_putc('\n');
        return;
    }

    // Print contents
    for (int i = 0; i < size; i++) {
        if (buf[i] == '\r') continue;  // Skip CR
        con_putc(buf[i]);
    }
    // Ensure newline at end
    if (size > 0 && buf[size-1] != '\n')
        con_putc('\n');
}

static void cmd_hexdump(const char *args) {
    args = skip_spaces(args);
    if (!*args) {
        con_puts("usage: hexdump <file> [bytes]\n");
        return;
    }

    uint8_t *buf = (uint8_t *)0x900000;
    int size = fs_load_file(args, buf, 256);  // First 256 bytes
    if (size < 0) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("hexdump: cannot open ");
        con_puts(args);
        con_putc('\n');
        return;
    }

    int rows = (size + 15) / 16;
    if (rows > 16) rows = 16;
    for (int r = 0; r < rows; r++) {
        con_set_fg(GPU_CYAN);
        con_hex8(r * 16 >> 8); con_hex8((r * 16) & 0xFF);
        con_puts(": ");
        con_set_fg(GPU_LIGHT_GRAY);
        for (int c = 0; c < 16 && (r*16+c) < size; c++) {
            con_hex8(buf[r*16+c]);
            con_putc(' ');
        }
        con_set_fg(GPU_GREEN);
        for (int c = 0; c < 16 && (r*16+c) < size; c++) {
            uint8_t ch = buf[r*16+c];
            con_putc((ch >= 0x20 && ch < 0x7F) ? ch : '.');
        }
        con_putc('\n');
    }
}

static void cmd_load(const char *args) {
    args = skip_spaces(args);
    if (!*args) {
        con_puts("usage: load <filename>\n");
        con_puts("  Receives file via XMODEM and saves to SD card\n");
        return;
    }

    // Build full path
    char fullpath[MAX_PATH];
    int fp = 0;
    if (args[0] == '/') {
        while (args[fp] && fp < MAX_PATH - 1) { fullpath[fp] = args[fp]; fp++; }
    } else {
        const char *c = fs_getcwd();
        while (*c && fp < MAX_PATH - 1) fullpath[fp++] = *c++;
        if (fp > 0 && fullpath[fp-1] != '/') fullpath[fp++] = '/';
        int i = 0;
        while (args[i] && args[i] != ' ' && fp < MAX_PATH - 1) fullpath[fp++] = args[i++];
    }
    fullpath[fp] = '\0';

    // Receive via XMODEM into a buffer in high SDRAM
    uint8_t *buf = (uint8_t *)0xA00000;  // Temp buffer at 10MB mark
    uint32_t max_size = 0x500000;         // 5MB max

    con_set_fg(GPU_YELLOW);
    con_puts("XMODEM ready. Send file from host...\n");

    // Disable interrupts during XMODEM (PS2 ISR steals cycles)
    asm volatile ("csrci mstatus, 0x8");

    // XMODEM receive (simplified inline — reuse monitor's protocol)
    #define XMODEM_SOH 0x01
    #define XMODEM_EOT 0x04
    #define XMODEM_ACK 0x06
    #define XMODEM_NAK 0x15
    #define XMODEM_CAN 0x18

    // Send initial NAK
    IO_OUT(IO_UART_DAT, XMODEM_NAK);
    while (IO_IN(IO_UART_CNTL) & 0x200);

    uint8_t expected_pkt = 1;
    uint32_t total = 0;
    int retries = 0;
    int done = 0;

    while (!done) {
        // Wait for SOH or EOT
        int timeout = 5000000;
        int c = -1;
        while (timeout-- > 0) {
            uint32_t u = IO_IN(IO_UART_DAT);
            if (u & 0x100) { c = u & 0xFF; break; }
        }

        if (c < 0) {
            retries++;
            if (retries > 30) { con_puts("Timeout!\n"); break; }
            IO_OUT(IO_UART_DAT, XMODEM_NAK);
            while (IO_IN(IO_UART_CNTL) & 0x200);
            continue;
        }

        if (c == XMODEM_EOT) {
            IO_OUT(IO_UART_DAT, XMODEM_ACK);
            while (IO_IN(IO_UART_CNTL) & 0x200);
            done = 1;
            break;
        }

        if (c != XMODEM_SOH) {
            IO_OUT(IO_UART_DAT, XMODEM_NAK);
            while (IO_IN(IO_UART_CNTL) & 0x200);
            continue;
        }

        // Read packet
        int pkt = -1, cpl = -1;
        uint8_t data[128];
        uint8_t cs = 0;
        int ok = 1;

        // Pkt num
        timeout = 500000;
        while (timeout-- > 0) { uint32_t u = IO_IN(IO_UART_DAT); if (u & 0x100) { pkt = u & 0xFF; break; } }
        if (pkt < 0) { IO_OUT(IO_UART_DAT, XMODEM_NAK); while (IO_IN(IO_UART_CNTL) & 0x200); continue; }

        // Complement
        timeout = 500000;
        while (timeout-- > 0) { uint32_t u = IO_IN(IO_UART_DAT); if (u & 0x100) { cpl = u & 0xFF; break; } }
        if (cpl < 0 || (pkt + cpl) != 0xFF) { IO_OUT(IO_UART_DAT, XMODEM_NAK); while (IO_IN(IO_UART_CNTL) & 0x200); continue; }

        // 128 data bytes
        for (int i = 0; i < 128; i++) {
            timeout = 500000;
            int b = -1;
            while (timeout-- > 0) { uint32_t u = IO_IN(IO_UART_DAT); if (u & 0x100) { b = u & 0xFF; break; } }
            if (b < 0) { ok = 0; break; }
            data[i] = b;
            cs += b;
        }
        if (!ok) { IO_OUT(IO_UART_DAT, XMODEM_NAK); while (IO_IN(IO_UART_CNTL) & 0x200); continue; }

        // Checksum
        int rcs = -1;
        timeout = 500000;
        while (timeout-- > 0) { uint32_t u = IO_IN(IO_UART_DAT); if (u & 0x100) { rcs = u & 0xFF; break; } }
        if (rcs < 0 || (cs & 0xFF) != (rcs & 0xFF)) { IO_OUT(IO_UART_DAT, XMODEM_NAK); while (IO_IN(IO_UART_CNTL) & 0x200); continue; }

        if (pkt == expected_pkt && total + 128 <= max_size) {
            // Copy data to buffer (word writes for SDRAM)
            volatile uint32_t *dst = (volatile uint32_t *)(buf + total);
            for (int i = 0; i < 128; i += 4) {
                dst[i/4] = (uint32_t)data[i] | ((uint32_t)data[i+1]<<8) |
                           ((uint32_t)data[i+2]<<16) | ((uint32_t)data[i+3]<<24);
            }
            total += 128;
            expected_pkt = (expected_pkt + 1) & 0xFF;
            retries = 0;
        }

        IO_OUT(IO_UART_DAT, XMODEM_ACK);
        while (IO_IN(IO_UART_CNTL) & 0x200);
    }

    // Re-enable interrupts
    asm volatile ("csrsi mstatus, 0x8");

    if (!done || total == 0) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("Transfer failed\n");
        return;
    }

    con_set_fg(GPU_BRIGHT_GREEN);
    con_puts("Received ");
    con_dec(total);
    con_puts(" bytes\n");

    // Write to SD card
    con_puts("Saving to ");
    con_puts(fullpath);
    con_puts("...\n");

    // Use FAT library to write file
    extern void *fl_fopen(const char *path, const char *mode);
    extern int fl_fwrite(const void *buffer, int size, int count, void *file);
    extern void fl_fclose(void *file);

    void *f = fl_fopen(fullpath, "w");
    if (!f) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("Error: cannot create file\n");
        return;
    }

    fl_fwrite(buf, 1, total, f);
    fl_fclose(f);

    con_set_fg(GPU_BRIGHT_GREEN);
    con_puts("Saved OK\n");
}

static void cmd_clear(void) {
    con_clear();
}

// ---- Shell loop ----

void shell_loop(void) {
    // Set up PS2 keyboard interrupt
    ps2_init(&ps2);
    asm volatile ("csrw mtvec, %0" :: "r"(&irq_entry));
    asm volatile ("csrw mie, %0" :: "r"(0xFFFFFFFF));
    asm volatile ("csrsi mstatus, 0x8");

    con_set_fg(GPU_LIGHT_GRAY);
    con_puts("Type 'help' for commands\n\n");

    while (1) {
        // Prompt: show cwd
        con_set_fg(GPU_BRIGHT_GREEN);
        con_puts(fs_getcwd());
        con_puts("$ ");
        con_set_fg(GPU_WHITE);

        read_line();

        const char *cmd = skip_spaces(input_buf);
        if (*cmd == '\0') continue;

        // Parse command and arguments
        const char *args = cmd;
        while (*args && *args != ' ' && *args != '\t') args++;
        int cmd_len = args - cmd;

        // Match commands
        if (cmd_len == 4 && str_starts(cmd, "help")) {
            cmd_help();
        } else if (cmd_len == 2 && str_starts(cmd, "ls")) {
            cmd_ls(args);
        } else if (cmd_len == 2 && str_starts(cmd, "cd")) {
            cmd_cd(args);
        } else if (cmd_len == 3 && str_starts(cmd, "pwd")) {
            cmd_pwd();
        } else if (cmd_len == 3 && str_starts(cmd, "cat")) {
            cmd_cat(args);
        } else if (cmd_len == 7 && str_starts(cmd, "hexdump")) {
            cmd_hexdump(args);
        } else if (cmd_len == 3 && str_starts(cmd, "mem")) {
            cmd_mem();
        } else if (cmd_len == 4 && str_starts(cmd, "load")) {
            cmd_load(args);
        } else if (cmd_len == 5 && str_starts(cmd, "clear")) {
            cmd_clear();
        } else if (cmd_len == 3 && str_starts(cmd, "ver")) {
            cmd_ver();
        } else if (cmd_len == 6 && str_starts(cmd, "reboot")) {
            con_puts("Rebooting...\n");
            // Jump to address 0 (BIOS reset)
            void (*reset)(void) = (void (*)(void))0;
            reset();
        } else {
            // Try to run as a program
            if (!load_and_run(cmd, args)) {
                con_set_fg(GPU_BRIGHT_RED);
                con_puts("unknown command: ");
                // Print just the command part
                for (int i = 0; i < cmd_len; i++) con_putc(cmd[i]);
                con_putc('\n');
            }
        }
    }
}
