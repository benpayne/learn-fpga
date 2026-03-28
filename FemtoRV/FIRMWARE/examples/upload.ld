/*
 * Linker script for uploadable programs loaded at 0x4000 by the monitor.
 * The monitor handles stack setup and IO base (gp register).
 * Programs should end with 'return' to go back to the monitor.
 */
MEMORY
{
    USER_RAM (RWX) : ORIGIN = 0x4000, LENGTH = 0x8000
}
SECTIONS
{
    .text : {
        *(.text.startup)
        *(.text)
        *(.rodata*)
        *(.data*)
        *(.sdata*)
        _end = .;
    } > USER_RAM

    .bss : {
        *(.bss*)
        *(.sbss*)
    } > USER_RAM
}
