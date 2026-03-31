// RetroKernel - Program Loader
// Loads .bin files from SD card to PROGRAM_BASE and executes them

#include "kernel.h"

// Try to find and run a program
// Returns 1 if program was found and executed, 0 if not found
int load_and_run(const char *name, const char *args) {
    // Build candidate paths to try:
    // 1. name as-is (might be absolute or relative)
    // 2. name + ".bin"
    // 3. /bin/name
    // 4. /bin/name + ".bin"

    char path[MAX_PATH];
    int loaded = -1;

    // Helper: copy string
    int i, j;

    // Try 1: name as-is
    i = 0;
    while (name[i] && name[i] != ' ' && name[i] != '\t' && i < MAX_PATH - 1)
        { path[i] = name[i]; i++; }
    path[i] = '\0';

    loaded = fs_load_file(path, (void *)PROGRAM_BASE, PROGRAM_MAX - PROGRAM_BASE);
    if (loaded > 0) goto run;

    // Try 2: name.bin
    j = i;
    if (j + 4 < MAX_PATH) {
        path[j] = '.'; path[j+1] = 'b'; path[j+2] = 'i'; path[j+3] = 'n'; path[j+4] = '\0';
        loaded = fs_load_file(path, (void *)PROGRAM_BASE, PROGRAM_MAX - PROGRAM_BASE);
        if (loaded > 0) goto run;
    }

    // Try 3: /bin/name
    path[0] = '/'; path[1] = 'b'; path[2] = 'i'; path[3] = 'n'; path[4] = '/';
    i = 5; j = 0;
    while (name[j] && name[j] != ' ' && name[j] != '\t' && i < MAX_PATH - 1)
        path[i++] = name[j++];
    path[i] = '\0';

    loaded = fs_load_file(path, (void *)PROGRAM_BASE, PROGRAM_MAX - PROGRAM_BASE);
    if (loaded > 0) goto run;

    // Try 4: /bin/name.bin
    if (i + 4 < MAX_PATH) {
        path[i] = '.'; path[i+1] = 'b'; path[i+2] = 'i'; path[i+3] = 'n'; path[i+4] = '\0';
        loaded = fs_load_file(path, (void *)PROGRAM_BASE, PROGRAM_MAX - PROGRAM_BASE);
        if (loaded > 0) goto run;
    }

    return 0;  // Not found

run:
    con_set_fg(GPU_LIGHT_GRAY);
    con_puts("Loading ");
    con_dec(loaded);
    con_puts(" bytes from ");
    con_puts(path);
    con_putc('\n');

    // Verify the loaded binary looks valid
    // Check first word isn't 0x00000000 (empty/corrupt) or 0xFFFFFFFF (erased flash)
    volatile uint32_t *code = (volatile uint32_t *)PROGRAM_BASE;
    uint32_t first_word = code[0];
    if (first_word == 0x00000000 || first_word == 0xFFFFFFFF) {
        con_set_fg(GPU_BRIGHT_RED);
        con_puts("Error: invalid program (first word = 0x");
        for (int i = 28; i >= 0; i -= 4) {
            int n = (first_word >> i) & 0xF;
            con_putc(n < 10 ? '0' + n : 'a' + n - 10);
        }
        con_puts(")\n");
        return 1;  // Return 1 so shell doesn't print "unknown command"
    }

    // Place a magic cookie after the program to detect stack overflow
    // (if the program's stack grows into the program area, this gets overwritten)

    // Switch to graphics-safe state: ensure text mode is active on return
    // Save current display state
    con_set_fg(GPU_WHITE);

    // Execute the loaded program
    void (*entry)(void) = (void (*)(void))PROGRAM_BASE;
    entry();

    // Restore gp register (IO_BASE) — program may have clobbered it
    asm volatile (
        ".option push\n"
        ".option norelax\n"
        "li gp, 0x400000\n"
        ".option pop\n"
    );

    // Program returned — restore text mode in case program left graphics mode
    GPU_WRITE(GPU_REG_DISPLAY_MODE, 0);  // Back to character mode
    wait_cycles(1000);

    con_set_fg(GPU_BRIGHT_GREEN);
    con_puts("exit(0)\n");

    return 1;
}
