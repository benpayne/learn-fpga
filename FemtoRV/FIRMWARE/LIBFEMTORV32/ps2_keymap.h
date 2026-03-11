#ifndef PS2_KEYMAP_H
#define PS2_KEYMAP_H

#include <stdint.h>

/*
 * PS/2 Scan Code Set 2 decoder
 *
 * Tracks modifier state (shift, ctrl, alt) and converts
 * scan codes to ASCII characters. Handles break codes (0xF0)
 * and extended keys (0xE0).
 *
 * Usage:
 *   ps2_state_t ps2;
 *   ps2_init(&ps2);
 *
 *   // In your interrupt handler or polling loop:
 *   ps2_event_t ev = ps2_process_scancode(&ps2, scancode);
 *   if (ev.type == PS2_EVENT_PRESS && ev.ascii) {
 *       putchar(ev.ascii);
 *   }
 */

/* Modifier key bit flags */
#define PS2_MOD_LSHIFT  0x01
#define PS2_MOD_RSHIFT  0x02
#define PS2_MOD_SHIFT   0x03  /* either shift */
#define PS2_MOD_LCTRL   0x04
#define PS2_MOD_RCTRL   0x08
#define PS2_MOD_CTRL    0x0C  /* either ctrl */
#define PS2_MOD_LALT    0x10
#define PS2_MOD_RALT    0x20
#define PS2_MOD_ALT     0x30  /* either alt */
#define PS2_MOD_CAPSLOCK 0x40

/* Event types */
#define PS2_EVENT_NONE    0  /* No complete event yet (mid-sequence) */
#define PS2_EVENT_PRESS   1  /* Key pressed */
#define PS2_EVENT_RELEASE 2  /* Key released */

/* Special key codes (non-ASCII, returned in ev.keycode) */
#define PS2_KEY_NONE      0x00
#define PS2_KEY_F1        0x80
#define PS2_KEY_F2        0x81
#define PS2_KEY_F3        0x82
#define PS2_KEY_F4        0x83
#define PS2_KEY_F5        0x84
#define PS2_KEY_F6        0x85
#define PS2_KEY_F7        0x86
#define PS2_KEY_F8        0x87
#define PS2_KEY_F9        0x88
#define PS2_KEY_F10       0x89
#define PS2_KEY_F11       0x8A
#define PS2_KEY_F12       0x8B
#define PS2_KEY_UP        0x90
#define PS2_KEY_DOWN      0x91
#define PS2_KEY_LEFT      0x92
#define PS2_KEY_RIGHT     0x93
#define PS2_KEY_HOME      0x94
#define PS2_KEY_END       0x95
#define PS2_KEY_PGUP      0x96
#define PS2_KEY_PGDN      0x97
#define PS2_KEY_INSERT    0x98
#define PS2_KEY_DELETE    0x99
#define PS2_KEY_PRTSCN    0x9A
#define PS2_KEY_PAUSE     0x9B
#define PS2_KEY_NUMLOCK   0x9C
#define PS2_KEY_SCRLOCK   0x9D

typedef struct {
    uint8_t type;      /* PS2_EVENT_NONE, PRESS, or RELEASE */
    uint8_t ascii;     /* ASCII character (0 if non-printable) */
    uint8_t keycode;   /* PS2_KEY_* for special keys, or ASCII for normal */
    uint8_t modifiers; /* Current modifier state (PS2_MOD_*) */
} ps2_event_t;

typedef struct {
    uint8_t modifiers;   /* Current modifier state */
    uint8_t flags;       /* Internal: bit 0 = break prefix seen, bit 1 = extended prefix */
} ps2_state_t;

