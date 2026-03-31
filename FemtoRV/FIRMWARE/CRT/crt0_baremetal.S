.include "femtorv32.inc"

.text
.global _start
.type _start, @function

_start:
.option push
.option norelax
     li gp,IO_BASE       #   Base address of memory-mapped IO
.option pop

     # Disable interrupts immediately on startup
     csrw mstatus, zero
     csrw mie, zero

     # Stack at top of SDRAM (8MB: 0x800000-0xFFFFFF)
     # RMW cache handles byte/halfword writes correctly
     li   sp, 0xFFFFF0

# TODO: clear BSS (for this we need a linker script that declares _edata)
#     la t1,_edata
#.L1: sw zero,0(t1)
#     addi t1,t1,4
#     bne t1,sp,.L1	
	
     call main
     tail exit


