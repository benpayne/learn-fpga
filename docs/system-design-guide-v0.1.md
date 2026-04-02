# UniRetro Bus - System Design Guide

**Draft Version 0.1** | March 2026

Reference motherboard designs for systems built around the UniRetro Bus.

---

## 1. Common Design Elements

All motherboard configurations share these on-board components. Everything else
goes on expansion cards via the UniRetro bus.

### 1.1 On-Board Components

| Component | Purpose |
|-----------|---------|
| CPU (or FPGA) | Host processor |
| SRAM | Main system memory (socketed, expandable) |
| Pi Pico | ROM emulator + firmware development interface |
| UART | Serial console (directly on board, no card needed) |
| PS2 | Keyboard interface (directly on board, no card needed) |
| Bus bridge | CPU ↔ UniRetro bus interface (CPLD, FPGA, or discrete) |
| Clock | System oscillator + bus CLK generation |
| Reset | Power-on reset circuit + manual reset button |
| Power | 5V input, 3.3V regulator, power distribution |

### 1.2 UniRetro Slot Configuration

Minimum 4 slots. All motherboards provide:
- 4× 100-pin (2×50) card edge sockets (accept 8/16/32-bit cards)
- Per-slot /SEL, /IRQ, /BREQ, /BGRANT active traces from bridge
- Bus CLK driven from bridge (derived from CPU clock or independent osc)
- Pull-ups on all active-low bus signals
- Power distribution to all slots (3.3V and 5V rails)
- Optional: 2 additional slots for 6-slot systems

### 1.3 Pi Pico ROM Emulator

The Raspberry Pi Pico (RP2040) serves as a programmable ROM emulator,
eliminating the need to burn EPROMs or flash chips during development.

**How it works:**
- Pico connects to the address bus, data bus, and control signals
- PIO state machines monitor the bus for reads in the ROM address range
- On a ROM read, Pico drives the data bus with the appropriate byte
- Firmware is uploaded to the Pico over USB from a development PC
- Pico can optionally provide a serial console for firmware upload

**Pico GPIO budget:**
```
Data bus:        8 pins  (D0-D7, directly on bus for 8-bit ROM access)
Address bus:     16-19 pins (depends on ROM window size)
/CS or /SEL:     1 pin   (active when ROM range is accessed)
R/W or /OE:      1 pin   (read strobe)
PHI2 or CLK:     1 pin   (bus timing reference)
                ─────
Total:           27-30 pins (Pico has 26 GPIO — tight but workable)
```

**GPIO optimization for larger address spaces:**
- Use active-low directly-connected /CS from address decode logic
- For 6502 (16-bit addr): 8 data + 16 addr + 2 control = 26 pins (exact fit)
- For 68k (24-bit addr): use a latch on upper address bits, or limit ROM to
  64KB window and page the rest
- Alternative: use a Pi Pico 2 (RP2350) which has 30 GPIO, or offload address
  latching to a 74HC573

**Pico firmware features:**
- USB mass storage mode: drag-and-drop firmware .bin files
- USB CDC serial port: terminal access + XMODEM upload
- ROM emulation via PIO: bus-speed response (~50ns achievable)
- Optional: break into monitor on NMI button press

### 1.4 UART

On-board UART provides the primary serial console. Directly connected to the
CPU bus, not on the expansion bus (always available, no card needed).

| System | UART Chip | Interface |
|--------|-----------|-----------|
| 6502 | WDC W65C51N (ACIA) | 6502-native bus timing |
| 68000 | MC68681 (DUART) | 68k-native async bus |
| 68030 | MC68681 or 16C550 | 68k-native or ISA-style |
| FPGA | Soft UART (Verilog) | Directly in fabric |

All systems: USB-to-serial adapter (CH340G or FT232RL) for USB connectivity.
3.3V logic levels.

**Serial parameters default**: 115200 8N1.

### 1.5 PS2 Keyboard Interface

On-board PS2 keyboard port. Directly connected to the CPU bus.

For real CPU boards, two implementation options:

**Option A: CPLD-based (recommended)**
A small CPLD (ATF1504 or EPM3032) implements the PS2 protocol decoder,
scancode FIFO, and bus interface. Same design as a PS2 expansion card but
integrated on the motherboard. Directly generates an interrupt to the CPU.

**Option B: Pi Pico handles PS2**
The Pico has PIO state machines available. One PIO can handle PS2 clock/data
decoding while another handles ROM emulation. The Pico presents decoded
scancodes in a shared register readable by the CPU. Saves a chip but couples
PS2 to the ROM emulator.

For the FPGA board: PS2 decoder is in the FPGA fabric (already have this
working in our design).

### 1.6 SRAM Configuration

All systems use socketed SRAM for easy configuration. Available SRAM chips
in DIP packages:

| Part | Organization | Package | Each | Notes |
|------|-------------|---------|------|-------|
| 62256 | 32K×8 | DIP-28 | 32 KB | Ubiquitous, cheapest |
| 628128 | 128K×8 | DIP-32 | 128 KB | Common |
| AS6C4008 | 512K×8 | DIP-32 | 512 KB | Alliance Memory, readily available |
| AS6C8008 | 1M×8 | DIP-32 | 1 MB | Alliance Memory, largest practical DIP |

For 16-bit and 32-bit data buses, chips are paired (2× for 16-bit, 4× for
32-bit) to provide the full bus width.

**Practical limits of DIP SRAM:**

| Target RAM | Width | Chips | Board Area | Feasible? |
|-----------|-------|-------|------------|-----------|
| 64 KB | 8-bit | 2× 62256 | Small | Easy |
| 512 KB | 16-bit | 2× AS6C4008 | Moderate | Easy |
| 1 MB | 16-bit | 2× AS6C8008 | Moderate | Easy |
| 2 MB | 16-bit | 4× AS6C8008 | Large | Practical |
| 4 MB | 32-bit | 4× AS6C8008 | Large | Practical |
| 8 MB | 32-bit | 8× AS6C8008 | Very large | Pushing it |
| 16 MB | 32-bit | 16× AS6C8008 | Huge | Impractical in DIP |

**For 16 MB**: DIP SRAM is impractical (16 chips, massive board). Options:
- TSOP SRAM on soldered-down daughter card (4× IS61WV102416 = 16 MB)
- SRAM SIMM/DIMM modules (if available)
- Compromise: 4 MB DIP on motherboard + SDRAM expansion card on the bus
- For the FPGA board: use the Colorlight i5's on-board SDRAM (32 MB)

**Recommendation**: Design motherboard with sockets for up to 4 MB DIP SRAM
(practical, hand-solderable). If 16 MB is needed, add an SDRAM or large-SRAM
expansion card on the UniRetro bus. This keeps the motherboard reasonable.