/* Scan Code Set 2 → ASCII lookup (unshifted) */
static const uint8_t ps2_scancode_to_ascii[128] = {
    /*0x00*/ 0,    0,    0,    0,    0,   PS2_KEY_F1, 0,   PS2_KEY_F12,
    /*0x08*/ 0,    PS2_KEY_F10, PS2_KEY_F8, PS2_KEY_F6, PS2_KEY_F4, '\t', '`',  0,
    /*0x10*/ 0,    0,    0,    0,    0,    'q',  '1',  0,
    /*0x18*/ 0,    0,    'z',  's',  'a',  'w',  '2',  0,
    /*0x20*/ 0,    'c',  'x',  'd',  'e',  '4',  '3',  0,
    /*0x28*/ 0,    ' ',  'v',  'f',  't',  'r',  '5',  0,
    /*0x30*/ 0,    'n',  'b',  'h',  'g',  'y',  '6',  0,
    /*0x38*/ 0,    0,    'm',  'j',  'u',  '7',  '8',  0,
    /*0x40*/ 0,    ',',  'k',  'i',  'o',  '0',  '9',  0,
    /*0x48*/ 0,    '.',  '/',  'l',  ';',  'p',  '-',  0,
    /*0x50*/ 0,    0,    '\'', 0,    '[',  '=',  0,    0,
    /*0x58*/ 0,    0,    '\r', ']',  0,    '\\', 0,    0,
    /*0x60*/ 0,    0,    0,    0,    0,    0,    '\b', 0,
    /*0x68*/ 0,    '1',  0,    '4',  '7',  0,    0,    0,
    /*0x70*/ '0',  '.',  '2',  '5',  '6',  '8',  '\x1b', PS2_KEY_NUMLOCK,
    /*0x78*/ PS2_KEY_F11, '+', '3',  '-',  '*',  '9',  PS2_KEY_SCRLOCK, 0,
};

/* Scan Code Set 2 → ASCII lookup (shifted) */
static const uint8_t ps2_scancode_to_ascii_shifted[128] = {
    /*0x00*/ 0,    0,    0,    0,    0,   PS2_KEY_F1, 0,   PS2_KEY_F12,
    /*0x08*/ 0,    PS2_KEY_F10, PS2_KEY_F8, PS2_KEY_F6, PS2_KEY_F4, '\t', '~',  0,
    /*0x10*/ 0,    0,    0,    0,    0,    'Q',  '!',  0,
    /*0x18*/ 0,    0,    'Z',  'S',  'A',  'W',  '@',  0,
    /*0x20*/ 0,    'C',  'X',  'D',  'E',  '$',  '#',  0,
    /*0x28*/ 0,    ' ',  'V',  'F',  'T',  'R',  '%',  0,
    /*0x30*/ 0,    'N',  'B',  'H',  'G',  'Y',  '^',  0,
    /*0x38*/ 0,    0,    'M',  'J',  'U',  '&',  '*',  0,
    /*0x40*/ 0,    '<',  'K',  'I',  'O',  ')',  '(',  0,
    /*0x48*/ 0,    '>',  '?',  'L',  ':',  'P',  '_',  0,
    /*0x50*/ 0,    0,    '"',  0,    '{',  '+',  0,    0,
    /*0x58*/ 0,    0,    '\r', '}',  0,    '|',  0,    0,
    /*0x60*/ 0,    0,    0,    0,    0,    0,    '\b', 0,
    /*0x68*/ 0,    0,    0,    0,    0,    0,    0,    0,
    /*0x70*/ 0,    0,    0,    0,    0,    0,    '\x1b', 0,
    /*0x78*/ PS2_KEY_F11, '+', 0,    '-',  '*',  0,    0,    0,
};

/* Extended key scan codes (after 0xE0 prefix) → key codes */
static const uint8_t ps2_extended_to_keycode[128] = {
    [0x75] = PS2_KEY_UP,
    [0x72] = PS2_KEY_DOWN,
    [0x6B] = PS2_KEY_LEFT,
    [0x74] = PS2_KEY_RIGHT,
    [0x6C] = PS2_KEY_HOME,
    [0x69] = PS2_KEY_END,
    [0x7D] = PS2_KEY_PGUP,
    [0x7A] = PS2_KEY_PGDN,
    [0x70] = PS2_KEY_INSERT,
    [0x71] = PS2_KEY_DELETE,
    [0x14] = 0xFF, /* Right Ctrl (handled as modifier) */
    [0x11] = 0xFE, /* Right Alt (handled as modifier) */
};

static inline void ps2_init(ps2_state_t *state) {
    state->modifiers = 0;
    state->flags = 0;
}

