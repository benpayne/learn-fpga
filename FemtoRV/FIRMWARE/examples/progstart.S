# Program entry stub for RetroKernel-loaded programs
# Ensures main() is called at the load address (0x810000)
# Must save/restore ra since 'call main' overwrites it
.section .text.startup
.global _progstart
_progstart:
    addi sp, sp, -16
    sw   ra, 12(sp)     # Save return address to kernel
    call main
    lw   ra, 12(sp)     # Restore return address
    addi sp, sp, 16
    ret                  # Return to kernel