### 1.7 Power Supply

```
Input:          5V DC barrel jack (or USB-C with 5V only)
3.3V rail:      LDO regulator (AMS1117-3.3 or similar), 1A minimum
5V rail:        Direct from input, protected with polarity diode
Per-slot budget: 500 mA at 5V, 300 mA at 3.3V
Total system:   5V @ 3A recommended (CPU + RAM + 4 slots)
```

---

## 2. System A: 6502 Motherboard

### 2.1 Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    6502 Motherboard                              │
│                                                                 │
│  ┌────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐  │
│  │ WDC    │  │ Pi Pico  │  │ PS2 CPLD │  │ SRAM            │  │
│  │ 65C02  │  │ (ROM     │  │ (ATF1504)│  │ 2× 62256 (64KB) │  │
│  │ @ 4MHz │  │  emu)    │  │          │  │ or 2× AS6C4008  │  │
│  └───┬────┘  └────┬─────┘  └────┬─────┘  │ (1 MB)          │  │
│      │            │              │         └───────┬─────────┘  │
│      │     ┌──────┴──────────────┴─────────────────┘            │
│      └─────┤         CPU Local Bus                              │
│            │   A0-A15, D0-D7, PHI2, R/W, /IRQ                  │
│            └──────────────┬─────────────────────────            │
│                           │                                     │
│                    ┌──────┴──────┐                               │
│                    │ Bus Bridge  │                               │
│                    │  (CPLD)     │                               │
│                    │  - Page reg │                               │
│                    │  - PHI2→    │                               │
│                    │    async    │                               │
│                    │  - RDY gen  │                               │
│                    │  - Enum     │                               │
│                    └──────┬──────┘                               │
│                           │                                     │
│         ┌─────────┬───────┴───────┬─────────┐                   │
│       ┌─┴──┐   ┌──┴─┐   ┌──┴─┐   ┌─┴──┐                       │
│       │Slot│   │Slot│   │Slot│   │Slot│  (8-bit cards only)    │
│       │ 0  │   │ 1  │   │ 2  │   │ 3  │                        │
│       └────┘   └────┘   └────┘   └────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 CPU Configuration

| Parameter | Value |
|-----------|-------|
| CPU | WDC W65C02S |
| Package | DIP-40, socketed |
| Clock | 4 MHz (can push to 8-14 MHz with W65C02S) |
| Data bus | 8-bit |
| Address bus | 16-bit (64 KB) |
| Wait states | Via RDY pin (active-low halts CPU) |
| Interrupts | /IRQ (maskable), /NMI (non-maskable) |

### 2.3 Address Map

```
 0x0000 ┌──────────────────────┐
        │ RAM (zero page,      │
        │ stack, working)      │
        │                      │
 0x8000 ├──────────────────────┤  ← 32 KB RAM (62256 #1) or
        │ RAM (continued)      │    up to 512 KB banked (AS6C4008)
        │ or Bank-switched     │
 0xC000 ├──────────────────────┤
        │ I/O Page             │  ← 256 bytes decoded
        │ 0xC000: UART (W65C51)│
        │ 0xC010: PS2 (CPLD)  │
        │ 0xC020: Bus bridge   │
        │   - Control regs     │
        │   - Page register    │
        │   - IRQ status       │
        │ 0xC030: Timer (CPLD) │
        │ 0xC040-CF: reserved  │
 0xC100 ├──────────────────────┤
        │ Bus Window (4 KB)    │  ← Mapped to UniRetro bus
        │ Page register sets   │    via page register in bridge
        │ which 4KB chunk of   │
        │ the 24-bit bus space │
        │ appears here         │
 0xD000 ├──────────────────────┤
        │ Reserved / I/O       │
 0xE000 ├──────────────────────┤
        │ ROM (Pi Pico)        │  ← 8 KB ROM window
        │ Pico emulates this   │    (Pico can bank-switch too)
 0xFFFA ├──────────────────────┤
        │ NMI vector           │  ← In ROM (Pico) space
 0xFFFC │ RESET vector         │
 0xFFFE │ IRQ vector           │
 0xFFFF └──────────────────────┘
```

### 2.4 Bank Switching (for >32KB RAM)

With the AS6C4008 (512K×8), the 6502 can access much more than 64KB using
a bank register:

```
Bank register at 0xC028 (in I/O page):
  Bits 0-3: Select 32KB bank (0-15) mapped at 0x0000-0x7FFF
  Bits 4-7: Reserved

512KB = 16 banks × 32KB. Bank 0 is the boot bank.
The upper 32KB (0x8000-0xFFFF) is not banked (I/O + ROM always visible).
```

Alternatively, use the AS6C8008 (1M×8) for 32 banks of 32KB.

### 2.5 Bus Bridge

The 6502 bridge is the most complex of the real-CPU designs due to the
synchronous-to-asynchronous conversion.

**Implementation**: CPLD (ATF1504AS or EPM3064) or small FPGA (iCE40LP1K).

**Functions:**
1. Address decode: detect 0xC100-0xCFFF as bus window
2. Page register: 12-bit register provides A12-A23 to bus
3. PHI2-to-async: convert 6502 synchronous cycle to /AS+/DS+/DTACK handshake
4. Wait state generation: hold RDY low until /DTACK returns
5. Slot table: 4 entries (base address, size, present, width)
6. Interrupt aggregation: OR all slot /IRQs into CPU /IRQ
7. Enumeration mode: manually assert /SEL per slot for config ROM access
8. Bus clock: divide PHI2 or use independent oscillator for CLK

**Bridge control registers (at 0xC020-0xC02F):**

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| 0xC020 | BUS_STATUS | R | Slots present bitmask |
| 0xC021 | BUS_CONTROL | W | Bit 0: enum mode |
| 0xC022 | ENUM_SLOT | W | Slot number for enumeration |
| 0xC023 | IRQ_STATUS | R | Slot interrupt pending bitmask |
| 0xC024 | IRQ_CLEAR | W | Write 1 to clear slot IRQ |
| 0xC025 | IRQ_ENABLE | R/W | Slot interrupt enable mask |
| 0xC026 | PAGE_REG_LO | W | Bus page register bits 12-15 |
| 0xC027 | PAGE_REG_HI | W | Bus page register bits 16-23 |
| 0xC028 | RAM_BANK | W | RAM bank select (bits 0-3) |

**Bus cycle timing (4 MHz PHI2):**

```
PHI2 period = 250ns

6502 asserts address at PHI2 rising edge
Bridge must respond before PHI2 falling edge (125ns later)

If card responds within 125ns: zero wait states (best case)
If card is slower: bridge holds RDY low, stretching PHI2

Worst case with slow card: 2-3 wait states = 500-750ns per access
Typical: 1 wait state = 375ns (fine for most cards)
```

