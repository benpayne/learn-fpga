
#include <femtorv32.h>

static volatile int timer_count = 0;
static volatile int key_count = 0;

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
        key_count++;
        printf("[IRQ] key=0x%x (#%d)\r\n", scancode, key_count);
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

    printf("Interrupt Test\r\n");
    printf("==============\r\n");

    uint32_t devices = IO_IN(IO_HW_CONFIG_DEVICES);
    printf("Devices: 0x%x\r\n", devices);
    printf("PS2: %s\r\n", FEMTOSOC_HAS_DEVICE(IO_PS2_bit) ? "YES" : "NO");
    printf("IntCtrl: %s\r\n", FEMTOSOC_HAS_DEVICE(IO_INT_CONTROLLER_bit) ? "YES" : "NO");
    printf("Timer: %s\r\n", FEMTOSOC_HAS_DEVICE(IO_TIMER_bit) ? "YES" : "NO");

    // Set up interrupt handler
    write_mtvec((uintptr_t)&irq_entry);

    // Clear pending interrupts again right before enabling
    IO_OUT(IO_INT_CONTROLLER, 0xFFFFFFFF);

    // Start timer: 25M cycles = 1 second at 25MHz
    IO_OUT(IO_TIMER, 25000000);

    // Enable interrupts
    enable_interrupts();

    printf("Interrupts ON\r\n");
    printf("Press PS2 keys...\r\n\r\n");

    while(1) {
        // Main loop: blink LEDs, show timer interrupt count
        LEDS(counter & 0xFF);
        IO_OUT(IO_SEGMENT, timer_count);

        delay(1000);
        counter++;

        printf("t=%d keys=%d\r\n", timer_count, key_count);
    }

    return 0;
}
