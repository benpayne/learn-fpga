# RetroCoprocessor BIOS/OS Architecture

## Overview

A two-layer firmware architecture for the retro computing co-processor, designed to be portable across CPU architectures (RISC-V, 68k, 6502, Z80, 8086).

```
┌─────────────────────────────────────────────┐
│              User Programs                   │
│         (loaded from SD/serial)              │
├─────────────────────────────────────────────┤
│                  OS / Shell                  │
│     (loaded into SDRAM, replaceable)         │
│  - File system, program loader, shell        │
│  - Calls BIOS via jump table                 │
├─────────────────────────────────────────────┤
│                    BIOS                      │
│        (in ROM/BRAM, permanent)              │
│  - Hardware abstraction layer                │
│  - Boot, self-test, device init              │
│  - Jump table at fixed addresses             │
├─────────────────────────────────────────────┤
│              Hardware                        │
│  GPU, Synth, UART, PS2, Timer, SDRAM, SD    │
└─────────────────────────────────────────────┘
```

## Design Principles

1. **BIOS is platform-independent API** — same jump table whether the CPU is RISC-V, 68k, or Z80. The BIOS implementation is CPU-specific, but the interface is identical.

2. **OS is loadable and replaceable** — lives in SDRAM, loaded by BIOS from SD card or serial. Could be a simple shell, a DOS-like OS, or even a BASIC interpreter.

3. **Programs call OS, OS calls BIOS** — programs should not call BIOS directly (though they can for simple systems). This allows the OS to provide higher-level services.

4. **Minimal BIOS, rich OS** — BIOS only does what requires direct hardware access. Everything else goes in the OS.

---

## Memory Map

```
0x000000-0x003FFF   BRAM: BIOS ROM (16KB)
  0x000000-0x0000FF   Jump table (64 entries × 4 bytes)
  0x000100-0x003FFF   BIOS code + data

0x400000+           IO: Memory-mapped devices
  0x400004            UART
  0x401000            GPU (character + graphics)
  0x402000            FM Synth
  0x404000            Timer
  0x408000            Interrupt Controller
  0x410000            PS2 Keyboard
  0x420000            SD Card (future)

0x800000-0xFFFFFF   SDRAM: 8MB
  0x800000-0x80FFFF   OS code + data (64KB reserved)
  0x810000-0xEFFFFF   User program space (~7MB)
  0xF00000-0xFFFFFF   Stack (1MB, grows downward)
```

---

## BIOS Jump Table

Fixed at address 0x000000. Each entry is a function pointer (4 bytes on 32-bit, 2 bytes on 8/16-bit). The OS and programs call these by jumping to the table entry.

### Calling Convention

On RISC-V:
```c
// Call BIOS function by loading address from jump table and calling it
#define BIOS_CALL(n) ((void (*)(void))*(uint32_t*)(n * 4))()
// Or with arguments via registers a0-a3 (standard RISC-V ABI)
```

On 68k:
```asm
; A-line trap or JSR to jump table
JSR (BIOS_BASE + func_num * 4)
```

### Console I/O (0x00-0x0F)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 0 | BIOS_PUTCHAR | a0=char | - | Write character to console (GPU + UART) |
| 1 | BIOS_GETCHAR | - | a0=char | Blocking read from keyboard (PS2 or UART) |
| 2 | BIOS_PUTS | a0=*string | - | Print null-terminated string |
| 3 | BIOS_KBHIT | - | a0=0/1 | Non-blocking: is a key available? |
| 4 | BIOS_GETLINE | a0=*buf, a1=maxlen | a0=len | Read line with echo and editing |
| 5 | BIOS_PUTCHAR_UART | a0=char | - | Write to UART only |
| 6 | BIOS_GETCHAR_UART | - | a0=char | Read from UART only (blocking) |
| 7 | BIOS_UART_STATUS | - | a0=status | UART status (TX ready, RX available) |