### 2.6 Card Compatibility

| Card Width | Works? | How |
|-----------|--------|-----|
| 8-bit | Yes (native) | Direct, SIZ=00 |
| 16-bit | 8-bit mode only | Bridge always issues SIZ=00 |
| 32-bit | 8-bit mode only | Bridge always issues SIZ=00 |

All cards work, but 16-bit and 32-bit cards operate at 8-bit width only.
This is by design — the 6502 data bus is 8 bits. The card still auto-configs
correctly (enumeration is always 8-bit).

### 2.7 Bill of Materials (Key Components)

| Component | Part | Package | Qty |
|-----------|------|---------|-----|
| CPU | WDC W65C02S | DIP-40 | 1 |
| SRAM | 62256 or AS6C4008 | DIP-28/32 | 2 |
| UART | WDC W65C51N | DIP-28 | 1 |
| ROM Emulator | Raspberry Pi Pico | Module | 1 |
| PS2 Controller | ATF1504AS (CPLD) | PLCC-44 | 1 |
| Bus Bridge | ATF1504AS (CPLD) | PLCC-44 | 1 |
| USB-Serial | CH340G | SOP-16 | 1 |
| Oscillator | 4 MHz (or 8 MHz) | DIP-8 | 1 |
| Voltage Reg | AMS1117-3.3 | SOT-223 | 1 |
| Bus Sockets | 2×50 card edge | PCB mount | 4 |
| Decoupling | 100nF ceramic | 0805 | ~20 |

---

## 3. System B: 68000 Motherboard

### 3.1 Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    68000 Motherboard                             │
│                                                                 │
│  ┌────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐  │
│  │MC68000 │  │ Pi Pico  │  │ PS2 CPLD │  │ SRAM (16-bit)   │  │
│  │@ 8 MHz │  │ (ROM     │  │ or Pico  │  │ 2× AS6C4008     │  │
│  │        │  │  emu)    │  │  PIO #2  │  │ = 1 MB          │  │
│  └───┬────┘  └────┬─────┘  └────┬─────┘  │ up to           │  │
│      │            │              │         │ 4× AS6C8008     │  │
│      │     ┌──────┴──────────────┴─────────┤ = 4 MB          │  │
│      └─────┤       CPU Local Bus           └───────┬─────────┘  │
│            │  A1-A23, D0-D15, /AS, /UDS, /LDS,     │            │
│            │  /DTACK, R/W, FC0-2, /IPL0-2           │            │
│            └──────────────┬──────────────────────────            │
│                           │                                     │
│                    ┌──────┴──────┐                               │
│                    │ Bus Bridge  │                               │
│                    │  (CPLD or   │                               │
│                    │  74-series) │                               │
│                    │  - Nearly   │                               │
│                    │    direct   │                               │
│                    │  - UDS/LDS  │                               │
│                    │    → SIZ    │                               │
│                    │  - IPL enc  │                               │
│                    └──────┬──────┘                               │
│                           │                                     │
│         ┌─────────┬───────┴───────┬─────────┐                   │
│       ┌─┴──┐   ┌──┴─┐   ┌──┴─┐   ┌─┴──┐                       │
│       │Slot│   │Slot│   │Slot│   │Slot│  (8/16-bit cards)      │
│       │ 0  │   │ 1  │   │ 2  │   │ 3  │                        │
│       └────┘   └────┘   └────┘   └────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 CPU Configuration

| Parameter | Value |
|-----------|-------|
| CPU | Motorola MC68000 (or MC68SEC000 for modern production) |
| Package | DIP-64, socketed |
| Clock | 8 MHz (MC68000-8) or 10 MHz (MC68000-10) |
| Data bus | 16-bit |
| Address bus | 24-bit (A1-A23, byte select via UDS/LDS) |
| Wait states | Via /DTACK (directly compatible with UniRetro) |
| Interrupts | /IPL0-2 (3-bit encoded priority level, active-low) |
| Bus arbitration | /BR, /BG, /BGACK (for DMA support) |

Note: The MC68SEC000 is a modern CMOS equivalent of the 68000, still in
production, runs at 20 MHz, and is pin-compatible. Recommended over original
NMOS parts.

### 3.3 Address Map

```
 0x000000 ┌──────────────────────┐
          │ ROM (Pi Pico)        │  ← Exception vectors + boot code
          │ 64 KB window         │    Pico needs 16 addr + 8 data + ctrl
          │                      │    Upper data byte directly driven or
 0x010000 ├──────────────────────┤    via latch for 16-bit reads
          │ Reserved             │
 0x040000 ├──────────────────────┤
          │ RAM                  │  ← 1 MB (2× AS6C4008)
          │ 1 MB                 │    or 4 MB (4× AS6C8008)
          │ (up to 4 MB with    │    16-bit wide (paired chips)
          │  4× AS6C8008)       │
 0x140000 ├──────────────────────┤  (or 0x440000 with 4 MB)
          │ Unused               │
 0x800000 ├──────────────────────┤
          │ UniRetro Bus Window  │  ← Full 8 MB window
          │ (all 4 slots mapped) │    Direct address passthrough
          │ Slot 0: assigned by  │    No page register needed!
          │ enum at aligned addr │    24-bit bus address =
          │ Slot 1: ...         │    CPU address - 0x800000
          │ Slot 2: ...         │
          │ Slot 3: ...         │
 0xF00000 ├──────────────────────┤
          │ I/O Devices          │
          │ 0xF00000: UART      │  ← MC68681 DUART
          │ 0xF00040: PS2       │  ← CPLD or Pico PIO
          │ 0xF00080: Bridge    │  ← Bridge control registers
          │ 0xF000C0: Timer     │  ← Optional on-board timer
          │ 0xF00100-0xF0FFFF:  │
          │   reserved I/O      │
 0xFFFFFF └──────────────────────┘
```

### 3.4 Bus Bridge

The 68000 bridge is the simplest of all designs. The UniRetro bus protocol
is modeled on the 68000 bus.

**Implementation**: Can be built with 74-series logic (3-5 chips) or a
single small CPLD.

**Signal mapping (active bus cycle):**

| 68000 Signal | UniRetro Signal | Conversion |
|-------------|-----------------|------------|
| A1-A23 | A1-A23 | Direct (offset by bus window base) |
| D0-D15 | D0-D15 | Direct |
| /AS | /AS | Direct |
| /UDS + /LDS | /DS + SIZ | See table below |
| /DTACK | /DTACK | Direct |
| R/W | R/W | Direct |
| FC0-FC2 | (not used) | Could route to reserved pins |

