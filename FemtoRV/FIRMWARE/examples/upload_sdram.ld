/*
 * Linker script for programs uploaded into SDRAM at 0x800000 by the BIOS
 * monitor's 'L' command and started with 'G 800000'.
 *
 * Entry is _sdramstart (sdramstart.S), which zeroes .bss before calling
 * main(). SDRAM powers up as garbage, so that step is mandatory -- see the
 * comment in sdramstart.S.
 */
MEMORY
{
    SDRAM (RWX) : ORIGIN = 0x800000, LENGTH = 0x400000
}
ENTRY(_sdramstart)
SECTIONS
{
    .text : {
        sdramstart.o (.text.startup)    /* must be first: monitor jumps here */
        *(.text.startup)
        *(.text)
        *(.rodata*)
        *(.data*)
        *(.sdata*)
    } > SDRAM
    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        . = ALIGN(4);
        __bss_end = .;
    } > SDRAM
    /* _end marks the heap base for _sbrk() (CRT/syscalls.c). It MUST come
     * after .bss -- when it sat inside .text the heap overlapped .bss and
     * the first malloc() would corrupt static state. */
    _end = .;
}
