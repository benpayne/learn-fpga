/*
 * Linker script for the llama2.c port, uploaded via XMODEM (monitor 'L'
 * command) and run via the monitor 'G' command at 0x800000.
 *
 * Memory layout (see specs/003-llama2-minimal-soc/data-model.md, entity 2):
 *   0x800000 - 0x8FFFFF   1MB   program image      (this linker script)
 *   0x900000 - 0x9FFFFF   1MB   model weights       (loaded from SD card)
 *   0xA00000 - 0xA0FFFF   64KB  vocabulary          (loaded from SD card)
 *   0xA10000 - ~0xAFFFFF  960KB activations/KV cache (runtime, program heap)
 *   0xB00000 - 0xEFFFFF   4MB   free
 *   0xF00000 - 0xFFFFF0   1MB   stack (grows down)
 *
 * The program must not extend past 0x8FFFFF, so LENGTH is capped at 1MB
 * (narrower than examples/upload_sdram.ld, which spans the whole 4MB bank).
 */
MEMORY
{
    SDRAM (RWX) : ORIGIN = 0x800000, LENGTH = 0x100000
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
    } > SDRAM
    .bss : {
        *(.bss*)
        *(.sbss*)
    } > SDRAM
}
