
#include <femtorv32.h>

int main() 
{
    int buttons = 0;
    int counter = 0;
    while(1) {
        printf("Hello World!\r\n");
        printf("Freq: %d MHz\r\n", FEMTORV32_FREQ);
        LEDS(0x03);
        buttons = IO_IN(IO_BUTTONS);
        printf("Buttons: %d \r\n", buttons);
        delay(500);
        LEDS(0x1c);
        buttons = IO_IN(IO_BUTTONS);
        printf("Buttons: %d \r\n", buttons);
        delay(500);

        printf("Counter: %d \r\n", counter);
        IO_OUT(IO_SEGMENT, counter);
        counter += 1;
    }

    return 0;
}
