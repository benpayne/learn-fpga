MEMORY
{
    SDRAM (RWX) : ORIGIN = 0x800000, LENGTH = 0x400000
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