### Display (0x10-0x1F)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 16 | BIOS_CLS | - | - | Clear screen |
| 17 | BIOS_SET_CURSOR | a0=row, a1=col | - | Move cursor |
| 18 | BIOS_GET_CURSOR | - | a0=row, a1=col | Get cursor position |
| 19 | BIOS_SET_COLOR | a0=fg, a1=bg | - | Set text colors (4-bit IRGB) |
| 20 | BIOS_SCROLL | a0=lines | - | Scroll screen up N lines |
| 21 | BIOS_SET_MODE | a0=mode | - | Set display mode (0=40col, 1=80col, 2=gfx) |
| 22 | BIOS_GET_MODE | - | a0=mode | Get current display mode |
| 23 | BIOS_GFX_PIXEL | a0=x, a1=y, a2=color | - | Set pixel in graphics mode |
| 24 | BIOS_GFX_FILL | a0=x, a1=y, a2=w, a3=h, a4=color | - | Fill rectangle |
| 25 | BIOS_GFX_SETPAL | a0=idx, a1=r, a2=g, a3=b | - | Set palette entry |
| 26 | BIOS_WAIT_VBLANK | - | - | Wait for vertical blank |

### Audio (0x20-0x2F)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 32 | BIOS_NOTE_ON | a0=voice, a1=note, a2=velocity | - | Start note on FM synth |
| 33 | BIOS_NOTE_OFF | a0=voice | - | Stop note |
| 34 | BIOS_SET_INSTRUMENT | a0=voice, a1=preset | - | Set voice instrument |
| 35 | BIOS_ALL_NOTES_OFF | - | - | Silence all voices |
| 36 | BIOS_PLAY_TONE | a0=freq_hz, a1=duration_ms | - | Simple beep (blocking) |

### Timer (0x30-0x37)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 48 | BIOS_GET_TICKS | - | a0=ticks | Get system tick count (ms since boot) |
| 49 | BIOS_DELAY_MS | a0=ms | - | Blocking delay |
| 50 | BIOS_SET_TIMER | a0=ms, a1=callback | - | Set periodic timer callback |
| 51 | BIOS_CANCEL_TIMER | - | - | Cancel timer callback |

### Memory (0x38-0x3F)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 56 | BIOS_MEMCPY | a0=dst, a1=src, a2=len | - | Copy memory (handles SDRAM alignment) |
| 57 | BIOS_MEMSET | a0=dst, a1=val, a2=len | - | Fill memory |
| 58 | BIOS_MEM_INFO | - | a0=total, a1=free | Get memory info |

### Storage (0x40-0x4F) — Future, for SD card

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 64 | BIOS_DISK_INIT | - | a0=status | Initialize SD card |
| 65 | BIOS_DISK_READ | a0=sector, a1=*buf, a2=count | a0=status | Read sectors |
| 66 | BIOS_DISK_WRITE | a0=sector, a1=*buf, a2=count | a0=status | Write sectors |
| 67 | BIOS_DISK_STATUS | - | a0=status | Get disk status |

### Serial Transfer (0x50-0x57)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 80 | BIOS_XMODEM_RECV | a0=*dest, a1=max_len | a0=bytes_received | Receive file via XMODEM |
| 81 | BIOS_XMODEM_SEND | a0=*src, a1=len | a0=status | Send file via XMODEM |

### System (0x58-0x5F)

| # | Name | Args | Returns | Description |
|---|------|------|---------|-------------|
| 88 | BIOS_RESET | - | - | Warm reset (reinit hardware, restart BIOS) |
| 89 | BIOS_VERSION | - | a0=major, a1=minor | Get BIOS version |
| 90 | BIOS_BOOT_OS | a0=*path | - | Load and boot OS from SD/serial |
| 91 | BIOS_SET_IRQ | a0=irq_num, a1=handler | - | Install interrupt handler |

---

## OS Layer

The OS is loaded into SDRAM (0x800000) by the BIOS. It provides:

### Shell
- Command line interpreter (like DOS COMMAND.COM)
- Built-in commands: DIR, CD, TYPE, COPY, DEL, REN, MEM, RUN
- Executes programs from SD card or SDRAM

### File System
- FAT16/FAT32 on SD card
- Current directory, path navigation
- File open/read/write/close API

### Program Loader
- Load .BIN (flat binary) or .ELF executables
- Relocate to load address
- Set up stack and jump to entry point
- Handle program exit (return to shell)

### OS System Calls

Programs call the OS via a trap or call table at a known address (e.g., 0x800000):

| # | Name | Description |
|---|------|-------------|
| 0 | OS_EXIT | Exit program, return to shell |
| 1 | OS_PUTCHAR | Write character (may add features over BIOS) |
| 2 | OS_GETCHAR | Read character |
| 3 | OS_OPEN | Open file (path, mode) → handle |
| 4 | OS_CLOSE | Close file handle |
| 5 | OS_READ | Read from file |
| 6 | OS_WRITE | Write to file |
| 7 | OS_SEEK | Seek in file |
| 8 | OS_EXEC | Load and execute program |
| 9 | OS_MALLOC | Allocate memory |
| 10 | OS_FREE | Free memory |
| 11 | OS_GETENV | Get environment variable |
| 12 | OS_SETENV | Set environment variable |

