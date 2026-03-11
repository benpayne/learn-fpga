
#include <femtorv32.h>
#include "ps2_keymap.h"

static volatile int timer_count = 0;
static volatile int key_count = 0;
static ps2_state_t ps2;

static void irq_entry(void) __attribute__ ((interrupt ("machine")));

void irq_entry(void)  {
    uint32_t flags = IO_IN(IO_INT_CONTROLLER);

    if (flags & (1 << INT_TIMER_bit)) {
        timer_count++;
        // Restart timer (25M cycles = 1 second at 25MHz)
        IO_OUT(IO_TIMER, 25000000);
        CLEAR_INT(INT_TIMER_bit);
    }
    if (flags & (1 << INT_PS2_bit)) {
        uint32_t ps2_reg = IO_IN(IO_PS2);
        uint8_t scancode = ps2_reg & 0xFF;
        ps2_event_t ev = ps2_process_scancode(&ps2, scancode);

        if (ev.type == PS2_EVENT_PRESS) {
            key_count++;
            if (ev.ascii >= 0x20 && ev.ascii < 0x7F) {
                /* Printable character */
                putchar(ev.ascii);
            } else if (ev.ascii == '\r') {
                putchar('\r');
                putchar('\n');
            } else if (ev.ascii == '\b') {
                /* Backspace: erase on terminal */
                putchar('\b');
                putchar(' ');
                putchar('\b');
            } else if (ev.ascii == '\x1b') {
                printf("[ESC]");
            } else if (ev.ascii == '\t') {
                putchar('\t');
            } else if (ev.keycode >= 0x80) {
                /* Special key */
                switch (ev.keycode) {
                    case PS2_KEY_UP:    printf("[UP]"); break;
                    case PS2_KEY_DOWN:  printf("[DN]"); break;
                    case PS2_KEY_LEFT:  printf("[LT]"); break;
                    case PS2_KEY_RIGHT: printf("[RT]"); break;
                    case PS2_KEY_HOME:  printf("[HM]"); break;
                    case PS2_KEY_END:   printf("[EN]"); break;
                    case PS2_KEY_PGUP:  printf("[PU]"); break;
                    case PS2_KEY_PGDN:  printf("[PD]"); break;
                    case PS2_KEY_INSERT:printf("[IN]"); break;
                    case PS2_KEY_DELETE:printf("[DL]"); break;
                    case PS2_KEY_F1:    printf("[F1]"); break;
                    case PS2_KEY_F2:    printf("[F2]"); break;
                    case PS2_KEY_F3:    printf("[F3]"); break;
                    case PS2_KEY_F4:    printf("[F4]"); break;
                    case PS2_KEY_F5:    printf("[F5]"); break;
                    case PS2_KEY_F6:    printf("[F6]"); break;
                    case PS2_KEY_F7:    printf("[F7]"); break;
                    case PS2_KEY_F8:    printf("[F8]"); break;
                    case PS2_KEY_F9:    printf("[F9]"); break;
                    case PS2_KEY_F10:   printf("[F10]"); break;
                    case PS2_KEY_F11:   printf("[F11]"); break;
                    case PS2_KEY_F12:   printf("[F12]"); break;
                    default:            printf("[0x%x]", ev.keycode); break;
                }
            }
        }
        CLEAR_INT(INT_PS2_bit);
    }
}

void write_mtvec(uintptr_t mtvec) {
    __asm__ volatile ("csrw mtvec, %0" : : "r"(mtvec));
}

void enable_interrupts() {
    uint32_t mstatus;
    __asm__ volatile ("csrr %0, mstatus" : "=r"(mstatus));
    mstatus |= (1 << 3);  // MIE bit (Machine Interrupt Enable)
    __asm__ volatile ("csrw mstatus, %0" : : "r"(mstatus));
}

int main()
{
    int counter = 0;

    // Clear any pending state before enabling interrupts
    IO_OUT(IO_TIMER, 0xFFFFFFFF);
    IO_OUT(IO_INT_CONTROLLER, 0xFFFFFFFF);

    milliwait(100);

    ps2_init(&ps2);

    printf("PS2 Keyboard Demo\r\n");
    printf("=================\r\n");

    uint32_t devices = IO_IN(IO_HW_CONFIG_DEVICES);
    printf("PS2: %s  ", FEMTOSOC_HAS_DEVICE(IO_PS2_bit) ? "YES" : "NO");
    printf("IRQ: %s  ", FEMTOSOC_HAS_DEVICE(IO_INT_CONTROLLER_bit) ? "YES" : "NO");
    printf("TMR: %s\r\n", FEMTOSOC_HAS_DEVICE(IO_TIMER_bit) ? "YES" : "NO");

    // Set up interrupt handler
    write_mtvec((uintptr_t)&irq_entry);

    // Clear pending interrupts again right before enabling
    IO_OUT(IO_INT_CONTROLLER, 0xFFFFFFFF);

    // Start timer: 25M cycles = 1 second at 25MHz
    IO_OUT(IO_TIMER, 25000000);

    // Enable interrupts
    enable_interrupts();

    printf("Type on PS2 keyboard:\r\n\r\n");

    while(1) {
        LEDS(counter & 0xFF);
        IO_OUT(IO_SEGMENT, timer_count);
        delay(1000);
        counter++;
    }

    return 0;
}
