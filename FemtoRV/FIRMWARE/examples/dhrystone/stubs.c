#include <femtorv32.h>

// Stub — not needed for kernel-loaded programs
void femtosoc_tty_init(void) {}

static int timer_started = 0;
long time() {
   volatile unsigned int *timer = (volatile unsigned int*)(0x400000 + (1 << (2+13)));
   if (!timer_started) {
       *timer = 0xFFFFFFFF;  // Start the hardware timer
       timer_started = 1;
   }
   return (long)*timer;
}

long insn() {
   // Try rdinstret, return 0 if not available
   int insns = 0;
   asm volatile ("rdinstret %0" : "=r"(insns));
   return insns;
}

int has_counters() {
    return 1; 
}
