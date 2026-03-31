/*
 * RetroKernel linker script
 * Loaded by BIOS to 0x800000 (SDRAM)
 * Kernel code + data in first 64KB, programs load at 0x810000+
 */
MEMORY
{
    KERNEL (RWX) : ORIGIN = 0x800000, LENGTH = 0x10000
}
SECTIONS
{
    .text : {
        *(.text.startup)
        *(.text)
    } > KERNEL
    .rodata : {
        *(.rodata*)
    } > KERNEL
    .data : {
        *(.data*)
        *(.sdata*)
    } > KERNEL
    .bss : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        _bss_end = .;
    } > KERNEL
    _end = .;
}
