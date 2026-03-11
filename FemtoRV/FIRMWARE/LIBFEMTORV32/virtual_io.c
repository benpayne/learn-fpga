#include <femtorv32.h>

extern int UART_putchar(int);
extern int UART_getchar();

static putcharfunc_t putcharfunc = UART_putchar; 
static getcharfunc_t getcharfunc = UART_getchar; 

void set_putcharfunc(putcharfunc_t f) {
   putcharfunc = f;
}

void set_getcharfunc(getcharfunc_t f) {
   getcharfunc = f;
}

int putchar(int c) {
   wait_cycles(10*FEMTORV32_FREQ); // 10us at 115200 bauds
   if (c == '\n') {
      (*putcharfunc)('\r');
   }
   return (*putcharfunc)(c);
}

int getchar() {
  return (*getcharfunc)();
}