static inline ps2_event_t ps2_process_scancode(ps2_state_t *state, uint8_t scancode) {
    ps2_event_t ev = {PS2_EVENT_NONE, 0, 0, state->modifiers};

    /* Break prefix: next code is a key release */
    if (scancode == 0xF0) {
        state->flags |= 0x01;
        return ev;
    }

    /* Extended key prefix */
    if (scancode == 0xE0) {
        state->flags |= 0x02;
        return ev;
    }

    /* BAT completion or echo - ignore */
    if (scancode == 0xAA || scancode == 0xEE || scancode == 0xFA) {
        state->flags = 0;
        return ev;
    }

    uint8_t is_break = state->flags & 0x01;
    uint8_t is_extended = state->flags & 0x02;
    state->flags = 0;  /* Reset for next sequence */

    ev.type = is_break ? PS2_EVENT_RELEASE : PS2_EVENT_PRESS;

    /* Handle extended keys */
    if (is_extended && scancode < 128) {
        uint8_t keycode = ps2_extended_to_keycode[scancode];
        if (keycode == 0xFF) {
            /* Right Ctrl */
            if (is_break) state->modifiers &= ~PS2_MOD_RCTRL;
            else          state->modifiers |= PS2_MOD_RCTRL;
            ev.modifiers = state->modifiers;
            ev.type = PS2_EVENT_NONE;
            return ev;
        }
        if (keycode == 0xFE) {
            /* Right Alt */
            if (is_break) state->modifiers &= ~PS2_MOD_RALT;
            else          state->modifiers |= PS2_MOD_RALT;
            ev.modifiers = state->modifiers;
            ev.type = PS2_EVENT_NONE;
            return ev;
        }
        ev.keycode = keycode;
        ev.modifiers = state->modifiers;
        return ev;
    }

    /* Handle modifier keys */
    if (scancode < 128) {
        switch (scancode) {
            case 0x12: /* Left Shift */
                if (is_break) state->modifiers &= ~PS2_MOD_LSHIFT;
                else          state->modifiers |= PS2_MOD_LSHIFT;
                ev.modifiers = state->modifiers;
                ev.type = PS2_EVENT_NONE;
                return ev;
            case 0x59: /* Right Shift */
                if (is_break) state->modifiers &= ~PS2_MOD_RSHIFT;
                else          state->modifiers |= PS2_MOD_RSHIFT;
                ev.modifiers = state->modifiers;
                ev.type = PS2_EVENT_NONE;
                return ev;
            case 0x14: /* Left Ctrl */
                if (is_break) state->modifiers &= ~PS2_MOD_LCTRL;
                else          state->modifiers |= PS2_MOD_LCTRL;
                ev.modifiers = state->modifiers;
                ev.type = PS2_EVENT_NONE;
                return ev;
            case 0x11: /* Left Alt */
                if (is_break) state->modifiers &= ~PS2_MOD_LALT;
                else          state->modifiers |= PS2_MOD_LALT;
                ev.modifiers = state->modifiers;
                ev.type = PS2_EVENT_NONE;
                return ev;
            case 0x58: /* Caps Lock - toggle on press */
                if (!is_break)
                    state->modifiers ^= PS2_MOD_CAPSLOCK;
                ev.modifiers = state->modifiers;
                ev.type = PS2_EVENT_NONE;
                return ev;
        }

        /* Normal key - look up ASCII */
        uint8_t shifted = (state->modifiers & PS2_MOD_SHIFT) ? 1 : 0;

        /* Caps lock inverts shift for letters only */
        if (state->modifiers & PS2_MOD_CAPSLOCK) {
            uint8_t ch = ps2_scancode_to_ascii[scancode];
            if (ch >= 'a' && ch <= 'z')
                shifted = !shifted;
        }

        if (shifted)
            ev.ascii = ps2_scancode_to_ascii_shifted[scancode];
        else
            ev.ascii = ps2_scancode_to_ascii[scancode];

        /* For special keys (F-keys etc), put in keycode instead */
        if (ev.ascii >= 0x80) {
            ev.keycode = ev.ascii;
            ev.ascii = 0;
        } else {
            ev.keycode = ev.ascii;
        }

        /* Ctrl+letter → control character (0x01-0x1A) */
        if ((state->modifiers & PS2_MOD_CTRL) && ev.ascii >= 'a' && ev.ascii <= 'z') {
            ev.ascii = ev.ascii - 'a' + 1;
        } else if ((state->modifiers & PS2_MOD_CTRL) && ev.ascii >= 'A' && ev.ascii <= 'Z') {
            ev.ascii = ev.ascii - 'A' + 1;
        }
    }

    ev.modifiers = state->modifiers;
    return ev;
}

#endif /* PS2_KEYMAP_H */
