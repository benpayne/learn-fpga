/*
 * Linker script for programs loaded by RetroKernel at 0x810000
 */
MEMORY
{
    PROGRAM (RWX) : ORIGIN = 0x810000, LENGTH = 0x6F0000
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
    } > PROGRAM
    .bss : {
        *(.bss*)
        *(.sbss*)
    } > PROGRAM
}
