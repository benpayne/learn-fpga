// edit.c — Simple text editor for RetroKernel
// Usage: edit <filename>
// Keys:
//   Type text normally, Enter for new line
//   Backspace to delete character
//   Arrow keys to move cursor
//   Ctrl+S to save
//   Ctrl+Q to quit (prompts to save if modified)

#include "retrokernel.h"

#define MAX_LINES   256
#define MAX_COLS    79       // Leave col 79 empty to prevent scroll
#define SCREEN_ROWS 23      // 25 rows - 1 status - 1 message
#define TOTAL_ROWS  25

// Direct GPU writes — no UART echo, no CR/LF translation, no scroll
static inline void ed_putc(char c) {
    GPU_WRITE(GPU_REG_CHAR_DATA, c);
}
static inline void ed_goto(int col, int row) {
    GPU_WRITE(GPU_REG_CURSOR_COL, col);
    GPU_WRITE(GPU_REG_CURSOR_ROW, row);
}
static inline void ed_fg(int c) { GPU_WRITE(GPU_REG_FG_COLOR, c); }
static inline void ed_bg(int c) { GPU_WRITE(GPU_REG_BG_COLOR, c); }

// Line buffer
static char lines[MAX_LINES][MAX_COLS + 1];
static int  line_len[MAX_LINES];
static int  num_lines = 1;

// Cursor
static int cur_row = 0;
static int cur_col = 0;
static int top_line = 0;

// State
static int modified = 0;
static char filename[128];

// ---- Drawing ----

static void draw_line(int screen_row, int doc_line) {
    ed_goto(0, screen_row);
    int cols = 79; // Write max 79 chars to avoid scroll on last row

    if (doc_line < num_lines) {
        ed_fg(GPU_LIGHT_GRAY);
        int i;
        for (i = 0; i < line_len[doc_line] && i < cols; i++)
            ed_putc(lines[doc_line][i]);
        for (; i < cols; i++)
            ed_putc(' ');
    } else {
        ed_fg(GPU_DARK_GRAY);
        ed_putc('~');
        for (int i = 1; i < cols; i++) ed_putc(' ');
    }
}

static void draw_status(void) {
    ed_goto(0, 24);
    ed_bg(GPU_BLUE);
    ed_fg(GPU_WHITE);

    int pos = 0;
    // Filename
    const char *p = filename;
    while (*p && pos < 40) { ed_putc(*p++); pos++; }
    if (modified) { ed_putc('*'); pos++; }

    // Pad
    while (pos < 50) { ed_putc(' '); pos++; }

    // Line/col info — write inline to avoid con_dec overhead
    ed_putc('L'); ed_putc(':');
    pos += 2;
    { int v = cur_row + 1; char buf[6]; int n = 0;
      if (v == 0) { ed_putc('0'); pos++; }
      else { while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
             while (n > 0) { ed_putc(buf[--n]); pos++; } } }
    ed_putc('/'); pos++;
    { int v = num_lines; char buf[6]; int n = 0;
      if (v == 0) { ed_putc('0'); pos++; }
      else { while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
             while (n > 0) { ed_putc(buf[--n]); pos++; } } }
    ed_putc(' '); pos++;
    ed_putc('C'); ed_putc(':'); pos += 2;
    { int v = cur_col + 1; char buf[6]; int n = 0;
      if (v == 0) { ed_putc('0'); pos++; }
      else { while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
             while (n > 0) { ed_putc(buf[--n]); pos++; } } }

    // Pad rest — stop at col 78 to avoid scroll
    while (pos < 78) { ed_putc(' '); pos++; }

    ed_bg(GPU_BLACK);
    ed_fg(GPU_WHITE);
}

static void draw_message(const char *msg) {
    ed_goto(0, 23);
    ed_fg(GPU_YELLOW);
    int len = 0;
    while (msg[len]) { ed_putc(msg[len]); len++; }
    while (len < 79) { ed_putc(' '); len++; }
    ed_fg(GPU_WHITE);
}

static void draw_screen(void) {
    for (int r = 0; r < SCREEN_ROWS; r++)
        draw_line(r, top_line + r);
    draw_status();
    draw_message("");
}

static void place_cursor(void) {
    ed_goto(cur_col, cur_row - top_line);
}

