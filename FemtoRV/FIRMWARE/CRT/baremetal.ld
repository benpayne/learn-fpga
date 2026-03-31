/*
 * linker control script for 'bare metal' executables.
 * Boot ROM in 16KB BRAM at address 0. Main RAM is SDRAM at 0x800000.
 * Stack is set in crt0_baremetal.S to top of SDRAM.
 */
MEMORY
{
   BRAM (RWX) : ORIGIN = 0x0000, LENGTH = 0x4000
}
SECTIONS
{
    .text :
    {
        crt0_baremetal.o (.text) 
        *(.text)
	_end = .;           /* as expected by syscalls.c */
    }
}
