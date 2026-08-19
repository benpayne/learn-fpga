/*
 * Linker script for the llama2 inference program.
 *
 * Uploaded into SDRAM at 0x800000 by the BIOS monitor ('L'), started with
 * 'G 800000'. Capped at 1MB so it cannot run into the model weights at
 * 0x900000 (see specs/003-llama2-minimal-soc/data-model.md entity 2).
 *
 * Entry is _sdramstart (../examples/sdramstart.S), which zeroes .bss before
 * calling main(). SDRAM powers up as garbage, so this is mandatory.
 */
MEMORY
{
    SDRAM (RWX) : ORIGIN = 0x800000, LENGTH = 0x100000
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
    /* Heap base for _sbrk(); must follow .bss, not sit inside .text. */
    _end = .;
}
