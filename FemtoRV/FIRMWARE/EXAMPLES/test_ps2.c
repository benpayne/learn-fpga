/*
 * PS/2 Keyboard Test for FemtoRV
 *
 * Tests the PS/2 controller by reading scan codes from a PS/2 keyboard
 * and displaying them via UART.
 *
 * Hardware connections on Colorlight i5:
 *   PS/2 Clock -> ps2_clk pin (K5)
 *   PS/2 Data  -> ps2_data pin (B3)
 *   PS/2 VCC   -> 5V
 *   PS/2 GND   -> GND
 */

#include <femtorv32.h>

int main() {
    // Disable interrupts - we're polling
    __asm__ volatile ("csrw mstatus, zero");
    __asm__ volatile ("csrw mie, zero");

    // Stop timer: write a large value so it doesn't immediately complete
    // (writing 0 causes instant completion which re-triggers the interrupt)
    IO_OUT(IO_TIMER, 0xFFFFFFFF);

    // Clear any pending interrupt bits
    IO_OUT(IO_INT_CONTROLLER, 0xFFFFFFFF);
    IO_OUT(IO_INT_CONTROLLER, 0xFFFFFFFF);

    // Brief delay to let UART settle after PLL lock
    milliwait(100);

    printf("PS/2 Keyboard Test\n");
    printf("==================\n");

    uint32_t devices = IO_IN(IO_HW_CONFIG_DEVICES);
    printf("HW devices: 0x%x\n", devices);

    int has_ps2 = FEMTOSOC_HAS_DEVICE(IO_PS2_bit);
    int has_int = FEMTOSOC_HAS_DEVICE(IO_INT_CONTROLLER_bit);

    printf("PS/2: %s\n", has_ps2 ? "YES" : "NO");
    printf("IntCtrl: %s\n", has_int ? "YES" : "NO");

    if (!has_ps2) {
        printf("ERROR: No PS/2 device!\n");
        while(1);
    }

    printf("Waiting for keys...\n\n");

    int count = 0;
    int heartbeat = 0;
    int diag_count = 0;

    while(1) {
        uint32_t ps2_reg = IO_IN(IO_PS2);
        uint8_t scancode = ps2_reg & 0xFF;
        uint8_t fifo_empty = (ps2_reg >> 8) & 1;
        uint8_t fifo_full = (ps2_reg >> 9) & 1;

        if (!fifo_empty) {
            count++;
            printf("[%d] key=0x%x", count, scancode);

            if (scancode == 0xF0) {
                printf(" BREAK");
            } else if (scancode == 0xE0) {
                printf(" EXT");
            } else if (scancode == 0xAA) {
                printf(" BAT-OK");
            }

            if (fifo_full) {
                printf(" FULL!");
            }

            printf("\n");

            if (has_int) {
                CLEAR_INT(INT_PS2_bit);
            }

            milliwait(10);
            heartbeat = 0;
        }

        // Every ~5 seconds, dump raw PS2 register and interrupt status
        heartbeat++;
        if (heartbeat >= 50000) {
            diag_count++;
            printf("\n[diag %d] ps2_reg=0x%x empty=%d full=%d",
                   diag_count, ps2_reg, fifo_empty, fifo_full);
            if (has_int) {
                uint32_t int_status = IO_IN(IO_INT_CONTROLLER);
                printf(" int=0x%x", int_status);
            }
            printf("\n");
            heartbeat = 0;
        }

        microwait(100);
    }

    return 0;
}