---

## Boot Sequence

```
1. Power on → CPU starts at 0x000000 (BRAM)
2. BIOS initializes:
   a. Disable interrupts
   b. Set stack pointer (BRAM top initially)
   c. Initialize SDRAM controller (wait for init)
   d. Move stack to SDRAM
   e. Initialize GPU (clear screen, show banner)
   f. Initialize UART
   g. Initialize PS2 keyboard
   h. Initialize FM synth (silence)
   i. Initialize timer (system tick)
   j. Enable interrupts
3. BIOS self-test:
   a. SDRAM quick test (write/read pattern)
   b. Report memory size
4. BIOS attempts to boot OS:
   a. Check SD card for /BOOT/OS.BIN
   b. If found: load to 0x800000, jump to entry
   c. If not found: check serial for XMODEM upload
   d. If nothing: drop to built-in monitor
5. OS initializes:
   a. Set up file system (mount SD card)
   b. Set up memory allocator
   c. Show OS banner
   d. Enter shell loop
```

---

## Cross-Platform Portability

The BIOS jump table is the **hardware abstraction layer**. To port to a new CPU architecture:

### What changes:
- BIOS implementation (assembly/C for the target CPU)
- Jump table format (4 bytes for 32-bit CPUs, 2 bytes for 16-bit)
- Calling convention (registers vs stack)
- Interrupt handling
- Memory map (may differ by platform)

### What stays the same:
- Jump table function numbers and semantics
- OS source code (if written in C, just recompile)
- Application API (OS system calls)
- File formats on SD card

### Platform-Specific Examples:

**RISC-V (current FemtoRV):**
```c
#define BIOS_PUTCHAR  ((void(*)(int)) *(uint32_t*)0x000000)
#define BIOS_GETCHAR  ((int(*)(void)) *(uint32_t*)0x000004)
// Call: BIOS_PUTCHAR('A');
```

**68k (future retro bus):**
```asm
BIOS_BASE  EQU $F00000     ; BIOS ROM at top of address space
BIOS_PUTCHAR:
    MOVE.L  #'A', D0
    JSR     BIOS_BASE+0    ; Jump table entry 0
    RTS
```

**6502 (future):**
```asm
BIOS_BASE = $FF00           ; Jump table in top of ROM
BIOS_PUTCHAR = BIOS_BASE+0  ; JSR indirect
    LDA #'A'
    JSR BIOS_PUTCHAR
```

---

## Implementation Plan

### Phase 1: BIOS (current monitor → BIOS)
- Refactor monitor.c into BIOS with jump table
- Move existing functions (putchar, getchar, GPU, synth) behind jump table
- Add system tick timer
- Add SDRAM memory test to boot sequence
- Keep built-in monitor as fallback shell

### Phase 2: Minimal OS
- Simple shell with command parsing
- Program loader (load .BIN from XMODEM, execute, return)
- Memory allocator (simple bump allocator)
- OS system call table

### Phase 3: SD Card + File System
- Enable SD card hardware
- FAT16 file system library
- DIR, TYPE, COPY commands
- Load programs from SD card

### Phase 4: Rich OS
- Multi-program support (TSR-style)
- Device driver framework
- Configuration files
- Autoexec-style startup script

---

## Comparison to Historical Systems

| Feature | IBM PC BIOS | Mac Toolbox | Amiga Exec | **Ours** |
|---------|-------------|-------------|------------|----------|
| ROM size | 8-64KB | 256KB-1MB | 256-512KB | **16KB** |
| Jump table | INT 10h/13h/etc | A-line traps | Library vectors | **Address table** |
| OS in RAM | DOS | System | Kickstart+WB | **OS.BIN** |
| Display | Text + CGA/VGA | QuickDraw | Intuition | **GPU registers** |
| Sound | PC speaker + SB | Sound Manager | Paula/Audio | **FM synth** |
| Storage | Floppy/HDD | Floppy/SCSI | Floppy/SCSI | **SD card** |
| Memory | 640KB-16MB | 1-128MB | 256KB-16MB | **8MB SDRAM** |

Our system is closest to the **early IBM PC BIOS + DOS** model in simplicity, with hardware capabilities more like an **Amiga** (custom display, sound, DMA).
