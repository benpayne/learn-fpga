//
// monitor.c - FemtoRV ROM Monitor with XMODEM Loader
//
// Features:
//   - HDMI display as primary console (per-character 16-color text)
//   - 80-column default, F5 toggles 40/80 mode
//   - PS2 keyboard input with interrupt-driven decoder
//   - UART serial I/O (115200 baud)
//   - XMODEM binary upload via serial
//   - Memory examine, deposit, and dump
//   - Execute loaded programs
//   - Dual output: HDMI + UART simultaneously
//
// Commands:
//   H          - Help (show commands)
//   D <addr>   - Dump 128 bytes from address
//   E <addr>   - Examine byte at address
//   S <addr> <val> - Store byte at address
//   L [addr]   - Load binary via XMODEM (default: 0x4000)
//   G [addr]   - Go (execute) at address (default: 0x4000)
//   C          - Clear screen
//   M          - Memory info
//   F5 key     - Toggle 40/80 column mode
//

#include <femtorv32.h>
#include "ps2_keymap.h"

// ----- Constants -----

#define DEFAULT_LOAD_ADDR  0x4000    // Default load address (16KB, above monitor code)
#define INPUT_BUF_SIZE     80

// XMODEM protocol constants
#define XMODEM_SOH  0x01
#define XMODEM_EOT  0x04
#define XMODEM_ACK  0x06
#define XMODEM_NAK  0x15
#define XMODEM_CAN  0x18

// ----- Display state -----

static int mode_80col = 1;  // Default to 80-column mode

// Forward declarations
static void toggle_mode(void);
static void show_banner(void);

// ----- GPU helpers -----

static inline void gpu_putc(char c) {
    GPU_WRITE(GPU_REG_CHAR_DATA, c);
}

static inline void gpu_set_cursor(int row, int col) {
    GPU_WRITE(GPU_REG_CURSOR_ROW, row);
    GPU_WRITE(GPU_REG_CURSOR_COL, col);
}

static inline void gpu_set_fg(int color) {
    GPU_WRITE(GPU_REG_FG_COLOR, color);
}

static inline void gpu_set_bg(int color) {
    GPU_WRITE(GPU_REG_BG_COLOR, color);
}

static inline void gpu_clear(void) {
    GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CLEAR | GPU_CTRL_CURSOR_EN |
              (mode_80col ? GPU_CTRL_80COL : 0));
    wait_cycles(5000);  // Wait for clear state machine (2400 cycles for 80-col)
}

static void gpu_set_mode(int wide) {
    mode_80col = wide;
    GPU_WRITE(GPU_REG_CONTROL, GPU_CTRL_CURSOR_EN |
              (mode_80col ? GPU_CTRL_80COL : 0));
    wait_cycles(5000);
}

// Print string to GPU only
static void gpu_puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            gpu_putc('\r');  // CR before LF (see mon_putc comment)
            gpu_putc('\n');
        } else {
            gpu_putc(*s);
        }
        s++;
    }
}

// Print to both GPU and UART
// The UART now has a hardware holding register, so back-to-back writes
// are safe. putchar() calls UART_putchar which does write-then-wait-busy.
static void mon_putc(char c) {
    if (c == '\n') {
        // Send CR *before* LF to GPU (see scroll timing note)
        gpu_putc('\r');
        gpu_putc('\n');
        putchar('\r');
        putchar('\n');
    } else {
        gpu_putc(c);
        putchar(c);
    }
}

static void mon_puts(const char *s) {
    while (*s) {
        mon_putc(*s);
        s++;
    }
}

// Print hex nibble
static void mon_hex_nibble(uint8_t n) {
    n &= 0xF;
    mon_putc(n < 10 ? '0' + n : 'A' + n - 10);
}

static void mon_hex_byte(uint8_t b) {
    mon_hex_nibble(b >> 4);
    mon_hex_nibble(b);
}

