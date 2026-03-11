
#include <femtorv32.h>

static void irq_entry(void) __attribute__ ((interrupt ("machine")));

void irq_entry(void)  {
    uint32_t flags = IO_IN(IO_INT_CONTROLLER);
    printf("Begin IRQ %x\r\n", IO_IN(IO_INT_CONTROLLER));

    if (flags & (1 << INT_TIMER_bit)) {
        printf("Timer IRQ\r\n");
        CLEAR_INT(INT_TIMER_bit);
    }
    if (flags & (1 << INT_PS2_bit)) {
        uint32_t ps2_data = IO_IN(IO_PS2);
        printf(" > Key %x status %d\r\n", ps2_data & 0xFF, (ps2_data >> 8) & 3 );
        CLEAR_INT(INT_PS2_bit);
    }

    printf("Exit IRQ %x\r\n", IO_IN(IO_INT_CONTROLLER));
}   

void write_mtvec(uintptr_t mtvec) {
    __asm__ volatile ("csrw mtvec, %0" : : "r"(mtvec));
}

void enable_interrupts() {
    uint32_t mstatus, mie;
    __asm__ volatile ("csrr %0, mstatus" : "=r"(mstatus));
    mstatus |= (1 << 3);  // MIE bit
    __asm__ volatile ("csrw mstatus, %0" : : "r"(mstatus));

    __asm__ volatile ("csrr %0, mie" : "=r"(mie));
    mie |= (1 << 7);  // MTIE (Machine Timer Interrupt Enable)
    mie |= (1 << 11); // MEIE (Machine External Interrupt Enable)
    __asm__ volatile ("csrw mie, %0" : : "r"(mie));
}

int main() 
{
    int buttons = 0;
    int counter = 0;
    write_mtvec((uintptr_t)&irq_entry);
    enable_interrupts();

    uint32_t timeout = 400000000;

    IO_OUT(IO_TIMER, timeout);
    printf("Timer Initial Count: %d\r\n", timeout);
    uint32_t devices = IO_IN(IO_HW_CONFIG_DEVICES);
    printf("Devices Configured: %x\r\n", devices);
    if (devices & (1 << IO_PS2_bit)) {
        printf("PS2 Device Configured\r\n");
    }
    if (devices & (1 << IO_INT_CONTROLLER_bit)) {
        printf("Interrupt Controller Configured\r\n");
    }
    while(1) {
        uint32_t timer_count = IO_IN(IO_TIMER);
        if ( timer_count > 0 ) {
            printf("Timer Count: %u\r\n", timer_count );
        }
        LEDS(0x03);
        delay(500);
        LEDS(0x1c);
        delay(500);

        buttons = IO_IN(IO_BUTTONS);
        printf("Buttons: %d, Counter %d\r\n", buttons, counter);
        //IO_OUT(IO_SEGMENT, counter);
        counter += 1;
    }

    return 0;
}
