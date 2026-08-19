# Startup stub for programs uploaded into SDRAM and started by the BIOS
# monitor's 'G' command.
#
# WHY THIS EXISTS:
#   CRT/crt0_baremetal.S has a long-standing TODO to clear .bss, left
#   undone because the linker scripts did not declare the needed symbols.
#   Programs linked into BRAM got away with it: the FPGA initialises block
#   RAM from the bitstream, so their .bss was already zero. Programs
#   uploaded into SDRAM do NOT -- SDRAM powers up as garbage, so every
#   zero-initialised static starts with random data.
#
#   That is not cosmetic. fat_io_lib's fl_init() links its FL_FILE list
#   nodes but never clears the structure bodies, so fl_fopen() would act on
#   a garbage file_data_dirty flag and try to flush a bogus sector.
#
# This stub zeroes .bss, then calls main(). The monitor invokes the load
# address as a plain function pointer, so returning here returns to the
# monitor prompt.

.section .text.startup
.global _sdramstart
_sdramstart:
    addi sp, sp, -16
    sw   ra, 12(sp)

    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b

2:  li   a0, 0              # argc = 0, argv = NULL: these programs take no
    li   a1, 0              # arguments (unlike RetroKernel's progstart.S)
    call main

    lw   ra, 12(sp)
    addi sp, sp, 16
    ret
