# Program entry stub for RetroKernel-loaded programs
# Ensures main() is called at the load address (0x810000)
.section .text.startup
.global _progstart
_progstart:
    call main
    ret         # Return to kernel