static void mon_hex_word(uint32_t w) {
    mon_hex_byte((w >> 24) & 0xFF);
    mon_hex_byte((w >> 16) & 0xFF);
    mon_hex_byte((w >> 8) & 0xFF);
    mon_hex_byte(w & 0xFF);
}

static void mon_hex_half(uint16_t w) {
    mon_hex_byte((w >> 8) & 0xFF);
    mon_hex_byte(w & 0xFF);
}

// ----- PS2 keyboard input -----

#define PS2_QUEUE_SIZE 16
static volatile char ps2_queue[PS2_QUEUE_SIZE];
static volatile int ps2_queue_head = 0;
static volatile int ps2_queue_tail = 0;
static volatile int ps2_f5_pressed = 0;  // Flag for mode toggle
static ps2_state_t ps2;

static void irq_entry(void) __attribute__ ((interrupt ("machine")));

void irq_entry(void) {
    uint32_t flags = IO_IN(IO_INT_CONTROLLER);

    if (flags & (1 << INT_PS2_bit)) {
        uint32_t ps2_reg = IO_IN(IO_PS2);
        uint8_t scancode = ps2_reg & 0xFF;
        ps2_event_t ev = ps2_process_scancode(&ps2, scancode);

        if (ev.type == PS2_EVENT_PRESS) {
            if (ev.keycode == PS2_KEY_F5) {
                ps2_f5_pressed = 1;
            } else if (ev.ascii != 0) {
                int next = (ps2_queue_head + 1) % PS2_QUEUE_SIZE;
                if (next != ps2_queue_tail) {
                    ps2_queue[ps2_queue_head] = ev.ascii;
                    ps2_queue_head = next;
                }
            }
        }
        CLEAR_INT(INT_PS2_bit);
    }
}

static int ps2_has_char(void) {
    return ps2_queue_head != ps2_queue_tail;
}

static char ps2_get_char(void) {
    char c = ps2_queue[ps2_queue_tail];
    ps2_queue_tail = (ps2_queue_tail + 1) % PS2_QUEUE_SIZE;
    return c;
}

// Get character from PS2 or UART (whichever comes first)
// Also handles F5 mode toggle
static char mon_getc(void) {
    while (1) {
        // Check F5 toggle
        if (ps2_f5_pressed) {
            ps2_f5_pressed = 0;
            toggle_mode();
        }
        // Check PS2 queue
        if (ps2_has_char()) {
            return ps2_get_char();
        }
        // Check UART (non-blocking)
        uint32_t uart = IO_IN(IO_UART_DAT);
        if (uart & 0x100) {
            char c = uart & 0xFF;
            if (c != '\n') return c;
        }
    }
}

// Get character from UART only, with timeout
static int uart_getc_timeout(int timeout_cycles) {
    for (volatile int i = 0; i < timeout_cycles; i++) {
        uint32_t uart = IO_IN(IO_UART_DAT);
        if (uart & 0x100) {
            return uart & 0xFF;
        }
    }
    return -1;
}

// Send byte to UART only (for XMODEM protocol)
// Uses direct IO to avoid putchar's \n conversion
extern int UART_putchar(int);
static void uart_putc(uint8_t c) {
    UART_putchar(c);
}

// ----- Hex input parsing -----

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex(const char *s, uint32_t *result) {
    uint32_t val = 0;
    int count = 0;
    while (*s) {
        int d = hex_digit(*s);
        if (d < 0) break;
        val = (val << 4) | d;
        s++;
        count++;
    }
    if (count == 0) return 0;
    *result = val;
    return count;
}