static void ensure_visible(void) {
    if (cur_row < top_line) {
        top_line = cur_row;
        draw_screen();
    } else if (cur_row >= top_line + SCREEN_ROWS) {
        top_line = cur_row - SCREEN_ROWS + 1;
        draw_screen();
    }
}

// ---- Editing ----

static void insert_char(char c) {
    if (cur_col >= MAX_COLS) return;
    if (line_len[cur_row] >= MAX_COLS) return;

    for (int i = line_len[cur_row]; i > cur_col; i--)
        lines[cur_row][i] = lines[cur_row][i-1];
    lines[cur_row][cur_col] = c;
    line_len[cur_row]++;
    cur_col++;
    modified = 1;
    draw_line(cur_row - top_line, cur_row);
}

static void delete_char(void) {
    if (cur_col > 0) {
        cur_col--;
        for (int i = cur_col; i < line_len[cur_row] - 1; i++)
            lines[cur_row][i] = lines[cur_row][i+1];
        line_len[cur_row]--;
        modified = 1;
        draw_line(cur_row - top_line, cur_row);
    } else if (cur_row > 0) {
        int prev_len = line_len[cur_row - 1];
        if (prev_len + line_len[cur_row] <= MAX_COLS) {
            for (int i = 0; i < line_len[cur_row]; i++)
                lines[cur_row - 1][prev_len + i] = lines[cur_row][i];
            line_len[cur_row - 1] += line_len[cur_row];

            for (int i = cur_row; i < num_lines - 1; i++) {
                for (int j = 0; j < MAX_COLS; j++)
                    lines[i][j] = lines[i+1][j];
                line_len[i] = line_len[i+1];
            }
            num_lines--;
            cur_row--;
            cur_col = prev_len;
            modified = 1;
            ensure_visible();
            draw_screen();
        }
    }
}

static void split_line(void) {
    if (num_lines >= MAX_LINES) return;

    for (int i = num_lines; i > cur_row + 1; i--) {
        for (int j = 0; j < MAX_COLS; j++)
            lines[i][j] = lines[i-1][j];
        line_len[i] = line_len[i-1];
    }

    int new_line = cur_row + 1;
    int remain = line_len[cur_row] - cur_col;
    for (int i = 0; i < remain; i++)
        lines[new_line][i] = lines[cur_row][cur_col + i];
    line_len[new_line] = remain;
    line_len[cur_row] = cur_col;
    num_lines++;

    cur_row++;
    cur_col = 0;
    modified = 1;
    ensure_visible();
    draw_screen();
}

// ---- File I/O ----

static int load_file(const char *path) {
    uint8_t *buf = (uint8_t *)0x900000;
    int size = rk_load_file(path, buf, 0x100000);
    if (size < 0) return 0;

    num_lines = 0;
    int col = 0;
    for (int i = 0; i < size && num_lines < MAX_LINES; i++) {
        if (buf[i] == '\r') continue;
        if (buf[i] == '\n' || col >= MAX_COLS) {
            line_len[num_lines] = col;
            num_lines++;
            col = 0;
        } else {
            lines[num_lines][col++] = buf[i];
        }
    }
    if (col > 0 || num_lines == 0) {
        line_len[num_lines] = col;
        num_lines++;
    }
    return 1;
}

static int save_file(void) {
    uint8_t *buf = (uint8_t *)0x900000;
    int total = 0;

    for (int i = 0; i < num_lines; i++) {
        for (int j = 0; j < line_len[i]; j++)
            buf[total++] = lines[i][j];
        buf[total++] = '\n';
    }

    int written = rk_save_file(filename, buf, total);
    if (written < 0) return 0;
    modified = 0;
    return total;
}

// ---- Main ----