**UDS/LDS to SIZ + /DS translation:**

| /UDS | /LDS | Operation | SIZ1 | SIZ0 | /DS |
|------|------|-----------|------|------|-----|
| 0 | 0 | Word (16-bit) | 0 | 1 | 0 |
| 0 | 1 | Upper byte | 0 | 0 | 0 |
| 1 | 0 | Lower byte | 0 | 0 | 0 |
| 1 | 1 | No transfer | x | x | 1 |

```
/DS = /UDS AND /LDS  (either strobe active = transfer active)
     actually: /DS = NOT (/UDS NAND /LDS) — asserted when either asserted
SIZ0 = NOT /UDS AND NOT /LDS  (both active = word transfer)
SIZ1 = 0 (68000 never does 32-bit transfers)
```

**8-bit card access:**
When a 68000 does a word read from an 8-bit card, the bridge automatically
runs two 8-bit cycles:
1. Read even byte (A0=0), place on D8-D15
2. Read odd byte (A0=1), place on D0-D7
3. Assert /DTACK to 68000

This adds one bus cycle of latency for word accesses to 8-bit cards.
Byte accesses to 8-bit cards are single-cycle, no penalty.

**Interrupt mapping:**
The 68000 uses a 3-bit priority-encoded interrupt input (/IPL0-2).
The bridge provides a simple priority encoder:

```
Slot 3 interrupt → IPL level 6 (highest)
Slot 2 interrupt → IPL level 5
Slot 1 interrupt → IPL level 4
Slot 0 interrupt → IPL level 3
On-board PS2     → IPL level 2
On-board UART    → IPL level 1
No interrupt     → IPL level 0 (all /IPL lines high)

Priority encoder: 3-to-8 (74LS148) with slot /IRQ inputs
```

The interrupt vector is provided during the IACK cycle. The bridge places
the appropriate vector on D0-D7 when /AS is asserted with FC=111 (CPU space)
and A1-A3 encoding the acknowledged level. This is standard 68000 autovector
or vectored interrupt handling.

**DMA support:**
The 68000 has native bus arbitration (/BR, /BG, /BGACK). The bridge maps
these directly:

```
Any slot /BREQ asserted → assert /BR to 68000
68000 asserts /BG (grants bus)
Bridge asserts /BGRANT[n] to winning slot
Slot asserts /BBUSY, bridge asserts /BGACK to 68000
DMA transfer proceeds
Slot releases /BBUSY, bridge releases /BGACK
68000 reclaims bus
```

**Bus error timeout:**
A watchdog timer in the bridge monitors /DTACK. If no response within 10µs,
the bridge asserts /BERR to the 68000, which takes a bus error exception.
At 8 MHz, 10µs = 80 CPU clocks — generous for any reasonable card.

### 3.5 Pi Pico ROM Interface (68000)

The 68000's 16-bit bus complicates the Pico ROM interface slightly. The Pico
only has 26 GPIO, but we need 16 address + 16 data + 2 control = 34 pins.

**Solution: 8-bit ROM with CPU wait states**

The simplest approach: Pico emulates an 8-bit ROM. The 68000 reads it as
two byte accesses per word (automatic when /DTACK is handled per-byte).
Performance impact is only at boot and firmware load — not runtime.

```
Pico GPIO:
  A1-A16    → 16 pins (64 KB ROM window)
  D0-D7     → 8 pins
  /CS       → 1 pin (from address decode)
  /LDS      → 1 pin (directly from 68000 — lower byte strobe)
              ──
              26 pins (exact fit)

ROM access sequence:
  68000 reads word at ROM address
  /UDS asserts → bridge requests upper byte from Pico (A0=0)
  Pico places byte on D0-D7, bridge routes to D8-D15
  /LDS asserts → bridge requests lower byte from Pico (A0=1)
  Pico places byte on D0-D7, bridge routes to D0-D7
  /DTACK asserted after both bytes ready
```

Alternatively, use a 74HC573 latch to capture A17-A23 on /AS edge, giving
128 KB-8 MB ROM window with only 8 data + 8 low-addr + 1 latch strobe + 2
control = 19 Pico pins used, with 7 GPIO free for PS2 and other uses.

### 3.6 SRAM Configuration (68000)

16-bit wide SRAM requires paired chips:

```
Configuration A: 1 MB (moderate)
  2× AS6C4008 (512K×8) DIP-32
  Chip 1: D0-D7  (active on /LDS)
  Chip 2: D8-D15 (active on /UDS)
  A1-A19 → chip A1-A19
  Total: 2 DIP-32 sockets

Configuration B: 4 MB (maximum practical DIP)
  4× AS6C8008 (1M×8) DIP-32
  Chips 1,2: Bank 0 (A1-A20, 2 MB)
  Chips 3,4: Bank 1 (A1-A20, 2 MB)
  A21 selects bank
  Total: 4 DIP-32 sockets
```

### 3.7 Bill of Materials (Key Components)

| Component | Part | Package | Qty |
|-----------|------|---------|-----|
| CPU | MC68SEC000 or MC68000 | DIP-64 | 1 |
| SRAM | AS6C4008 or AS6C8008 | DIP-32 | 2 or 4 |
| UART | MC68681 (DUART) | DIP-48 | 1 |
| ROM Emulator | Raspberry Pi Pico | Module | 1 |
| PS2 Controller | ATF1504AS (CPLD) | PLCC-44 | 1 |
| Bus Bridge | 74HC logic or CPLD | DIP/PLCC | 3-5 or 1 |
| USB-Serial | CH340G | SOP-16 | 1 |
| Oscillator | 8 MHz or 16 MHz | DIP-8/14 | 1 |
| Voltage Reg | AMS1117-3.3 | SOT-223 | 1 |
| Bus Sockets | 2×50 card edge | PCB mount | 4 |
| Priority Enc | 74LS148 | DIP-16 | 1 |
| Address Latch | 74HC573 | DIP-20 | 1 |

---

## 4. System C: 68030 Motherboard

