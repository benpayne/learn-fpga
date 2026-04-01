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

#define DEFAULT_LOAD_ADDR  0x800000  // Default load address (SDRAM)
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
            // Write as 32-bit words (SDRAM doesn't support byte writes)
            volatile uint32_t *dest32 = (volatile uint32_t *)addr;
            for (int i = 0; i < 128; i += 4) {
                dest32[i/4] = (uint32_t)data[i]
                            | ((uint32_t)data[i+1] << 8)
                            | ((uint32_t)data[i+2] << 16)
                            | ((uint32_t)data[i+3] << 24);
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
        mon_puts("  FemtoRV Monitor v1.0 | RV32IMFC @ 25MHz | 32KB ROM + 8MB SDRAM | F5=40/80\n");
        mon_puts("===============================================================================\n");
    } else {
        mon_puts("========================================\n");
        mon_puts("  FemtoRV Monitor v1.0 | 25MHz 8MB\n");
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
    mon_puts("  H          Help\n");
    mon_puts("  D <addr>   Dump 128 bytes\n");
    mon_puts("  E <addr>   Examine byte\n");
    mon_puts("  S <a> <v>  Store byte\n");
    mon_puts("  L [addr]   Load XMODEM (default 800000)\n");
    mon_puts("  G [addr]   Go/execute (default 800000)\n");
    mon_puts("  C          Clear screen\n");
    mon_puts("  M          Memory info\n");
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
        mon_hex_word(addr + row * 16);
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
    mon_hex_word(addr);
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
    mon_puts("  ROM:   32KB (0x000000-0x007FFF)\n");
    mon_puts("  SDRAM: 8MB  (0x800000-0xFFFFFF)\n");
    mon_puts("  IO:    0x400000+\n");
}

// ----- Minimal FAT32 SD Boot -----
// Tiny FAT32 reader — just enough to find and load one file from root dir.
// No FAT library dependency (~800 bytes of code).

extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

#define KERNEL_LOAD_ADDR  0x800000

static uint8_t sector_buf[512];

// Read 32-bit LE from buffer
static uint32_t rd32(const uint8_t *p) {
    return p[0] | (p[1]<<8) | (p[2]<<16) | (p[3]<<24);
}
static uint16_t rd16(const uint8_t *p) {
    return p[0] | (p[1]<<8);
}

// FAT32 boot sector fields
static uint32_t fat_begin;       // First sector of FAT
static uint32_t cluster_begin;   // First sector of cluster 2
static uint32_t root_cluster;    // Root directory cluster
static uint8_t  sectors_per_cluster;

// Convert cluster number to sector number
static uint32_t cluster_to_sector(uint32_t cluster) {
    return cluster_begin + (cluster - 2) * sectors_per_cluster;
}

// Read next cluster from FAT
static uint32_t fat_next_cluster(uint32_t cluster) {
    uint32_t fat_sector = fat_begin + (cluster * 4) / 512;
    uint32_t fat_offset = (cluster * 4) % 512;
    if (!sd_readsector(fat_sector, sector_buf, 1)) return 0x0FFFFFFF;
    return rd32(sector_buf + fat_offset) & 0x0FFFFFFF;
}

// Compare 8.3 filename (11 chars, space-padded)
static int name_match(const uint8_t *entry, const char *name83) {
    for (int i = 0; i < 11; i++)
        if (entry[i] != name83[i]) return 0;
    return 1;
}

