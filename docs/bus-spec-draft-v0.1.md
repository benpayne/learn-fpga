# UniRetro Bus Specification

**Draft Version 0.2** | March 2026

A CPU-agnostic, plug-and-play expansion bus for retro and hobby computing systems.

---

## 1. Overview

### 1.1 Purpose

The UniRetro Bus provides a standardized physical expansion interface for retro
computing systems. It enables a single card design to work across systems built
around 6502, Z80, 8086, 68000, RISC-V, and other processors without
modification.

### 1.2 Design Goals

- **CPU-agnostic**: No assumptions about host processor architecture
- **Plug and Play**: Cards self-describe; system assigns resources at boot
- **Scalable width**: 8-bit, 16-bit, and 32-bit cards on the same backplane
- **Simple cards**: Minimal logic required; a ROM and basic bus interface suffice
- **Retro-accessible**: Hand-solderable 2.54mm pitch, 5V tolerant, no BGA
- **FPGA and discrete friendly**: Implementable in CPLD, FPGA, or 74-series logic

### 1.3 System Architecture

This specification defines the card-to-slot electrical and protocol interface.
The system architecture hosting those slots is an implementation choice that
does not affect card compatibility. Three models are viable:

- **Motherboard**: CPU and bridge are fixed on the board alongside the card
  slots. Simplest cards, easiest to debug, lowest per-card cost. Each CPU
  architecture requires its own motherboard design. This is the recommended
  model for initial implementations.

- **Passive backplane**: CPU resides on a card in a designated system slot.
  The backplane is purely passive copper. Allows CPU swapping by changing one
  card, but increases card complexity (daisy-chain for per-slot signals) and
  moves all bridge intelligence onto the CPU card.

- **Carrier with CPU module**: A carrier board holds the card slots and a
  socket for a small, pluggable CPU module containing the processor and
  bridge. Combines motherboard-simple cards with CPU swappability. Requires
  an additional module connector specification.

All three models present identical signals at the card edge connector. A card
designed to this specification works in any conforming system regardless of
the hosting architecture.

### 1.4 Key Characteristics

| Parameter          | Value                              |
|--------------------|------------------------------------|
| Bus type           | Asynchronous, non-multiplexed      |
| Data width         | 8, 16, or 32 bits (per card)       |
| Address width      | 24 bits (16 MB address space)      |
| Clock              | 1-50 MHz reference (bus is async)  |
| Max slots          | 8 (reference design)               |
| Connector          | PCB card edge, 2.54mm pitch        |
| Voltage            | 3.3V logic, 5V tolerant, 5V power  |
| Byte order         | Big-endian on the bus (see §4.7)   |

---

## 2. Physical Layer

### 2.1 Connector