### 4.1 Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    68030 Motherboard                             │
│                                                                 │
│  ┌────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐  │
│  │MC68030 │  │ Pi Pico  │  │ PS2 CPLD │  │ SRAM (32-bit)   │  │
│  │@ 25MHz │  │ (ROM     │  │          │  │ 4× AS6C8008     │  │
│  │        │  │  emu)    │  │          │  │ = 4 MB          │  │
│  │MC68882 │  └────┬─────┘  └────┬─────┘  │ (expandable)    │  │
│  │ (FPU)  │       │              │         └───────┬─────────┘  │
│  └───┬────┘┌──────┴──────────────┴─────────────────┘            │
│      └─────┤       CPU Local Bus                                │
│            │  A0-A31, D0-D31, /AS, /DS,                         │
│            │  SIZ0-1, /DSACK0-1, R/W, FC0-2                    │
│            └──────────────┬─────────────────────────            │
│                           │                                     │
│                    ┌──────┴──────┐                               │
│                    │ Bus Bridge  │                               │
│                    │  (CPLD)     │                               │
│                    │  - DTACK +  │                               │
│                    │    WIDTH →  │                               │
│                    │    DSACK    │                               │
│                    │  - /CIIN    │                               │
│                    │  - Enum     │                               │
│                    └──────┬──────┘                               │
│                           │                                     │
│         ┌─────────┬───────┴───────┬─────────┐                   │
│       ┌─┴──┐   ┌──┴─┐   ┌──┴─┐   ┌─┴──┐                       │
│       │Slot│   │Slot│   │Slot│   │Slot│  (8/16/32-bit cards)   │
│       │ 0  │   │ 1  │   │ 2  │   │ 3  │                        │
│       └────┘   └────┘   └────┘   └────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 CPU Configuration

| Parameter | Value |
|-----------|-------|
| CPU | Motorola MC68030 |
| Package | PGA-128 or QFP-128, socketed (PGA preferred) |
| Clock | 25 MHz (MC68030RC25) or 33 MHz (MC68030FE33) |
| Data bus | 32-bit |
| Address bus | 32-bit (A0-A31), 24-bit used for bus |
| Wait states | Via /DSACK0 + /DSACK1 (dynamic bus sizing!) |
| Interrupts | /IPL0-2 (same as 68000) |
| Cache | 256B data + 256B instruction (on-chip) |
| MMU | On-chip (can mark bus window cache-inhibited) |
| FPU socket | Optional MC68882 coprocessor |

### 4.3 Address Map

```
 0x00000000 ┌──────────────────────┐
            │ ROM (Pi Pico)        │  ← Boot vectors at 0x00000000
            │ 256 KB window        │    (68030 fetches SSP + PC from
            │                      │     0x00000000 on reset)
 0x00040000 ├──────────────────────┤
            │ Reserved             │
 0x00100000 ├──────────────────────┤
            │ RAM                  │  ← 4 MB (4× AS6C8008)
            │ 4 MB                 │    32-bit wide (4 chips)
            │                      │    Cacheable, full speed
 0x00500000 ├──────────────────────┤
            │ Unused               │
 0x00800000 ├──────────────────────┤
            │ UniRetro Bus Window  │  ← Full 8 MB mapped
            │ (all 4 slots)        │    MMU marks cache-inhibited
            │                      │    /CIIN asserted by bridge
            │                      │    DSACK encodes card width
 0x01000000 ├──────────────────────┤
            │ Extended RAM         │  ← Future: up to 12 MB more
            │ (if populated)       │    with additional SRAM sockets
 0x0F000000 ├──────────────────────┤
            │ I/O Devices          │  ← Cache-inhibited
            │ 0x0F000000: UART    │
            │ 0x0F000100: PS2     │
            │ 0x0F000200: Bridge  │
            │ 0x0F000300: Timer   │
 0x0FFFFFFF └──────────────────────┘
            (only 28 bits decoded for simplicity)
```

### 4.4 Bus Bridge

The 68030 bridge is the simplest of all. The 68030's /DSACK mechanism handles
bus width negotiation automatically.

**Implementation**: Small CPLD (ATF1504 or EPM3064). Less logic than even
the 68000 bridge.

**The key insight — /DSACK does the width conversion for us:**

When a UniRetro card asserts /DTACK, the bridge reads the card's WIDTH pins
and translates to the appropriate /DSACK encoding:

| Card WIDTH | /DSACK1 | /DSACK0 | Meaning | CPU Action |
|-----------|---------|---------|---------|------------|
| 8-bit | 1 | 0 | 8-bit port | CPU auto-runs extra cycles |
| 16-bit | 0 | 1 | 16-bit port | CPU auto-runs extra cycles (if 32-bit transfer) |
| 32-bit | 0 | 0 | 32-bit port | Single cycle |

**This is the entire bridge width-conversion logic:**
```verilog
// When card asserts /DTACK, translate WIDTH to DSACK
assign DSACK0_n = DTACK_n ? 1'b1 :
                  (card_width == 2'b00) ? 1'b0 :  // 8-bit: DSACK=01
                  (card_width == 2'b01) ? 1'b1 :  // 16-bit: DSACK=10
                  1'b0;                            // 32-bit: DSACK=00

assign DSACK1_n = DTACK_n ? 1'b1 :
                  (card_width == 2'b00) ? 1'b1 :  // 8-bit: DSACK=01
                  (card_width == 2'b01) ? 1'b0 :  // 16-bit: DSACK=10
                  1'b0;                            // 32-bit: DSACK=00
```

The 68030 CPU handles all byte lane steering internally. No external logic
needed for width conversion. The bridge is essentially transparent.

**Cache inhibit:**
The bridge asserts /CIIN (cache inhibit in) for all UniRetro bus accesses.
This prevents the 68030's data cache from caching I/O register reads.
Single wire, directly from address decode.

**Signal mapping:**

| 68030 Signal | UniRetro Signal | Conversion |
|-------------|-----------------|------------|
| A0-A23 | A0-A23 | Direct (lower 24 bits) |
| D0-D31 | D0-D31 | Direct |
| /AS | /AS | Direct |
| /DS | /DS | Direct |
| SIZ0-SIZ1 | SIZ0-SIZ1 | Direct |
| /DSACK0-1 | /DTACK + WIDTH | Translation (see above) |
| R/W | R/W | Direct |
| /CIIN | (generated) | Asserted for bus window addresses |

**What's NOT connected:**
- /CBACK, /CBREQ (burst — not supported, just leave disconnected)
- /AVEC (autovector — directly active for bus interrupts, active for I/O)

### 4.5 Pi Pico ROM Interface (68030)

Same challenge as the 68000 but worse: 32-bit data bus. The Pico still only
provides 8-bit data.

**Solution**: Same as 68000 — Pico presents an 8-bit ROM. The 68030's /DSACK
mechanism handles it automatically:

```
68030 reads 32-bit word from ROM:
  Bridge asserts DSACK = 8-bit (01)
  68030 automatically performs 4 byte reads
  Bridge routes each Pico byte to correct lane
  68030 assembles 32-bit word internally
```

Boot is slower (4× cycles for instruction fetches from ROM) but once code
is copied to SRAM, execution is full-speed. Standard practice: the reset
handler copies ROM to RAM and jumps there.

**Pico GPIO allocation:**

