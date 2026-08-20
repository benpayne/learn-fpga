/*
 * Linker script for the runq (int8 Q8_0) inference program. Identical
 * layout to llama2.ld (the fp32 sibling) -- same 1 MB code/data region at
 * 0x800000, same reasoning: the actual Q8_0 model at 0x900000 is far
 * smaller than the fp32 one (299,008 vs 1,056,540 bytes, see
 * model_load.h), but the REGION boundary here is unrelated to that and
 * stays put.
 *
 * Uploaded into SDRAM at 0x800000 by the BIOS monitor ('L'), started with
 * 'G 800000'. Entry is _sdramstart (../examples/sdramstart.S), which
 * zeroes .bss before calling main() -- mandatory, SDRAM powers up as
 * garbage.
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