The bus uses a PCB card edge connector at 2.54mm (0.100") pitch with contacts
on both sides. Three card widths are defined by three connector sections.

```
           Section A          Section B          Section C
         (8-bit base)      (16-bit ext)       (32-bit ext)
        ◄─── 2×25 ────►   ◄── 2×15 ──►      ◄── 2×10 ──►
        ╔══════════════╦═══╦═══════════╦═══╦════════════╗
  Top   ║ A1 ....  A25 ║   ║ B1 .. B15 ║   ║ C1 .. C10  ║
        ╠══════════════╬═══╬═══════════╬═══╬════════════╣
  Bot   ║ A26 ... A50  ║   ║ B16.. B30 ║   ║ C11 .. C20 ║
        ╚══════════════╩═══╩═══════════╩═══╩════════════╝
                           ▲               ▲
                        Key notch       Key notch
                        (1 pos gap)     (1 pos gap)
```

| Section | Pins | Socket Width | Cumulative | Standard Part |
|---------|------|-------------|------------|---------------|
| A (8-bit base) | 50 (2×25) | ~64 mm | 50 pins | 2×25 card edge |
| A+B (16-bit) | 80 (2×40) | ~102 mm | 80 pins | 2×40 card edge |
| A+B+C (32-bit) | 100 (2×50) | ~127 mm | 100 pins | 2×50 card edge |

Key notches (1 position gap with no gold fingers) separate sections and provide:
- Mechanical keying against reversed insertion
- Physical card width detection
- Alignment reference during insertion

**Card PCB thickness**: 1.6mm standard (±0.1mm)

**Gold finger specification**: Hard gold, minimum 0.75μm (30μin), beveled edge
recommended for insertion ease.

### 2.2 Backplane

The backplane is a PCB with card edge sockets spaced at a regular pitch. All
signals are directly connected across all slots (active backplane for /SEL,
/IRQ, /BREQ, and /BGRANT lines which are per-slot).

**Recommended slot pitch**: 20.32mm (0.800") center-to-center, accommodating
standard card thickness plus clearance for components.

**Recommended backplane form factor**: The reference design supports up to 8
slots. Smaller systems may implement 2 or 4 slots.

### 2.3 Electrical Characteristics

| Parameter | Min | Typical | Max | Unit |
|-----------|-----|---------|-----|------|
| VCC_3V3 | 3.0 | 3.3 | 3.6 | V |
| VCC_5V | 4.75 | 5.0 | 5.25 | V |
| V_IH (input high) | 2.0 | - | 5.5 | V |
| V_IL (input low) | -0.3 | - | 0.8 | V |
| V_OH (output high) | 2.4 | 3.3 | - | V |
| V_OL (output low) | - | 0.0 | 0.4 | V |
| I_OH (output high) | - | - | -8 | mA |
| I_OL (output low) | - | - | 8 | mA |
| Bus capacitance/slot | - | 10 | 15 | pF |

Logic levels are 3.3V LVCMOS with 5V tolerance on inputs. Cards powered by 5V
should use level-shifting buffers (74LVC245 or equivalent) to drive the bus.

All active-low signals use 10kΩ pull-up resistors to VCC_3V3 on the backplane.
This ensures inactive state when slots are empty.

---

## 3. Pin Assignment

### 3.1 Section A - 8-Bit Base (50 pins)

All cards must implement Section A.

| Pin (Top) | Signal | Pin (Bot) | Signal | Description |
|-----------|--------|-----------|--------|-------------|
| A1 | GND | A26 | GND | Ground |
| A2 | D0 | A27 | D1 | Data bus bit 0, 1 |
| A3 | D2 | A28 | D3 | Data bus bit 2, 3 |
| A4 | D4 | A29 | D5 | Data bus bit 4, 5 |
| A5 | D6 | A30 | D7 | Data bus bit 6, 7 |
| A6 | GND | A31 | GND | Ground (mid-bus shield) |
| A7 | A0 | A32 | A1 | Address bus bit 0, 1 |
| A8 | A2 | A33 | A3 | Address bus bit 2, 3 |
| A9 | A4 | A34 | A5 | Address bus bit 4, 5 |
| A10 | A6 | A35 | A7 | Address bus bit 6, 7 |
| A11 | A8 | A36 | A9 | Address bus bit 8, 9 |
| A12 | A10 | A37 | A11 | Address bus bit 10, 11 |
| A13 | A12 | A38 | A13 | Address bus bit 12, 13 |
| A14 | A14 | A39 | A15 | Address bus bit 14, 15 |
| A15 | /AS | A40 | /DS | Address/Data strobe |
| A16 | /DTACK | A41 | R/W | Acknowledge, Direction |
| A17 | SIZ0 | A42 | SIZ1 | Transfer size |
| A18 | /IRQ | A43 | /SEL | Interrupt, Slot select |
| A19 | /RESET | A44 | CLK | Reset, Reference clock |
| A20 | WIDTH0 | A45 | WIDTH1 | Card width sense |
| A21 | /BERR | A46 | RSVD_A1 | Bus error, Reserved |
| A22 | RSVD_A2 | A47 | RSVD_A3 | Reserved |
| A23 | RSVD_A4 | A48 | RSVD_A5 | Reserved |
| A24 | VCC_3V3 | A49 | VCC_5V | Power |
| A25 | GND | A50 | GND | Ground |

**Notes:**
- GND pins at edges and between data/address groups for signal integrity
- /IRQ and /SEL are unique per slot (active backplane traces)
- 8-bit cards see only A0-A15 (bridge provides full 24-bit translation)
- RSVD_A1-A5: reserved for future use, do not connect
- 50-pin (2×25) card edge connector is a standard, widely available part

### 3.2 Section B - 16-Bit Extension (30 pins)

Required for 16-bit and 32-bit cards.

| Pin (Top) | Signal | Pin (Bot) | Signal | Description |
|-----------|--------|-----------|--------|-------------|
| B1 | GND | B16 | GND | Ground |
| B2 | D8 | B17 | D9 | Data bus bit 8, 9 |
| B3 | D10 | B18 | D11 | Data bus bit 10, 11 |
| B4 | D12 | B19 | D13 | Data bus bit 12, 13 |
| B5 | D14 | B20 | D15 | Data bus bit 14, 15 |
| B6 | A16 | B21 | A17 | Address bus bit 16, 17 |
| B7 | A18 | B22 | A19 | Address bus bit 18, 19 |
| B8 | A20 | B23 | A21 | Address bus bit 20, 21 |
| B9 | A22 | B24 | A23 | Address bus bit 22, 23 |
| B10 | /BREQ | B25 | /BGRANT | Bus request, Bus grant |
| B11 | /BBUSY | B26 | /BTERM | Bus busy, Bus terminate |
| B12 | /SNOOP | B27 | RSVD_B1 | Cache snoop, Reserved |
| B13 | RSVD_B2 | B28 | RSVD_B3 | Reserved |
| B14 | VCC_3V3 | B29 | VCC_5V | Power |
| B15 | GND | B30 | GND | Ground |

**Notes:**
- A16-A23 extend the address bus to full 24-bit
- /BREQ and /BGRANT are unique per slot (active backplane traces)
- All DMA signals (/BREQ, /BGRANT, /BBUSY, /BTERM, /SNOOP) are in Section B,
  enabling 16-bit cards to be DMA masters
- 3 reserved pins for future use

### 3.3 Section C - 32-Bit Extension (20 pins)

Required for 32-bit cards only.

| Pin (Top) | Signal | Pin (Bot) | Signal | Description |
|-----------|--------|-----------|--------|-------------|
| C1 | GND | C11 | GND | Ground |
| C2 | D16 | C12 | D17 | Data bus bit 16, 17 |
| C3 | D18 | C13 | D19 | Data bus bit 18, 19 |
| C4 | D20 | C14 | D21 | Data bus bit 20, 21 |
| C5 | D22 | C15 | D23 | Data bus bit 22, 23 |
| C6 | D24 | C16 | D25 | Data bus bit 24, 25 |
| C7 | D26 | C17 | D27 | Data bus bit 26, 27 |
| C8 | D28 | C18 | D29 | Data bus bit 28, 29 |
| C9 | D30 | C19 | D31 | Data bus bit 30, 31 |
| C10 | GND | C20 | GND | Ground |

**Notes:**
- Section C is purely data lines and ground
- All DMA and control signals reside in Section B
- GND pins on both ends provide return path for high-speed D16-D31 signals
- Power supplied through Sections A and B via card PCB traces

### 3.4 Width Sense Pins

The WIDTH0 and WIDTH1 pins indicate the card's native data width. These are
active-low, directly connected to GND on the card (no logic needed).

| WIDTH1 | WIDTH0 | Card Width |
|--------|--------|------------|
| Hi (open) | Hi (open) | No card / invalid |
| Hi (open) | Lo (GND) | 8-bit |
| Lo (GND) | Hi (open) | 16-bit |
| Lo (GND) | Lo (GND) | 32-bit |

Pull-up resistors on the backplane ensure empty slots read as "no card."

---

## 4. Bus Protocol

### 4.1 Signal Definitions

All active-low signals are prefixed with `/`.

| Signal | Direction | Active | Description |
|--------|-----------|--------|-------------|
| D0-D31 | Bidirectional | - | Data bus. Width depends on card. |
| A0-A23 | Master → Card | - | Address bus. 8-bit cards see A0-A15 only. |
| /AS | Master → Card | Low | Address Strobe. Address lines are valid. |
| /DS | Master → Card | Low | Data Strobe. Data requested (read) or valid (write). |
| /DTACK | Card → Master | Low | Data Transfer Acknowledge. Transfer complete. |
| R/W | Master → Card | - | High = Read, Low = Write. |
| SIZ0-SIZ1 | Master → Card | - | Transfer size (see §4.2). |
| /SEL | Bridge → Card | Low | Slot Select. Active for the addressed slot. Per-slot. |
| /IRQ | Card → Bridge | Low | Interrupt Request. Per-slot. |
| /RESET | System | Low | Global reset. Minimum 100μs pulse. |
| CLK | System | - | Reference clock. 1-50 MHz. Cards may ignore. |
| WIDTH0-1 | Card → Bridge | Low | Card width sense (see §3.4). |
| /BERR | Bridge → Master | Low | Bus Error. No /DTACK received within timeout. |
| /BREQ | Card → Bridge | Low | Bus Request. Card wants DMA mastership. Per-slot. |
| /BGRANT | Bridge → Card | Low | Bus Grant. Card may take the bus. Per-slot. |
| /BBUSY | Current Master | Low | Bus Busy. A transfer is in progress. |
| /BTERM | Bridge → Card | Low | Bus Terminate. Force end of DMA burst. |
| /SNOOP | DMA Master | Low | Snoop. DMA write in progress (cache advisory). |

### 4.2 Transfer Size Encoding

| SIZ1 | SIZ0 | Transfer Size | Data Lines Used |
|------|------|---------------|-----------------|
| 0 | 0 | 8-bit (1 byte) | D0-D7 |
| 0 | 1 | 16-bit (2 bytes) | D0-D15 |
| 1 | 0 | 32-bit (4 bytes) | D0-D31 |
| 1 | 1 | Reserved | - |

The bridge always issues transfers at the card's native width. If the CPU
requests a wider transfer than the card supports, the bridge breaks it into
multiple bus cycles transparently.

### 4.3 Read Cycle

```
              ┌─────────────────────────────────────────────────┐
   Address    │         VALID ADDRESS                           │
              └─────────────────────────────────────────────────┘
              ┌──┐
   /AS        │  └──────────────────────────────────────┐
              │                                         └───────
              ┌──────┐
   /DS        │      └──────────────────────────────────┐
              │                                         └───────

   R/W        ─────────────────── HIGH (READ) ─────────────────
                                            ┌──────────┐
   Data       ──────────────────────────────┤VALID DATA├────────
                                            └──────────┘
                                      ┌─────────────────┐
   /DTACK     ────────────────────────┘                 └───────

              ├──── Address setup ────┤
              ├────────── Data access time ──────────────┤
```

**Sequence:**

1. Master drives address on A0-A23 (or A0-A15 for 8-bit cards)
2. Master drives R/W high (read)
3. Master asserts /AS (address valid)
4. Bridge asserts /SEL[n] for the matching slot
5. Master asserts /DS (requesting data)
6. Card decodes address, places data on bus, asserts /DTACK
7. Master latches data on /DTACK falling edge
8. Master deasserts /DS, then /AS
9. Card deasserts /DTACK, releases data bus

**Timing constraints:**
- Address must be valid before /AS asserts (setup: ≥ 10ns)
- /AS must precede /DS (setup: ≥ 0ns, may be simultaneous)
- Data must be valid before /DTACK asserts (setup: ≥ 5ns)
- Master must hold /DS at least 10ns after latching data
- Card must release data bus within 20ns of /DS deassertion

### 4.4 Write Cycle

```
              ┌─────────────────────────────────────────────────┐
   Address    │         VALID ADDRESS                           │
              └─────────────────────────────────────────────────┘
              ┌──┐
   /AS        │  └──────────────────────────────────────┐
              │                                         └───────
              ┌──────────┐
   R/W        │          └──── LOW (WRITE) ─────────────────────
              └──────────┘
                         ┌──────────────────────────────┐
   Data       ───────────┤        VALID DATA            ├───────
                         └──────────────────────────────┘
              ┌──────┐
   /DS        │      └──────────────────────────────────┐
              │                                         └───────
                                      ┌─────────────────┐
   /DTACK     ────────────────────────┘                 └───────
```

**Sequence:**

1. Master drives address on A0-A23
2. Master drives R/W low (write)
3. Master asserts /AS (address valid)
4. Master drives data on bus
5. Master asserts /DS (data valid)
6. Card latches data, asserts /DTACK
7. Master deasserts /DS, then /AS, releases data bus
8. Card deasserts /DTACK

### 4.5 Bus Error

The bridge asserts /BERR to signal a bus error to the CPU in two cases:

1. **Unmapped address (immediate)**: During normal operation, the bridge knows
   which address windows are assigned. If /DS targets an address outside all
   assigned windows, the bridge asserts /BERR immediately without waiting for
   a timeout. No bus cycle is generated.

2. **Card non-response (timeout)**: If /DS targets a valid slot window but the
   card fails to assert /DTACK within the timeout period, the bridge asserts
   /BERR. This handles cards that have locked up or been removed.

**Timeout**: Configurable, default 10μs (sufficient for the slowest reasonable
device). The bridge implements a countdown timer that resets on /DS assertion
and fires /BERR if /DTACK is not received. During enumeration, timeout is the
only error detection mechanism (since no address windows are yet assigned).

### 4.6 Bus Width Conversion

When the CPU requests a transfer wider than the card's native width, the bridge
performs automatic width conversion.

**32-bit CPU reading 8-bit card (4 bus cycles):**

```
CPU Request:  32-bit read at address 0x1000
Bridge:       Reads card WIDTH pins → 8-bit
              Cycle 1: Read addr 0x1000, D0-D7  → byte 0
              Cycle 2: Read addr 0x1001, D0-D7  → byte 1
              Cycle 3: Read addr 0x1002, D0-D7  → byte 2
              Cycle 4: Read addr 0x1003, D0-D7  → byte 3
              Assemble into 32-bit word, return to CPU
```

**32-bit CPU reading 16-bit card (2 bus cycles):**

```
CPU Request:  32-bit read at address 0x1000
Bridge:       Reads card WIDTH pins → 16-bit
              Cycle 1: Read addr 0x1000, D0-D15 → half 0
              Cycle 2: Read addr 0x1002, D0-D15 → half 1
              Assemble into 32-bit word, return to CPU
```

**8-bit CPU reading any card:**

```
CPU Request:  8-bit read at address 0x1000
Bridge:       Sets SIZ=00 (8-bit)
              Cycle 1: Read addr 0x1000, D0-D7  → byte
              Return to CPU
              (16-bit and 32-bit cards respond on D0-D7 for 8-bit transfers)
```

All width conversion is handled by the bridge. Cards always see transfers at
their native width or narrower. A card never sees a transfer wider than its
native width.

### 4.7 Byte Ordering

The bus uses **big-endian** (Motorola) byte ordering. D0-D7 always carries the
byte at the lowest address. For multi-byte transfers:

| Transfer Size | D0-D7 | D8-D15 | D16-D23 | D24-D31 |
|---------------|-------|--------|---------|---------|
| 8-bit | byte[addr] | - | - | - |
| 16-bit | byte[addr] | byte[addr+1] | - | - |
| 32-bit | byte[addr] | byte[addr+1] | byte[addr+2] | byte[addr+3] |

This applies to all bus transfers including config ROM reads.

**Big-endian host CPUs** (68000, etc.) can use bus data directly with no
conversion.

**Little-endian host CPUs** (RISC-V, x86, etc.) may require byte-swapping.
Whether the bridge performs automatic byte-swapping or leaves it to software
is a bridge implementation choice. Cards are not affected either way — they
always see big-endian byte ordering on the bus.

**Card designers**: Store multi-byte values (16-bit registers, etc.) in
big-endian order. The most significant byte occupies the lowest address.

---

## 5. Address Mapping

### 5.1 Address Space

The bus provides a 24-bit address space (16 MB). The bridge maps this into the
host CPU's address space. The location within the host address space is
CPU-bridge specific and not defined by this specification.

### 5.2 Card Address Windows

Each card is assigned a contiguous, naturally-aligned window in the 24-bit bus
address space. Window sizes are powers of 2, from 16 bytes to 16 MB.

**8-bit cards** are limited to a maximum 64 KB window (A0-A15). The bridge
translates the card's local A0-A15 address to the appropriate location within
the 24-bit bus space. The card never sees addresses above 0xFFFF.

**16-bit and 32-bit cards** can address the full 24-bit bus space (A0-A23).

### 5.3 Bridge Slot Table

The bridge maintains an internal slot table that maps bus addresses to slots:

```
Per-slot entry:
  base_address [23:0]   - Start of card's address window
  size_mask    [23:0]   - Window size bitmask (2^N - 1)
  present      [0]      - Card detected in slot
  width        [1:0]    - Card data width (from WIDTH pins)
  irq_enable   [0]      - Interrupt routing enabled
  dma_enable   [0]      - DMA mastership allowed
```

Address decode logic:
```
match = present AND ((bus_address AND NOT size_mask) == base_address)
card_address = bus_address AND size_mask
```

For 8-bit cards, only the lower 16 bits of card_address are driven on A0-A15.

---

## 6. Plug and Play

### 6.1 Overview

Cards are identified and configured at boot via a geographic enumeration
process. Each slot has a dedicated /SEL line. The bus controller reads a config
ROM from each slot in sequence, then assigns non-conflicting address windows.

No card-specific knowledge is required in the enumerator.

### 6.2 Enumeration Sequence

```
1.  System reset (/RESET asserted for ≥ 100μs)
2.  Bridge enters ENUM mode
3.  For each slot (0 to N-1):
    a.  Assert /SEL[n] (only this slot active)
    b.  Read config ROM at card address 0x0000 using 8-bit transfers
    c.  If /DTACK within timeout: card present, read full config header
    d.  If /BERR (timeout): slot empty, continue to next
    e.  Validate magic bytes and checksum
    f.  Record card resource requirements
    g.  Deassert /SEL[n]
4.  Sort cards by requested window size (largest first)
5.  Assign base addresses (naturally aligned, no overlap)
6.  Program bridge slot table with assignments
7.  Exit ENUM mode
8.  Normal bus operation begins
```

**All enumeration reads use 8-bit (SIZ=00) transfers.** This ensures that even
an 8-bit CPU can enumerate 32-bit cards, and that card config ROM logic is
always minimal.

### 6.3 Config ROM Format

Located at card-local address 0x0000. Read as sequential bytes.

```
Offset  Size  Field               Value / Description
──────  ────  ─────               ───────────────────
0x00    1     magic[0]            0xA5
0x01    1     magic[1]            0x5A
0x02    1     config_version      0x01 (this spec)
0x03    1     header_length       Total header length in bytes (incl. magic)
0x04    2     vendor_id           Vendor identifier (big-endian)
0x06    2     device_id           Device identifier (big-endian)
0x08    1     device_revision     Hardware revision number
0x09    1     device_class        Device class code (see §6.5)
0x0A    1     device_subclass     Device subclass code
0x0B    1     bus_flags           Capability flags (see §6.6)
0x0C    1     mem_size_exp        Memory window: 2^N bytes (0 = none)
0x0D    1     mem_flags           Memory attributes (see §6.7)
0x0E    1     reserved_0E         Reserved for future I/O space (must be 0)
0x0F    1     reserved_0F         Reserved for future I/O space (must be 0)
0x10    1     irq_flags           Interrupt behavior (see §6.8)
0x11    1     dma_flags           DMA capabilities (see §6.9)
0x12    2     reserved            Must be 0x0000
0x14    1     name_length         Length of name string (0-31)
0x15    N     name[]              ASCII device name (not null-terminated)
0x15+N  1     checksum            XOR of all preceding bytes (0x00 - 0x14+N)
```

Maximum config ROM size: 54 bytes (22-byte header + 31-byte name + checksum).

### 6.4 Vendor and Device IDs

| Range | Assignment |
|-------|------------|
| 0x0000 | Prototype / unregistered (free use) |
| 0x0001-0x00FF | Reserved for bus specification authors |
| 0x0100-0xFEFF | Open registration (see project wiki) |
| 0xFFFF | Reserved |

Device IDs are scoped to vendor IDs. Each vendor manages their own device ID
space.

### 6.5 Device Class Codes

| Code | Class | Example Devices |
|------|-------|-----------------|
| 0x00 | Unclassified | Prototype, test cards |
| 0x01 | Storage | SD card, CompactFlash, floppy controller |
| 0x02 | Network | Ethernet, WiFi, serial link |
| 0x03 | Display | VGA, HDMI framebuffer, character LCD |
| 0x04 | Audio | DAC, SID-like synth, FM, codec |
| 0x05 | Input | Keyboard, mouse, joystick |
| 0x06 | Communication | UART, SPI bridge, I2C bridge |
| 0x07 | Bridge | Bus-to-bus adapter |
| 0x08 | Co-processor | Math, crypto, DSP |
| 0x09 | Memory | RAM expansion, ROM |
| 0x0A | Timer / Counter | Interval timer, RTC, watchdog |
| 0x0B | GPIO / Parallel | General-purpose I/O |
| 0x0C-0xFE | Reserved | Future standardization |
| 0xFF | Vendor-specific | Defined by vendor |

### 6.6 bus_flags Field

```
Bit   Name           Description
───   ────           ───────────
0-1   bus_width      00 = 8-bit, 01 = 16-bit, 10 = 32-bit, 11 = reserved
2     dma_capable    1 = Card can be bus master
3     burst_capable  1 = Card supports burst transfers
4     fcode_present  1 = Card has FCode bytecode at 0x0100 (see §10.5)
5-7   reserved       Must be 0
```

### 6.7 mem_flags Field

```
Bit   Name           Description
───   ────           ───────────
0     read_only      1 = Memory region is read-only
1     prefetchable   1 = Safe to read ahead (no side effects)
2     cacheable      1 = Safe to cache (not volatile registers)
3-7   reserved       Must be 0
```

### 6.8 irq_flags Field

```
Bit   Name           Description
───   ────           ───────────
0     irq_present    1 = Card uses interrupts
1     irq_trigger    0 = Edge-triggered, 1 = Level-triggered
2     irq_polarity   0 = Active-low (default), 1 = Active-high
3-7   reserved       Must be 0
```

The recommended default is edge-triggered, active-low (irq_flags = 0x01).

### 6.9 dma_flags Field

```
Bit   Name           Description
───   ────           ───────────
0     dma_master     1 = Card can initiate bus transfers
1     dma_slave      1 = Card can be target of external DMA
2-3   max_burst      00 = 1 word, 01 = 4, 10 = 16, 11 = 64 words
4-7   reserved       Must be 0
```

### 6.10 Checksum

The checksum byte is the XOR of all preceding bytes in the config ROM (from
offset 0x00 through 0x14+name_length). Verification:

```
XOR of all bytes from offset 0x00 through checksum byte == 0x00
```

---

## 7. Interrupts

### 7.1 Signal Behavior

Each slot has a dedicated /IRQ line. The default behavior is edge-triggered,
active-low, as indicated by the card's irq_flags.

**Edge-triggered (default):**
Card pulses /IRQ low for at least 100ns. The bridge latches the falling edge.
This minimum pulse width ensures reliable detection regardless of bus clock
speed or whether the card uses CLK.

**Level-triggered:**
Card holds /IRQ low as long as the interrupt condition persists. The bridge
must not re-trigger until the line deasserts and re-asserts.

### 7.2 Interrupt Routing

The bridge maps per-slot /IRQ lines to the host CPU's interrupt mechanism.
This mapping is CPU-bridge specific:

| Host CPU | Interrupt Mechanism | Bridge Mapping |
|----------|-------------------|----------------|
| 6502 | IRQ, NMI (active-low) | Any slot → /IRQ (active = any asserted) |
| Z80 | /INT (IM 2 vectored) | Priority encoder → vector on IACK |
| 8086/286/386 | 8259 PIC (IRQ0-7/15) | Slot N → 8259 input N |
| 68000/030/040 | IPL0-IPL2 (encoded 1-7) | Priority encoder → IPL level |
| FemtoRV | 32-source controller | Slot N → interrupt source N |

### 7.3 Interrupt Identification

After receiving an interrupt, the CPU reads the bridge's interrupt status
register to identify which slot(s) interrupted. The bridge provides:

- **Interrupt Status Register (read)**: Bit N = 1 if slot N has pending interrupt
- **Interrupt Clear Register (write)**: Write 1 to bit N to clear slot N's interrupt

---

## 8. DMA / Bus Mastering

### 8.1 Eligibility

Only 16-bit and 32-bit cards may be DMA masters. All DMA signals (/BREQ,
/BGRANT, /BBUSY, /BTERM, /SNOOP) reside in Section B. 8-bit cards, which
only implement Section A, cannot request bus mastership.

### 8.2 Arbitration Protocol

```
    Card              Arbiter            Current Master (CPU)
     │                  │                       │
     │──── /BREQ[n] ───►│                       │
     │                  │   (wait for /BBUSY     │
     │                  │    to deassert)        │
     │                  │                       │──── /BBUSY deasserts
     │◄── /BGRANT[n] ──│                       │
     │                  │                       │     (tri-states bus)
     │──── /BBUSY ─────►│                       │
     │   (deassert /BREQ)                       │
     │                  │                       │
     │  ◄═══ DMA transfers (card is master) ═══►│
     │                  │                       │
     │──── /BBUSY deasserts ───►│               │
     │                  │──── (return to CPU) ──►│
```

**Sequence:**

1. Card asserts /BREQ[n] (requests bus)
2. Arbiter waits for current bus cycle to complete (/BBUSY high)
3. Arbiter asserts /BGRANT[n] (card may proceed)
4. Card asserts /BBUSY, deasserts /BREQ[n]
5. Card drives address, data, and control lines as bus master
6. Card performs transfers (single, block, or demand mode)
7. Card deasserts /BBUSY when complete
8. Arbiter deasserts /BGRANT[n], returns mastership to CPU

### 8.3 Arbitration Policy

The reference arbiter uses **round-robin** scheduling. After granting slot N,
the next grant cycles through N+1, N+2, ... wrapping around. The CPU is
always the lowest-priority requester (serviced when no card requests are
pending).

### 8.4 Burst Limits

The bridge may assert /BTERM to force a DMA master to release the bus. This
prevents any single card from monopolizing bandwidth.

**Default maximum burst**: 64 words (configurable in bridge).

When /BTERM is asserted:
1. DMA master completes current transfer
2. DMA master deasserts /BBUSY within 2 CLK periods
3. DMA master may immediately re-assert /BREQ to continue

### 8.5 Snoop Signal

When a DMA master writes to memory, it should assert /SNOOP simultaneously with
/DS. CPU bridges with cached processors may use this signal to trigger cache
invalidation.

Systems without data caches (6502, Z80, 68000, FemtoRV) ignore /SNOOP.

### 8.6 DMA Address Space

DMA masters address the same 24-bit bus address space as the CPU. A DMA
transfer can target system memory (via the CPU bridge) or another card's
address window.

**Note:** Card-to-card DMA is architecturally possible but not required in
conforming implementations. The bridge may restrict DMA targets to system
memory only.

---

## 9. CPU Bridge Requirements

The CPU bridge connects the host processor to the UniRetro backplane. Each
bridge is CPU-specific. This section defines the requirements that all bridges
must satisfy.

### 9.1 Mandatory Bridge Functions

1. **Address decode**: Map a region of the host CPU's address space to the
   24-bit bus address space.
2. **Slot table**: Maintain base_address, size_mask, present, and width for
   each slot. Support programmatic read/write by the CPU.
3. **Width conversion**: Automatically split wide CPU transfers into multiple
   narrow bus cycles when card width < CPU width.
4. **Wait state generation**: Translate async /DTACK to the CPU's native wait
   mechanism (RDY, /WAIT, READY, /DTACK, mem_rbusy, etc.).
5. **Bus error generation**: Assert /BERR and signal bus error to CPU if
   /DTACK timeout expires.
6. **Interrupt routing**: Map per-slot /IRQ to host CPU interrupt mechanism.
7. **Enumeration support**: Provide ENUM mode where /SEL can be manually
   asserted per slot for config ROM reads.

### 9.2 Optional Bridge Functions

1. **DMA arbitration**: Required only if DMA-capable cards are supported.
2. **Cache snoop handling**: Required only if host CPU has data caches.
3. **Bus clock generation**: Bridge may drive CLK from CPU clock or an
   independent oscillator.

### 9.3 Bridge Control Registers

The bridge exposes control registers to the CPU at a platform-specific address.
Minimum register set:

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | BUS_STATUS | R | Bit 0: enum mode, Bits 7-1: slots present bitmask |
| 0x02 | BUS_CONTROL | W | Bit 0: enter/exit enum mode |
| 0x04 | ENUM_SLOT | W | Slot number for enum /SEL assertion (0-7) |
| 0x06 | IRQ_STATUS | R | Pending interrupt bitmask (bit N = slot N) |
| 0x08 | IRQ_CLEAR | W | Write 1 to bit N to clear slot N interrupt |
| 0x0A | IRQ_ENABLE | R/W | Interrupt enable mask (bit N = slot N) |
| 0x10-0x4F | SLOT_TABLE | R/W | 8 × 8-byte slot entries (see §5.3) |

---

## 10. Card Design Guide

### 10.1 Minimum Viable 8-bit Card

An 8-bit card requires:

1. **Config ROM**: 44-54 bytes at card-local address 0x0000. May be a parallel
   EEPROM (28C64), CPLD lookup table, or FPGA block RAM.

2. **Bus interface**: Directly connect D0-D7, A0-A15, /SEL, /DS, R/W. Generate
   /DTACK after completing a read or write. Directly tie WIDTH0 to GND, leave
   WIDTH1 floating.

3. **Address decode**: Card-local only (A0-A15). The bridge handles global
   mapping.

```
Minimal 8-bit card block diagram:

                    ┌────────────────────────────┐
  A0-A15 ──────────►│                            │
  D0-D7  ◄─────────►│    Card Logic              │
  /SEL   ──────────►│    (CPLD/FPGA/discrete)    │
  /DS    ──────────►│                            │
  R/W    ──────────►│    Config ROM at 0x0000    │
  /AS    ──────────►│    Device regs at 0x0100+  │
                    │                            │
  /DTACK ◄──────────│                            │
  /IRQ   ◄──────────│    (active-low, optional)  │
                    │                            │
  WIDTH0 ─── GND    │                            │
  WIDTH1 ─── open   │                            │
                    └────────────────────────────┘
```

### 10.2 /DTACK Generation

**Simple (fixed timing):** Assert /DTACK a fixed number of CLK cycles after
/DS. Suitable for register-based cards with predictable timing.

```verilog
// Simplest /DTACK: assert one cycle after /DS
reg dtack_r;
always @(posedge CLK or posedge RESET)
    if (RESET)       dtack_r <= 1'b1;     // inactive (high)
    else if (!DS_n)  dtack_r <= 1'b0;     // assert (low)
    else             dtack_r <= 1'b1;     // deassert
assign DTACK_n = SEL_n ? 1'bZ : dtack_r;  // tri-state when not selected
```

**Asynchronous (fastest):** Assert /DTACK combinationally when /SEL and /DS
are both active and data is ready. No clock dependency.

```verilog
// Async /DTACK: no clock needed
assign DTACK_n = (SEL_n || DS_n) ? 1'bZ : 1'b0;  // immediate response
```

**Delayed (for slow devices):** Use a shift register or counter to delay
/DTACK assertion. The bus will wait.

### 10.3 Config ROM Implementation

For FPGA/CPLD cards, the config ROM is a simple case statement:

```verilog
module config_rom (
    input  wire [5:0] addr,
    output reg  [7:0] data
);
    always @(*) begin
        case (addr)
            // Magic
            6'h00: data = 8'hA5;
            6'h01: data = 8'h5A;
            // Version, header length
            6'h02: data = 8'h01;        // config version 1
            6'h03: data = 8'h22;        // header length 34 bytes
            // Vendor ID (0x0000 = prototype)
            6'h04: data = 8'h00;
            6'h05: data = 8'h00;
            // Device ID
            6'h06: data = 8'h00;
            6'h07: data = 8'h01;
            // Revision
            6'h08: data = 8'h01;
            // Class: Input, Subclass: Keyboard
            6'h09: data = 8'h05;
            6'h0A: data = 8'h01;
            // Flags: 8-bit, no DMA, no burst
            6'h0B: data = 8'h00;
            // Memory: 2^4 = 16 bytes
            6'h0C: data = 8'h04;
            6'h0D: data = 8'h00;
            // Reserved (future I/O space)
            6'h0E: data = 8'h00;
            6'h0F: data = 8'h00;
            // IRQ: present, edge, active-low
            6'h10: data = 8'h01;
            // DMA: none
            6'h11: data = 8'h00;
            // Reserved
            6'h12: data = 8'h00;
            6'h13: data = 8'h00;
            // Name: "PS2 Keyboard" (12 chars)
            6'h14: data = 8'h0C;        // name_length
            6'h15: data = "P";
            6'h16: data = "S";
            6'h17: data = "2";
            6'h18: data = " ";
            6'h19: data = "K";
            6'h1A: data = "e";
            6'h1B: data = "y";
            6'h1C: data = "b";
            6'h1D: data = "o";
            6'h1E: data = "a";
            6'h1F: data = "r";
            6'h20: data = "d";
            // Checksum (XOR of bytes 0x00-0x20)
            6'h21: data = 8'hC6;        // pre-computed
            default: data = 8'h00;
        endcase
    end
endmodule
```

### 10.4 Card Address Space Layout

Recommended card-local address layout:

```
0x0000 - 0x003F    Config ROM (read-only, accessed during enumeration)
0x0040 - 0x00FF    Reserved for future config extensions
0x0100 - 0x0FFF    FCode region (optional, see §10.5)
0x1000 - 0xFFFF    Device registers and memory (card-specific)
```

The enumerator accesses only 0x0000-0x003F. Normal operation accesses
0x1000+. Cards may combine these into a single decode (config ROM and FCode
regions are always readable) or separate them.

Cards without FCode may use the 0x0100-0x0FFF region for device registers,
but this is discouraged to preserve forward compatibility.

### 10.5 FCode Region (Reserved for Future Use)

When bus_flags bit 4 (fcode_present) is set, the card provides portable
initialization bytecode at card-local address 0x0100. This region is reserved
for a future version of this specification that will define:

- A Forth-derived bytecode format (inspired by IEEE 1275 Open Firmware FCode)
- A minimal execution environment (~40-50 primitives)
- Standard words for card register access, console output, and self-test
- A portable card initialization sequence executable on any host CPU

The intent is to enable cards to carry CPU-independent initialization and
self-test code, eliminating the need for per-CPU driver binaries. Host systems
would include a small bytecode interpreter (~1-2 KB) to execute FCode during
boot.

**FCode region layout (preliminary, subject to change):**

```
0x0100    2 bytes    FCode magic (TBD)
0x0102    2 bytes    FCode length (bytes, big-endian)
0x0104    N bytes    FCode bytecode stream
```

**Maximum FCode size**: 3,840 bytes (0x0100 through 0x0FFF).

Until the FCode specification is finalized, cards should set bus_flags bit 4
to 0 and hosts should ignore the FCode region. Cards may still use addresses
0x1000+ for device registers regardless of FCode support.

---

## 11. Reference Implementation Notes

### 11.1 Bus Timing Budget

At maximum bus clock (50 MHz), one CLK period = 20ns.

| Phase | Duration | Notes |
|-------|----------|-------|
| Address setup | ≥ 10ns | Before /AS assertion |
| /AS to /DS | ≥ 0ns | May be simultaneous |
| Card response | Varies | Card-dependent, async |
| /DTACK hold | ≥ 10ns | After data latched |
| Bus turnaround | ≥ 20ns | Between back-to-back cycles |

Minimum cycle time for a zero-wait-state card: ~60ns (address setup + /DS
assert + /DTACK response + hold + turnaround).

Maximum theoretical throughput at 8/16/32-bit:

| Width | Cycle Time | Throughput |
|-------|-----------|------------|
| 8-bit | 60ns | 16.7 MB/s |
| 16-bit | 60ns | 33.3 MB/s |
| 32-bit | 60ns | 66.7 MB/s |

Real-world throughput will be lower due to card response time and bridge
overhead.

### 11.2 Hot-Plug

Hot-plug is not supported. Cards must be inserted before power-on or system
reset. Removing a card from a live system results in undefined behavior
(floating bus lines, potential data corruption). Future revisions may address
hot-plug with card-present detect pins and sequenced power control.

### 11.3 Recommended Bus Termination

For backplanes longer than 6 slots or clock speeds above 25 MHz, series
termination resistors (22-33Ω) on master outputs are recommended to reduce
reflections.

For shorter backplanes at lower speeds, no termination is required.

---

## Appendix A: Connector Pin Quick Reference

### Section A (8-bit base) - 2×25 (50 pins)

```
Top:  GND D0  D2  D4  D6  GND A0  A2  A4  A6  A8  A10 A12 A14 /AS  /DTACK SIZ0 /IRQ /RST W0  /BERR RSVD RSVD 3V3 GND
Bot:  GND D1  D3  D5  D7  GND A1  A3  A5  A7  A9  A11 A13 A15 /DS  R/W    SIZ1 /SEL CLK  W1  RSVD  RSVD RSVD 5V  GND
```

### Section B (16-bit ext) - 2×15 (30 pins)

```
Top:  GND D8  D10 D12 D14 A16 A18 A20 A22 /BREQ  /BBUSY /SNOOP RSVD 3V3 GND
Bot:  GND D9  D11 D13 D15 A17 A19 A21 A23 /BGRANT /BTERM RSVD  RSVD 5V  GND
```

### Section C (32-bit ext) - 2×10 (20 pins)

```
Top:  GND D16 D18 D20 D22 D24 D26 D28 D30 GND
Bot:  GND D17 D19 D21 D23 D25 D27 D29 D31 GND
```

---

## Appendix B: Example Enumeration Code (C)

```c
#include <stdint.h>

#define MAX_SLOTS       8
#define CONFIG_MAGIC_0  0xA5
#define CONFIG_MAGIC_1  0x5A

typedef struct {
    uint16_t vendor_id;
    uint16_t device_id;
    uint8_t  revision;
    uint8_t  dev_class;
    uint8_t  dev_subclass;
    uint8_t  bus_width;        // 0=8, 1=16, 2=32
    uint8_t  dma_capable;
    uint32_t mem_size;         // bytes
    uint32_t base_addr;        // assigned by enumerator
    char     name[32];
    uint8_t  present;
} slot_info_t;

slot_info_t slots[MAX_SLOTS];

// Platform-specific bridge access (implement per CPU)
extern void     bus_enum_mode(int enable);
extern void     bus_select_slot(int slot);
extern uint8_t  bus_read_config(uint16_t addr);
extern void     bus_set_slot_base(int slot, uint32_t base);
extern void     bus_set_slot_size(int slot, uint32_t size);
extern void     bus_enable_slot(int slot);

static int validate_checksum(int slot, int total_len) {
    uint8_t xor = 0;
    for (int i = 0; i <= total_len; i++)
        xor ^= bus_read_config(i);
    return (xor == 0);
}

int bus_enumerate(void) {
    int count = 0;

    bus_enum_mode(1);

    for (int s = 0; s < MAX_SLOTS; s++) {
        slots[s].present = 0;
        bus_select_slot(s);

        // Check magic bytes
        if (bus_read_config(0x00) != CONFIG_MAGIC_0) continue;
        if (bus_read_config(0x01) != CONFIG_MAGIC_1) continue;

        // Read header
        uint8_t version    = bus_read_config(0x02);
        uint8_t header_len = bus_read_config(0x03);
        if (version != 0x01) continue;  // unknown version

        slots[s].vendor_id    = (bus_read_config(0x04) << 8)
                              |  bus_read_config(0x05);
        slots[s].device_id    = (bus_read_config(0x06) << 8)
                              |  bus_read_config(0x07);
        slots[s].revision     = bus_read_config(0x08);
        slots[s].dev_class    = bus_read_config(0x09);
        slots[s].dev_subclass = bus_read_config(0x0A);

        uint8_t flags         = bus_read_config(0x0B);
        slots[s].bus_width    = flags & 0x03;
        slots[s].dma_capable  = (flags >> 2) & 0x01;

        uint8_t mem_exp       = bus_read_config(0x0C);
        slots[s].mem_size     = mem_exp ? (1UL << mem_exp) : 0;

        // Read name
        uint8_t name_len = bus_read_config(0x14);
        if (name_len > 31) name_len = 31;
        for (int i = 0; i < name_len; i++)
            slots[s].name[i] = bus_read_config(0x15 + i);
        slots[s].name[name_len] = '\0';

        // Validate checksum
        int total_len = 0x15 + name_len;  // last byte = checksum
        if (!validate_checksum(s, total_len)) continue;

        slots[s].present = 1;
        count++;
    }

    bus_enum_mode(0);

    // Assign addresses - largest first, naturally aligned
    bus_assign_addresses(slots, MAX_SLOTS);

    // Program bridge
    for (int s = 0; s < MAX_SLOTS; s++) {
        if (!slots[s].present) continue;
        bus_set_slot_base(s, slots[s].base_addr);
        bus_set_slot_size(s, slots[s].mem_size);
        bus_enable_slot(s);
    }

    return count;
}

void bus_assign_addresses(slot_info_t *slots, int n) {
    // Simple largest-first allocator
    // Sort indices by mem_size descending
    int order[MAX_SLOTS];
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 0; i < n - 1; i++)
        for (int j = i + 1; j < n; j++)
            if (slots[order[j]].mem_size > slots[order[i]].mem_size) {
                int tmp = order[i]; order[i] = order[j]; order[j] = tmp;
            }

    uint32_t next_addr = 0x000000;  // start of bus address space

    for (int i = 0; i < n; i++) {
        int s = order[i];
        if (!slots[s].present || slots[s].mem_size == 0) continue;

        // Align to mem_size boundary
        uint32_t align = slots[s].mem_size;
        next_addr = (next_addr + align - 1) & ~(align - 1);

        slots[s].base_addr = next_addr;
        next_addr += slots[s].mem_size;
    }
}
```

---

## Appendix C: CPU Bridge Summary

LoV = estimated Lines of Verilog for a minimal bridge implementation.

| CPU | Data | Wait Mechanism | IRQ Mapping | Address Latch | Bridge LoV (est.) |
|-----|------|----------------|-------------|---------------|------------|
| 6502 | 8 | RDY pin | IRQ/NMI → any slot | No | ~200 |
| Z80 | 8 | /WAIT | IM 2 vectors | No | ~250 |
| 8088 | 8 | READY (sync) | 8259 vectors | Yes (ALE) | ~300 |
| 8086 | 16 | READY (sync) | 8259 vectors | Yes (ALE) | ~350 |
| 80186 | 8/16 | READY (built-in) | Built-in PIC | Yes (ALE) | ~250 |
| 80286 | 16 | READY (sync) | 8259 vectors | No | ~150 |
| 80386 | 32 | READY (sync) | 8259 vectors | No | ~250 |
| 68000 | 16 | /DTACK (async) | IPL encoder | No | ~50 |
| 68030 | 32 | /DSACK (async) | IPL encoder | No | ~30 |
| 68040 | 32 | /TA (sync) | IPL encoder | No | ~300 |
| FemtoRV | 32 | mem_rbusy | Direct (32-src) | No (FPGA) | ~150 |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-03-26 | Initial draft |
| 0.2 | 2026-03-29 | Clarified byte ordering (big-endian on bus, §4.7). Deferred I/O space to phase 2 (config ROM fields reserved). Immediate /BERR for unmapped addresses (§4.5). Fixed IRQ pulse width to absolute 100ns. Added hot-plug statement (§11.2). Minor diagram and label fixes. |