```
A0-A17    → 18 pins (256 KB ROM window)
D0-D7     → 8 pins
              ──
              26 pins

/CS from address decode logic (active-low)
derived from 68030 /AS — directly usable
```

### 4.6 SRAM Configuration (68030)

32-bit wide SRAM requires four chips per bank:

```
Configuration A: 4 MB (recommended base)
  4× AS6C8008 (1M×8) DIP-32
  Chip 1: D0-D7   (active on byte lane 0)
  Chip 2: D8-D15  (active on byte lane 1)
  Chip 3: D16-D23 (active on byte lane 2)
  Chip 4: D24-D31 (active on byte lane 3)
  A2-A20 → chip A0-A18
  Byte enables from SIZ + A0-A1 decode
  Total: 4 DIP-32 sockets

Configuration B: 8 MB (extended, if board space allows)
  8× AS6C8008, banked
  A21 selects bank
  Total: 8 DIP-32 sockets
```

For 16 MB: not practical in DIP. Use an SRAM or SDRAM expansion card on the
UniRetro bus. A 32-bit SRAM card with 4× IS61WV102416 (2M×16 TSOP) provides
16 MB with no DIP constraints.

### 4.7 FPU Socket

The MC68882 FPU is optional but recommended for the 68030 system. It connects
directly to the 68030's coprocessor interface:

- /CS (from 68030 coprocessor protocol)
- Shares the data bus D0-D31
- Same clock as 68030
- PGA-68 or PLCC-68 socket, next to the CPU

### 4.8 Bill of Materials (Key Components)

| Component | Part | Package | Qty |
|-----------|------|---------|-----|
| CPU | MC68030RC25 | PGA-128 | 1 |
| FPU (optional) | MC68882RC25 | PGA-68 | 0-1 |
| SRAM | AS6C8008 | DIP-32 | 4-8 |
| UART | MC68681 or 16C550 | DIP-48/40 | 1 |
| ROM Emulator | Raspberry Pi Pico | Module | 1 |
| PS2 Controller | ATF1504AS | PLCC-44 | 1 |
| Bus Bridge | ATF1504AS | PLCC-44 | 1 |
| USB-Serial | CH340G | SOP-16 | 1 |
| Oscillator | 25 MHz | DIP-8/14 | 1 |
| Voltage Reg | AMS1117-3.3 | SOT-223 | 1 |
| Bus Sockets | 2×50 card edge | PCB mount | 4 |
| Address Decode | 74HC138 + 74HC00 | DIP | 2-3 |
| Byte Enable | GAL16V8 or CPLD | DIP-20/PLCC | 1 |

---

## 5. System D: FPGA Motherboard

### 5.1 Overview

The FPGA motherboard replaces the CPU, bridge, UART, PS2, and timer with a
single FPGA. Soft cores can be loaded to emulate different processors.

```
┌─────────────────────────────────────────────────────────────────┐
│                    FPGA Motherboard                              │
│                                                                 │
│  ┌────────────────────────────┐  ┌──────────┐                  │
│  │         FPGA (ECP5)        │  │ Pi Pico  │                  │
│  │                            │  │ (firmware │                  │
│  │  ┌──────────┐ ┌─────────┐ │  │  upload   │                  │
│  │  │ Soft CPU │ │ Bus     │ │  │  + ROM    │                  │
│  │  │ 6502 /   │ │ Bridge  │ │  │  emu)     │                  │
│  │  │ FemtoRV /│ │ (Vlog)  │ │  └────┬─────┘                  │
│  │  │ TG68 /   │ │         │ │       │                          │
│  │  │ ao68000  │ │         │ │  ┌────┴──────┐                  │
│  │  └────┬─────┘ └────┬────┘ │  │ SRAM      │                  │
│  │       │            │      │  │ (optional  │                  │
│  │  ┌────┴────────────┘      │  │  external) │                  │
│  │  │ UART (soft)            │  └────┬──────┘                  │
│  │  │ PS2  (soft)            │       │                          │
│  │  │ Timer (soft)           ├───────┘                          │
│  │  │ Interrupt Ctrl (soft)  │                                  │
│  │  └────────────────────────┘                                  │
│  └────────────┬───────────────┘                                 │
│               │                                                 │
│         ┌─────┴───┬───────────┬─────────┐                       │
│       ┌─┴──┐   ┌──┴─┐   ┌──┴─┐   ┌──┴──┐                      │
│       │Slot│   │Slot│   │Slot│   │Slot  │ (8/16/32-bit cards)  │
│       │ 0  │   │ 1  │   │ 2  │   │ 3   │                       │
│       └────┘   └────┘   └────┘   └─────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 FPGA Selection

| Parameter | Recommended | Alternative |
|-----------|-------------|-------------|
| FPGA | Lattice ECP5-25F | ECP5-45F or ECP5-85F |
| Package | caBGA-256 (via module) or TQFP-144 | Same |
| LUTs | 24K (ECP5-25) | 44K / 84K |
| Block RAM | 56 × 18Kb = 126 KB | 108 / 208 KB |
| PLLs | 2 | 2 / 4 |
| SERDES | No (25F) | Yes (45F, 85F) |
| GPIO | ~100 (caBGA-256) | Same |

**Recommendation**: Use the ECP5-25F via a module board (Colorlight i5 or
similar) for prototyping. For a production motherboard, solder down an
ECP5-45F in TQFP-144 for better GPIO access and more LUTs.

**FPGA GPIO budget:**

```
UniRetro bus (4 slots):
  D0-D31              32 pins
  A0-A23              24 pins
  /AS, /DS, /DTACK     3 pins
  R/W, SIZ0, SIZ1      3 pins
  /SEL[0-3]            4 pins  (directly driven per-slot)
  /IRQ[0-3]            4 pins  (directly sensed per-slot)
  /BREQ[0-3]           4 pins
  /BGRANT[0-3]         4 pins
  /BBUSY, /BTERM       2 pins
  /SNOOP, /BERR        2 pins
  /RESET, CLK          2 pins
  WIDTH0-1             2 pins  (directly sensed per-slot = 8 pins)
                      ─────
  Bus subtotal:        94 pins (with 4× WIDTH sensing = 100)

On-board I/O:
  UART TX, RX           2 pins
  PS2 CLK, DATA         2 pins
  USB-serial (if separate) 2 pins
  Pi Pico interface     ~10-20 pins (SPI or parallel)
  LEDs (debug)          4 pins
  Reset button          1 pin
                      ─────
  I/O subtotal:        ~21-31 pins

