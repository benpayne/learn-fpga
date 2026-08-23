---
title: "I/O Card"
description: "Reference I/O peripheral: SD card mass storage (FAT32), UART serial, and PS/2 keyboard. The 'console + storage' card for any Retro-Active build."
image: ./io-card-card.svg
components:
  - "SD card socket (microSD or full-size)"
  - "UART transceiver (MAX3232 for RS-232 levels) + DB9 or 6-pin Dupont"
  - "PS/2 mini-DIN connector + line clamp"
  - "Either: a small FPGA (ICE40 LP1K) for all three, OR a 65C51 / 16550 UART + bit-bang SD + PS/2 controller IC"
  - "Optional: RTC chip (DS3231 over I²C) on a header"
  - "Reserve pins / bus space for future USB host"
order: 8
links:
  - label: "Bus standard"
    url: "/learn-fpga/architecture/"
  - label: "Reference SD/PS2 implementation (FemtoRV co-processor)"
    url: "/learn-fpga/projects/femtorv-coprocessor/"
---

The third "always need one" peripheral after [video](/learn-fpga/projects/video-card/) and [audio](/learn-fpga/projects/audio-card/): an **I/O card** that gives the system mass storage, a serial console, and a keyboard.

Status: **design phase**.

## What's on the card

### SD card slot

The mass-storage path. SPI-mode SD card is the simplest option: four signals (CLK, MOSI, MISO, /CS) plus power, FAT32 filesystem, no driver-side wear-leveling needed because that's the card's job. Bit-banged from the bus is possible but slow (~30 KB/s on a 1 MHz 6502). A small FPGA on the card, or a dedicated SPI master, gets you 1–3 MB/s.

### UART serial

The serial console. 115200-N81 is the canonical baud. Two implementation options:

- **Discrete-friendly**: 65C51 or 16550 UART chip + MAX3232 level shifter. Both still in production. Three or four chips total.
- **FPGA-friendly**: a soft UART core in the same FPGA that does SD + PS/2.

Either way the board exposes a DB9 or 6-pin Dupont header.

### PS/2 keyboard

Standard 6-pin mini-DIN. PS/2 is a synchronous serial protocol with a clock the keyboard generates; the card needs an edge-triggered shift register and a small FIFO of decoded scan codes for the host to pull from. Either soft (FPGA) or hard (a dedicated PS/2 controller IC like the AT89C51 — though those are scarce now).

The existing [FemtoRV PS/2 controller](/learn-fpga/projects/femtorv-coprocessor/) has all this logic implemented and tested; re-packaging it as a card is mostly hookup work.

### Optional extras

- **RTC** — DS3231 via I²C on a header. Tiny, cheap, fixes timestamps.
- **GPIO** — a 4× or 8× open-drain header for builders to wire whatever they want.
- **USB host** — reserved pins on the slot connector and reserved space in the register window. Not v1.

## Bus interface

Slot's 64 KB window divides three ways:

| Range | Purpose |
|---|---|
| `+0x0000 – +0x00FF` | Card identification, status, IRQ enable mask |
| `+0x0100 – +0x01FF` | UART control + 256-byte RX FIFO read window |
| `+0x0200 – +0x02FF` | PS/2 status + scan-code FIFO read window |
| `+0x0300 – +0x03FF` | SD card command / status / data sliding window |
| `+0x0400 – +0xFFFF` | Reserved (RTC mailbox, GPIO, future USB) |

Each subsystem can fire `IRQ_n` on its own conditions: UART RX-not-empty, PS/2 byte available, SD-DMA-complete. The host's interrupt controller distinguishes which slot fired, then this card's driver code reads its own status register to learn which subsystem fired.

## Dependencies

- **Bus standard** (done)
- **A main board** to plug into
- An **I/O driver** stack in the [driver library](/learn-fpga/projects/driver-library/) — three drivers really: SD/FAT32, UART, PS/2

## Next steps

1. Decide: one FPGA or three discrete chips? The right answer is "ship both options" but v1 picks one. The FPGA option is faster to prototype.
2. Re-package the FemtoRV SD + PS/2 + UART blocks.
3. Card layout — connector-heavy, so this is the largest card mechanically.
4. Document the register map.

Contributions wanted: anyone who's done FAT32 on a tight budget (driver code reuse), reviewers familiar with PS/2 timing edge cases (key release vs. key make handling).