static const char *skip_spaces(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

// ----- Command line input -----

static char input_buf[INPUT_BUF_SIZE];

static void read_line(void) {
    int pos = 0;
    while (pos < INPUT_BUF_SIZE - 1) {
        char c = mon_getc();

        if (c == '\r' || c == '\n') {
            mon_putc('\n');
            break;
        } else if (c == '\b' || c == 0x7F) {
            if (pos > 0) {
                pos--;
                mon_putc('\b');
                mon_putc(' ');
                mon_putc('\b');
            }
        } else if (c >= 0x20 && c < 0x7F) {
            input_buf[pos++] = c;
            mon_putc(c);
        }
    }
    input_buf[pos] = '\0';
}

// ----- XMODEM receiver -----

static int xmodem_receive(uint32_t load_addr) {
    uint8_t expected_pkt = 1;
    uint32_t addr = load_addr;
    int retries = 0;
    int total_bytes = 0;

    gpu_set_fg(GPU_YELLOW);
    mon_puts("XMODEM ready. Start transfer from host...\n");

    // Disable interrupts during XMODEM - the PS2 ISR can steal
    // CPU cycles and cause UART RX byte loss
    asm volatile ("csrci mstatus, 0x8");
    gpu_set_fg(GPU_LIGHT_GRAY);

    uart_putc(XMODEM_NAK);

    while (1) {
        int c = uart_getc_timeout(2500000);

        if (c < 0) {
            retries++;
            if (retries > 30) {
                asm volatile ("csrsi mstatus, 0x8");
                gpu_set_fg(GPU_BRIGHT_RED);
                mon_puts("Transfer timeout!\n");
                return -1;
            }
            uart_putc(XMODEM_NAK);
            continue;
        }

        if (c == XMODEM_EOT) {
            uart_putc(XMODEM_ACK);
            asm volatile ("csrsi mstatus, 0x8");
            gpu_set_fg(GPU_BRIGHT_GREEN);
            mon_puts("\nTransfer complete: ");
            mon_hex_word(total_bytes);
            mon_puts(" bytes at ");
            mon_hex_word(load_addr);
            mon_putc('\n');
            return total_bytes;
        }

        if (c == XMODEM_CAN) {
            asm volatile ("csrsi mstatus, 0x8");
            gpu_set_fg(GPU_BRIGHT_RED);
            mon_puts("Cancelled by sender\n");
            return -1;
        }

        if (c != XMODEM_SOH) {
            retries++;
            if (retries > 10) {
                uart_putc(XMODEM_CAN);
                asm volatile ("csrsi mstatus, 0x8");
                gpu_set_fg(GPU_BRIGHT_RED);
                mon_puts("Too many errors!\n");
                return -1;
            }
            uart_putc(XMODEM_NAK);
            continue;
        }

        int pkt_num = uart_getc_timeout(500000);
        if (pkt_num < 0) { gpu_putc('a'); uart_putc(XMODEM_NAK); continue; }

        int pkt_cpl = uart_getc_timeout(500000);
        if (pkt_cpl < 0) { gpu_putc('b'); uart_putc(XMODEM_NAK); continue; }

        if ((pkt_num + pkt_cpl) != 0xFF) {
            gpu_putc('c');
            uart_putc(XMODEM_NAK);
            continue;
        }

        uint8_t checksum = 0;
        uint8_t data[128];
        int ok = 1;
        int i;
        // Read 128 data bytes with tight inline polling
        for (i = 0; i < 128; i++) {
            uint32_t uart;
            int timeout = 5000000;  // ~1 second
            do {
                uart = IO_IN(IO_UART_DAT);
                if (uart & 0x100) goto got_byte;
            } while (--timeout > 0);
            ok = 0;
            break;
          got_byte:
            data[i] = uart & 0xFF;
            checksum += data[i];
        }
        if (!ok) {
            gpu_putc('d');
            // Show how many bytes we got before timeout
            gpu_putc('0' + (i / 100) % 10);
            gpu_putc('0' + (i / 10) % 10);
            gpu_putc('0' + i % 10);
            uart_putc(XMODEM_NAK);
            continue;
        }

        int recv_checksum = uart_getc_timeout(500000);
        if (recv_checksum < 0) { gpu_putc('e'); uart_putc(XMODEM_NAK); continue; }

        if ((checksum & 0xFF) != (recv_checksum & 0xFF)) {
            gpu_putc('f');
            uart_putc(XMODEM_NAK);
            continue;
        }

        if (pkt_num == expected_pkt) {
            volatile uint8_t *dest = (volatile uint8_t *)addr;
            for (int i = 0; i < 128; i++) {
                dest[i] = data[i];
            }
            addr += 128;
            total_bytes += 128;
            expected_pkt = (expected_pkt + 1) & 0xFF;
            retries = 0;
            gpu_putc('.');  // GPU only - don't send to UART during XMODEM
        }

        uart_putc(XMODEM_ACK);
    }
}

// ----- Banner and mode toggle -----

static void show_banner(void) {
    gpu_clear();
    gpu_set_fg(GPU_BRIGHT_CYAN);
    gpu_set_bg(GPU_BLACK);

    if (mode_80col) {
        mon_puts("===============================================================================\n");
        mon_puts("  FemtoRV Monitor v1.0 | RV32IMFC @ 25MHz | 64KB RAM | UART 115200 | F5=40/80\n");
        mon_puts("===============================================================================\n");
    } else {
        mon_puts("========================================\n");
        mon_puts("  FemtoRV Monitor v1.0\n");
        mon_puts("  RV32IMFC 25MHz 64KB | F5=40/80\n");
        mon_puts("========================================\n");
    }

    gpu_set_fg(GPU_LIGHT_GRAY);
    mon_puts("Type H for help\n");
}

static void toggle_mode(void) {
    mode_80col = !mode_80col;
    gpu_set_mode(mode_80col);
    show_banner();
    // Print prompt after banner
    gpu_set_fg(GPU_BRIGHT_GREEN);
    gpu_putc('>');
    gpu_putc(' ');
    gpu_set_fg(GPU_WHITE);
}

// ----- Monitor commands -----

static void cmd_help(void) {
    gpu_set_fg(GPU_BRIGHT_CYAN);
    mon_puts("Commands:\n");
    gpu_set_fg(GPU_WHITE);
    mon_puts("  H            Help\n");
    mon_puts("  D <addr>     Dump 128 bytes\n");
    mon_puts("  E <addr>     Examine byte\n");
    mon_puts("  S <a> <v>    Store byte\n");
    mon_puts("  L [addr]     Load via XMODEM (default 4000)\n");
    mon_puts("  G [addr]     Go/execute (default 4000)\n");
    mon_puts("  C            Clear screen\n");
    mon_puts("  M            Memory info\n");
    gpu_set_fg(GPU_LIGHT_GRAY);
    mon_puts("  F5           Toggle 40/80 column mode\n");
}

static void cmd_dump(const char *args) {
    uint32_t addr = 0;
    args = skip_spaces(args);
    if (!parse_hex(args, &addr)) {
        mon_puts("Usage: D <addr>\n");
        return;
    }

    volatile uint8_t *p = (volatile uint8_t *)addr;
    for (int row = 0; row < 8; row++) {
        gpu_set_fg(GPU_CYAN);
        mon_hex_half((addr + row * 16) & 0xFFFF);
        mon_puts(": ");
        gpu_set_fg(GPU_LIGHT_GRAY);

        for (int col = 0; col < 16; col++) {
            mon_hex_byte(p[row * 16 + col]);
            mon_putc(' ');
        }

        gpu_set_fg(GPU_GREEN);
        for (int col = 0; col < 16; col++) {
            uint8_t c = p[row * 16 + col];
            mon_putc((c >= 0x20 && c < 0x7F) ? c : '.');
        }
        mon_putc('\n');
    }
}

static void cmd_examine(const char *args) {
    uint32_t addr = 0;
    args = skip_spaces(args);
    if (!parse_hex(args, &addr)) {
        mon_puts("Usage: E <addr>\n");
        return;
    }

    volatile uint8_t *p = (volatile uint8_t *)addr;
    gpu_set_fg(GPU_CYAN);
    mon_hex_half(addr & 0xFFFF);
    mon_puts(": ");
    gpu_set_fg(GPU_WHITE);
    mon_hex_byte(*p);
    mon_putc('\n');
}

static void cmd_store(const char *args) {
    uint32_t addr = 0, val = 0;
    args = skip_spaces(args);
    int n = parse_hex(args, &addr);
    if (!n) { mon_puts("Usage: S <addr> <val>\n"); return; }

    args = skip_spaces(args + n);
    if (!parse_hex(args, &val)) { mon_puts("Usage: S <addr> <val>\n"); return; }

    volatile uint8_t *p = (volatile uint8_t *)addr;
    *p = val & 0xFF;
    mon_puts("OK\n");
}

static void cmd_load(const char *args) {
    uint32_t addr = DEFAULT_LOAD_ADDR;
    args = skip_spaces(args);
    if (*args) parse_hex(args, &addr);

    mon_puts("Load to ");
    mon_hex_word(addr);
    mon_putc('\n');

    int result = xmodem_receive(addr);
    if (result < 0) {
        gpu_set_fg(GPU_BRIGHT_RED);
        mon_puts("Load failed\n");
    }
}

static void cmd_go(const char *args) {
    uint32_t addr = DEFAULT_LOAD_ADDR;
    args = skip_spaces(args);
    if (*args) parse_hex(args, &addr);

    mon_puts("Jump to ");
    mon_hex_word(addr);
    mon_putc('\n');

    void (*entry)(void) = (void (*)(void))addr;
    entry();

    gpu_set_fg(GPU_BRIGHT_GREEN);
    mon_puts("Returned from program\n");
}

static void cmd_meminfo(void) {
    gpu_set_fg(GPU_BRIGHT_CYAN);
    mon_puts("Memory:\n");
    gpu_set_fg(GPU_WHITE);
    mon_puts("  RAM:   64KB (0x0000-0xFFFF)\n");
    mon_puts("  Mon:   0x0000-0x3FFF (16KB)\n");
    mon_puts("  User:  0x4000-0xBFFF (32KB)\n");
    mon_puts("  Stack: 0xFFFF downward\n");
    mon_puts("  IO:    0x400000+\n");
    mon_puts("  CPU:   RV32IMFC @ 25MHz\n");

    gpu_set_fg(GPU_LIGHT_GRAY);
    mon_puts("  Mode:  ");
    mon_puts(mode_80col ? "80" : "40");
    mon_puts("-col, 25 rows, 16 colors\n");
}

// ----- Main -----

int main(void) {
    ps2_init(&ps2);

    // Enable interrupts
    asm volatile ("csrw mtvec, %0" :: "r"(&irq_entry));
    asm volatile ("csrw mie, %0" :: "r"(0xFFFFFFFF));
    asm volatile ("csrsi mstatus, 0x8");

    // Set up 80-column mode with cursor
    gpu_set_mode(1);

    show_banner();

    while (1) {
        // Check F5 toggle between commands
        if (ps2_f5_pressed) {
            ps2_f5_pressed = 0;
            toggle_mode();
        }

        gpu_set_fg(GPU_BRIGHT_GREEN);
        mon_putc('>');
        mon_putc(' ');
        gpu_set_fg(GPU_WHITE);

        read_line();

        const char *cmd = skip_spaces(input_buf);
        if (*cmd == '\0') continue;

        char c = *cmd;
        if (c >= 'a' && c <= 'z') c -= 32;

        const char *args = cmd + 1;

        switch (c) {
            case 'H': cmd_help(); break;
            case 'D': cmd_dump(args); break;
            case 'E': cmd_examine(args); break;
            case 'S': cmd_store(args); break;
            case 'L': cmd_load(args); break;
            case 'G': cmd_go(args); break;
            case 'C': show_banner(); break;
            case 'M': cmd_meminfo(); break;
            default:
                gpu_set_fg(GPU_BRIGHT_RED);
                mon_puts("Unknown: ");
                mon_putc(c);
                mon_puts(" (H for help)\n");
                break;
        }
    }

    return 0;
}