Total:                 ~121-131 pins
```

This is tight for the ECP5-25 in caBGA-256 (~100 usable GPIO). Solutions:
- Reduce to 16-bit external bus (D0-D15 only, FPGA does 32→16 conversion)
- Use ECP5-45F or larger package
- Multiplex WIDTH sensing (read during enumeration only, one set of pins)
- Use Colorlight i5 which has 2× PMOD headers plus direct pin access

**Practical approach**: Run a 16-bit external data bus from the FPGA. The
FPGA internally operates at 32-bit but serializes to 16-bit for the physical
bus. This halves the data pin count (16 vs 32) and still allows 32-bit cards
to work (the bridge runs two 16-bit cycles). Pin budget drops to ~83 for
the bus, well within range.

Alternatively, if using a Colorlight i5 module, connect a CPLD (ATF1504)
as a pin expander for the upper 16 data bits, controlled via a few FPGA
pins. This keeps full 32-bit bus width with limited FPGA GPIO.

### 5.3 Soft Core Options

| Core | ISA | LUTs (approx) | RAM | Status |
|------|-----|---------------|-----|--------|
| FemtoRV quark | RV32I | 1,000 | 8 KB | Proven, our project |
| FemtoRV intermissum | RV32IM + IRQ | 1,300 | 16-64 KB | Proven, our project |
| FemtoRV petitbateau | RV32IMFC | 2,000 | 64 KB | Proven, our project |
| arlet-65c02 | 6502 | ~800 | External | Well-tested, Verilog |
| ag_6502 | 65C02 | ~1,200 | External | Cycle-accurate |
| ao68000 | 68000 | ~4,000 | External | Open source, Verilog |
| TG68 | 68020-ish | ~5,000 | External | VHDL, full-featured |
| TV80 | Z80 | ~1,500 | External | VHDL, well-tested |

**Resource budget (ECP5-25F, 24K LUTs):**

```
Soft CPU (68000-class)    ~5,000 LUTs
Bus bridge                  ~500 LUTs
UART                        ~200 LUTs
PS2 decoder                 ~300 LUTs
Interrupt controller        ~200 LUTs
Timer                       ~100 LUTs
Bus enumeration logic       ~300 LUTs
                          ──────
Subtotal                  ~6,600 LUTs (27% of ECP5-25)

Remaining for user logic: ~17,000 LUTs
Block RAM for CPU:         32-64 KB (uses 18-36 of 56 BRAMs)
```

Even a 68000 soft core fits comfortably in the ECP5-25F with room to spare.

### 5.4 Memory Architecture

The FPGA system has several memory options:

**Internal Block RAM (fast, limited):**
- 126 KB total on ECP5-25F
- Used for CPU program/data memory (32-64 KB typical)
- Single-cycle access
- Initialized from bitstream (Pi Pico → FPGA SPI flash)

**External SRAM (moderate speed, larger):**
- Optional DIP sockets on motherboard: 2× AS6C4008 = 1 MB
- 16-bit wide (paired chips)
- Access time: 55ns (AS6C4008-55) → 1-2 wait states at 25 MHz
- Connected to FPGA GPIO, independent of UniRetro bus

**On-module SDRAM (if using Colorlight i5):**
- 2× 16 MB SDRAM on the Colorlight i5 module
- 32 MB total, 16-bit wide per chip
- Requires SDRAM controller in FPGA (~800 LUTs)
- Higher latency but massive capacity

**Via UniRetro bus (expansion cards):**
- SRAM or SDRAM expansion cards
- Limited by bus speed and card response time
- Good for bulk storage, not primary program memory

### 5.5 Pi Pico Interface (FPGA)

The FPGA system has the most flexible Pico interface since the FPGA can
implement any protocol.

**Option A: SPI (minimal pins)**
```
Pico ←→ FPGA via SPI:
  SCLK    1 pin
  MOSI    1 pin
  MISO    1 pin
  /CS     1 pin
          ─────
          4 pins

Use: Firmware upload to FPGA block RAM via SPI writes.
     Pico sends binary, FPGA DMA writes to BRAM.
     Slow for large images but minimal pin usage.
```

**Option B: Parallel (fast, more pins)**
```
Pico ←→ FPGA via parallel:
  D0-D7     8 pins
  ADDR[2:0] 3 pins  (register select)
  /WR       1 pin
  /RD       1 pin
  /CS       1 pin
            ─────
            14 pins

Use: Fast firmware upload. Register-based interface.
     Also provides: serial console relay, PS2 relay,
     debug register access.
```

**Option C: Dual-role — Pico AS the bus ROM**
Same as the real CPU systems: Pico directly emulates ROM on the FPGA's
internal bus. The FPGA exports a ROM bus to Pico GPIO. This gives the
Pico direct visibility into the CPU's address space and enables interactive
debugging (breakpoints, memory dumps) from the Pico's USB console.

### 5.6 FPGA Configuration (Bitstream Loading)

The FPGA needs its bitstream loaded at power-on:

**Option A: SPI Flash (standalone boot)**
- W25Q32 or larger SPI flash on motherboard
- FPGA loads bitstream on power-up
- Pi Pico can program the flash over SPI
- Standalone operation (no Pico needed after programming)

**Option B: Pico loads FPGA directly**
- Pico drives the FPGA's SPI configuration pins
- FPGA in slave SPI mode
- Pico loads bitstream from its flash on every power-up
- Simpler (no SPI flash chip) but Pico must be present

**Recommended**: Both. SPI flash for standalone operation, Pico as alternate
configuration source for development. FPGA PROGRAMN pin directly accessible
from Pico GPIO for re-configuration without power cycling.

### 5.7 Bus Bridge (FPGA)

The bus bridge is purely Verilog, no external components:

```verilog
module uniretro_bridge #(
    parameter NUM_SLOTS = 4
)(
    // CPU-side (internal fabric)
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    output reg  [31:0] cpu_rdata,
    input  wire [3:0]  cpu_wmask,
    input  wire        cpu_rstrb,
    input  wire        cpu_wstrb,
    output reg         cpu_rbusy,
    output reg         cpu_wbusy,

    // UniRetro bus pins (directly to FPGA GPIO)
    output reg  [23:0] bus_addr,
    inout  wire [31:0] bus_data,      // directly to card edge
    output reg         bus_as_n,
    output reg         bus_ds_n,
    input  wire        bus_dtack_n,
    output reg         bus_rw,
    output reg  [1:0]  bus_siz,
    output reg  [NUM_SLOTS-1:0] bus_sel_n,
    input  wire [NUM_SLOTS-1:0] bus_irq_n,
    input  wire [1:0]  bus_width [NUM_SLOTS-1:0],  // WIDTH pins per slot
    output wire        bus_reset_n,
    output wire        bus_clk,
    output wire        bus_berr_n,

    // DMA signals
    input  wire [NUM_SLOTS-1:0] bus_breq_n,
    output reg  [NUM_SLOTS-1:0] bus_bgrant_n,
    input  wire        bus_bbusy_n,
    output reg         bus_bterm_n,
    input  wire        bus_snoop_n,

    // Interrupt output to CPU
    output wire        irq_out
);
    // ... slot table, address decode, width conversion,
    //     enumeration mode, interrupt routing, DMA arbiter
    //     ~150-300 lines of Verilog