static int try_sd_boot(void) {
    gpu_set_fg(GPU_YELLOW);
    mon_puts("SD boot...");

    if (sd_init()) {
        gpu_set_fg(GPU_LIGHT_GRAY);
        mon_puts("no card\n");
        return 0;
    }

    // Read MBR to find partition
    if (!sd_readsector(0, sector_buf, 1)) { mon_puts("read err\n"); return 0; }

    uint32_t part_start = 0;
    // Check for MBR (0x55AA signature)
    if (sector_buf[510] == 0x55 && sector_buf[511] == 0xAA) {
        // First partition entry at offset 446
        part_start = rd32(sector_buf + 446 + 8);
    }

    // Read boot sector (VBR)
    if (!sd_readsector(part_start, sector_buf, 1)) { mon_puts("VBR err\n"); return 0; }

    // Verify FAT32 signature
    uint16_t bytes_per_sector = rd16(sector_buf + 11);
    if (bytes_per_sector != 512) { mon_puts("not 512\n"); return 0; }

    sectors_per_cluster = sector_buf[13];
    uint16_t reserved_sectors = rd16(sector_buf + 14);
    uint8_t  num_fats = sector_buf[16];
    uint32_t fat_size = rd32(sector_buf + 36);
    root_cluster = rd32(sector_buf + 44);

    fat_begin = part_start + reserved_sectors;
    cluster_begin = fat_begin + num_fats * fat_size;

    // Search root directory for KERNEL.BIN (8.3 format: "KERNEL  BIN")
    // 8.3 names are space-padded: 8 chars name + 3 chars extension
    const char target[] = "KERNEL  BIN";

    uint32_t cluster = root_cluster;
    uint32_t file_size = 0;
    uint32_t file_cluster = 0;
    int found = 0;

    while (cluster < 0x0FFFFFF8 && !found) {
        uint32_t sec = cluster_to_sector(cluster);
        for (int s = 0; s < sectors_per_cluster && !found; s++) {
            if (!sd_readsector(sec + s, sector_buf, 1)) break;
            for (int e = 0; e < 512; e += 32) {
                if (sector_buf[e] == 0x00) goto done_search; // End of dir
                if (sector_buf[e] == 0xE5) continue; // Deleted
                if (sector_buf[e + 11] & 0x08) continue; // Volume label
                if (sector_buf[e + 11] & 0x0F == 0x0F) continue; // LFN entry
                if (name_match(sector_buf + e, target)) {
                    file_cluster = (rd16(sector_buf + e + 20) << 16) |
                                    rd16(sector_buf + e + 26);
                    file_size = rd32(sector_buf + e + 28);
                    found = 1;
                }
            }
        }
        cluster = fat_next_cluster(cluster);
    }
done_search:

    if (!found || file_size == 0) {
        gpu_set_fg(GPU_LIGHT_GRAY);
        mon_puts("no kernel\n");
        return 0;
    }

    // Load file to SDRAM
    volatile uint32_t *dest = (volatile uint32_t *)KERNEL_LOAD_ADDR;
    uint32_t remaining = file_size;
    cluster = file_cluster;
    int total = 0;

    while (cluster < 0x0FFFFFF8 && remaining > 0) {
        uint32_t sec = cluster_to_sector(cluster);
        for (int s = 0; s < sectors_per_cluster && remaining > 0; s++) {
            if (!sd_readsector(sec + s, sector_buf, 1)) {
                mon_puts("read err\n");
                return 0;
            }
            // Copy as 32-bit words (SDRAM needs word writes)
            int bytes = remaining > 512 ? 512 : remaining;
            for (int i = 0; i < bytes; i += 4) {
                dest[total/4] = sector_buf[i] | (sector_buf[i+1]<<8) |
                               (sector_buf[i+2]<<16) | (sector_buf[i+3]<<24);
                total += 4;
            }
            remaining -= bytes;
        }
        cluster = fat_next_cluster(cluster);
    }

    // Verify first word
    uint32_t first = *(volatile uint32_t *)KERNEL_LOAD_ADDR;
    if (first == 0x00000000 || first == 0xFFFFFFFF) {
        mon_puts("bad image\n");
        return 0;
    }

    gpu_set_fg(GPU_BRIGHT_GREEN);
    mon_puts("OK\n");

    // Jump to kernel
    void (*entry)(void) = (void (*)(void))KERNEL_LOAD_ADDR;
    entry();

    // If kernel returns, fall through to monitor
    return 1;
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

    // Try SD card boot before dropping to monitor
    try_sd_boot();

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
