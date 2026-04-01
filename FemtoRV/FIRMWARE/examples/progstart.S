# Program entry stub for RetroKernel-loaded programs
# Loads argc/argv from ARGS_BASE (0x80FF00) and passes to main(argc, argv)
# Must save/restore ra since 'call main' overwrites it

.equ ARGS_BASE, 0x80FF00

.section .text.startup
.global _progstart
_progstart:
    addi sp, sp, -16
    sw   ra, 12(sp)     # Save return address to kernel

    # Load argc into a0, argv pointer into a1
    li   t0, ARGS_BASE
    lw   a0, 0(t0)      # argc = *(ARGS_BASE + 0)
    addi a1, t0, 4      # argv = ARGS_BASE + 4 (pointer to argv[0])

    call main
    lw   ra, 12(sp)     # Restore return address
    addi sp, sp, 16
    ret                  # Return to kernel