endmodule
```

### 5.8 Bill of Materials (Key Components)

| Component | Part | Package | Qty |
|-----------|------|---------|-----|
| FPGA Module | Colorlight i5 (ECP5-25F) | Module | 1 |
| Alt: FPGA | ECP5-25F | TQFP-144 | 1 |
| SRAM (optional) | AS6C4008 | DIP-32 | 0 or 2 |
| SPI Flash | W25Q32JVSSIQ | SOP-8 | 1 |
| ROM/Dev Interface | Raspberry Pi Pico | Module | 1 |
| USB-Serial | CH340G | SOP-16 | 1 |
| Oscillator | 25 MHz | DIP-8/SMD | 1 |
| Voltage Reg | AMS1117-3.3 | SOT-223 | 1 |
| Bus Sockets | 2×50 card edge | PCB mount | 4 |
| Level Shifter | 74LVC245 | TSSOP-20 | 4-6 |
| PS2 Connector | Mini-DIN 6 | PCB mount | 1 |
| Pin Expander | ATF1504AS (optional) | PLCC-44 | 0-1 |

---

## 6. Comparison Matrix

| Feature | 6502 | 68000 | 68030 | FPGA |
|---------|------|-------|-------|------|
| **CPU clock** | 4-8 MHz | 8-10 MHz | 25-33 MHz | 25-50 MHz |
| **Data width** | 8-bit | 16-bit | 32-bit | Configurable |
| **Card widths** | 8-bit only | 8, 16-bit | 8, 16, 32-bit | 8, 16, 32-bit |
| **Base RAM** | 64 KB | 1 MB | 4 MB | 64 KB BRAM |
| **Max DIP RAM** | 1 MB (banked) | 4 MB | 8 MB | 1 MB ext |
| **Address space** | 64 KB (banked) | 16 MB | 4 GB (256 MB decoded) | 16 MB |
| **Bus window** | 4 KB (paged) | 8 MB (direct) | 8 MB (direct) | 16 MB |
| **Bridge type** | CPLD | 74-series/CPLD | CPLD | In-FPGA |
| **Bridge complexity** | Moderate | Simple | Trivial | Simple |
| **Width conversion** | N/A (8-bit only) | Bridge (8→16) | CPU auto (DSACK) | In-FPGA |
| **DMA support** | No | Yes (BR/BG) | Yes (BR/BG) | Yes (Verilog) |
| **Pico GPIO fit** | Exact (26) | Tight (26+latch) | Tight (26+latch) | Flexible (SPI/parallel) |
| **Total ICs** | ~10-12 | ~12-15 | ~12-15 | ~5-8 |
| **Board complexity** | Moderate | Moderate | Moderate-High | Low-Moderate |
| **Estimated cost** | $40-60 | $50-80 | $80-120 | $30-50 |
| **Best for** | Learning, simplicity | Classic retro | Performance | Flexibility |

---

## 7. Expansion Card Examples

Cards that would demonstrate the bus across all systems:

| Card | Width | Class | Size | Works On |
|------|-------|-------|------|----------|
| LED + GPIO | 8-bit | GPIO | 16 bytes | All systems |
| SID audio synth | 8-bit | Audio | 32 bytes | All systems |
| HDMI character display | 8-bit | Display | 4 KB | All systems |
| SD card + FAT | 16-bit | Storage | 512 bytes | 68k, 68030, FPGA |
| Ethernet (ENC28J60) | 8-bit | Network | 32 bytes | All systems |
| SRAM expansion (1 MB) | 16-bit | Memory | 1 MB | 68k, 68030, FPGA |
| SRAM expansion (16 MB) | 32-bit | Memory | 16 MB | 68030, FPGA |
| Graphics framebuffer | 32-bit + DMA | Display | 2 MB | 68030, FPGA |

The LED+GPIO card is the recommended first card build — it validates the
entire bus protocol with minimal card-side logic (a 74HC245 buffer, a
74HC574 latch, and a config ROM EEPROM).

---

## 8. Development Sequence

Recommended build order:

### Phase 1: FPGA System + Simple Card
1. Build FPGA motherboard (Colorlight i5 + breakout PCB)
2. Build LED+GPIO card (simplest possible card)
3. Implement bus bridge in Verilog
4. Write enumeration firmware
5. Verify: enumerate card, blink LEDs, read GPIO
6. Build PS2 keyboard card (port existing design to card form factor)

### Phase 2: 68000 System
1. Build 68000 motherboard
2. Verify CPU boots from Pi Pico ROM
3. Connect to same expansion cards from Phase 1
4. Validate cross-system card compatibility

### Phase 3: 6502 System
1. Build 6502 motherboard
2. Verify same cards work (8-bit mode)
3. Write 6502 enumeration firmware

### Phase 4: 68030 System
1. Build 68030 motherboard
2. Verify 32-bit card support
3. Demonstrate DSACK dynamic bus sizing with mixed-width cards

---

## Appendix A: Pi Pico ROM Emulator Pinout

### 6502 Configuration (26 GPIO, exact fit)

```
Pico GPIO    Signal     Direction
─────────    ──────     ─────────
GP0-GP7      D0-D7      Bidirectional
GP8-GP23     A0-A15     Input
GP26         /CS        Input (active when ROM address range)
GP27         PHI2       Input (timing reference)
```

### 68000 Configuration (26 GPIO, with latch)

```
Pico GPIO    Signal     Direction
─────────    ──────     ─────────
GP0-GP7      D0-D7      Bidirectional (8-bit ROM)
GP8-GP23     A1-A16     Input (directly, 64 KB window)
GP26         /CS        Input
GP27         /AS        Input (active-low, triggers latch)

External: 74HC573 latch captures A17-A23 on /AS edge
          (for ROM windows > 64 KB)
```

### FPGA Configuration (SPI, 4 GPIO)

```
Pico GPIO    Signal     Direction
─────────    ──────     ─────────
GP0          SPI_MISO   Output (Pico → FPGA)
GP1          SPI_CS     Output
GP2          SPI_SCLK   Output
GP3          SPI_MOSI   Input (FPGA → Pico)
GP4-GP5      UART TX/RX Bidirectional (console)
GP6          FPGA_RESET Output (trigger FPGA reconfig)
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-03-27 | Initial draft — 6502, 68000, 68030, FPGA systems |