int main(int argc, char **argv) {
    for (int i = 0; i < MAX_LINES; i++)
        line_len[i] = 0;

    if (argc < 2) {
        rk_puts("usage: edit <filename>\n");
        return 1;
    }

    int i = 0;
    while (argv[1][i] && i < 126) { filename[i] = argv[1][i]; i++; }
    filename[i] = '\0';

    if (load_file(filename)) {
        // loaded
    } else {
        num_lines = 1;
        line_len[0] = 0;
    }

    // Clear and draw
    GPU_WRITE(GPU_REG_DISPLAY_MODE, 0);
    rk_cls();
    draw_screen();
    place_cursor();

    int running = 1;
    while (running) {
        uint16_t k = rk_getkey();
        uint8_t keycode = k >> 8;
        char c = k & 0xFF;

        if (keycode == RK_KEY_UP) {
            if (cur_row > 0) {
                cur_row--;
                if (cur_col > line_len[cur_row]) cur_col = line_len[cur_row];
                ensure_visible();
                draw_status();
                place_cursor();
            }
        } else if (keycode == RK_KEY_DOWN) {
            if (cur_row < num_lines - 1) {
                cur_row++;
                if (cur_col > line_len[cur_row]) cur_col = line_len[cur_row];
                ensure_visible();
                draw_status();
                place_cursor();
            }
        } else if (keycode == RK_KEY_LEFT) {
            if (cur_col > 0) {
                cur_col--;
                draw_status();
                place_cursor();
            } else if (cur_row > 0) {
                cur_row--;
                cur_col = line_len[cur_row];
                ensure_visible();
                draw_status();
                place_cursor();
            }
        } else if (keycode == RK_KEY_RIGHT) {
            if (cur_col < line_len[cur_row]) {
                cur_col++;
                draw_status();
                place_cursor();
            } else if (cur_row < num_lines - 1) {
                cur_row++;
                cur_col = 0;
                ensure_visible();
                draw_status();
                place_cursor();
            }
        } else if (keycode == RK_KEY_HOME) {
            cur_col = 0;
            draw_status();
            place_cursor();
        } else if (keycode == RK_KEY_END) {
            cur_col = line_len[cur_row];
            draw_status();
            place_cursor();
        } else if (keycode == RK_KEY_PGUP) {
            cur_row -= SCREEN_ROWS;
            if (cur_row < 0) cur_row = 0;
            if (cur_col > line_len[cur_row]) cur_col = line_len[cur_row];
            ensure_visible();
            draw_screen();
            place_cursor();
        } else if (keycode == RK_KEY_PGDN) {
            cur_row += SCREEN_ROWS;
            if (cur_row >= num_lines) cur_row = num_lines - 1;
            if (cur_col > line_len[cur_row]) cur_col = line_len[cur_row];
            ensure_visible();
            draw_screen();
            place_cursor();
        } else if (keycode == RK_KEY_DELETE) {
            // Delete char under cursor
            if (cur_col < line_len[cur_row]) {
                for (int i = cur_col; i < line_len[cur_row] - 1; i++)
                    lines[cur_row][i] = lines[cur_row][i+1];
                line_len[cur_row]--;
                modified = 1;
                draw_line(cur_row - top_line, cur_row);
                draw_status();
                place_cursor();
            }
        } else if (c == 0x13) {
            // Ctrl+S — Save
            int bytes = save_file();
            if (bytes > 0) {
                char msg[40] = "Saved ";
                // Append byte count
                char buf[11]; int n = 0; int v = bytes;
                while (v > 0) { buf[n++] = '0' + v % 10; v /= 10; }
                int p = 6;
                while (n > 0) msg[p++] = buf[--n];
                msg[p++] = ' '; msg[p++] = 'b'; msg[p++] = 'y';
                msg[p++] = 't'; msg[p++] = 'e'; msg[p++] = 's';
                msg[p] = '\0';
                draw_message(msg);
            } else {
                draw_message("Error saving file!");
            }
            draw_status();
            place_cursor();
        } else if (c == 0x11) {
            // Ctrl+Q — Quit
            if (modified) {
                draw_message("Unsaved! Ctrl+Q=quit Ctrl+S=save");
                uint16_t k2 = rk_getkey();
                char c2 = k2 & 0xFF;
                if (c2 == 0x11) {
                    running = 0;
                } else if (c2 == 0x13) {
                    save_file();
                    running = 0;
                } else {
                    draw_message("");
                    place_cursor();
                }
            } else {
                running = 0;
            }
        } else if (c == '\r' || c == '\n') {
            split_line();
            place_cursor();
        } else if (c == '\b' || c == 0x7F) {
            delete_char();
            draw_status();
            place_cursor();
        } else if (c >= 0x20 && c < 0x7F) {
            insert_char(c);
            draw_status();
            place_cursor();
        }
    }

    rk_cls();
    return 0;
}
