---
title: "68000 Reference Main Board"
description: "A finished 68000-based main board: CPU, the 68k bus bridge, RAM, ROM, IPL priority encoder, and four backplane connectors. The starter board for a 16-bit Retro-Active build."
image: ./68000-reference-mainboard-card.svg
components:
  - "Motorola MC68000P10 (10 MHz DIP) or MC68000FN16"
  - "Retro-Active 68k bridge (PAL build, 6 chips, or pure-74 build, 12 chips)"
  - "32 KB boot ROM (parallel, 8-bit or 16-bit wide)"
  - "256 KB DRAM or SRAM (16-bit wide)"
  - "Slot interrupt path: 2× 74LS148 priority encoders → /IPL[2:0]"
  - "4 × DIN 41612 96-pin backplane connectors"
order: 5
links:
  - label: "Bus standard (Architecture)"
    url: "/learn-fpga/architecture/"
  - label: "68000 Bridge project"
    url: "/learn-fpga/projects/68k-bridge/"
  - label: "Backplane reference"
    url: "https://github.com/benpayne/learn-fpga/blob/master/bus-design/docs/backplane.md"
---

The 16-bit counterpart to the [6502 main board](/learn-fpga/projects/6502-reference-mainboard/). Same shape — CPU + bridge + RAM + ROM + slots — but with the 68000's wider data path, full 24-bit address bus, and asynchronous /AS+/DTACK handshake.

Status: **planned** (design phase).

## What's on the board

1. **CPU** — a real Motorola MC68000 in a 64-pin DIP socket. The 10 MHz P-grade is the easy choice; the 12.5 MHz or 16 MHz parts work too if the rest of the timing budget allows.
2. **The bridge** — the [6-chip PAL build](/learn-fpga/projects/68k-bridge/). The 68k's full 23-bit address bus passes through the bridge to the bus, so a 68k system that puts its IO at `0x400000-0x4FFFFF` lands cleanly on the right slots without any extra glue.
3. **ROM** — 32 KB minimum; 64 KB if you want a real monitor + a small BASIC. Maps high (0xFE0000–0xFFFFFF) so the 68k's reset vectors at 0x000000–0x000007 can come from ROM at boot, then RAM after the boot copies vectors down.
4. **RAM** — 256 KB is comfortable for a 68k system; less is possible. 16-bit-wide SRAM (or DRAM with a refresh controller) sits in the low end of the address space.
5. **IPL priority encoder** — two cascaded 74LS148s convert the 16 per-slot `IRQ_n` lines into the 68k's 3-bit `/IPL[2:0]` priority code. No microkernel-side aggregation register needed; the 68k's interrupt vector handles steering.
6. **Backplane** — same 4-slot DIN 41612 connector setup as the 6502 board.

## Why the 68k case is "easier" software-wise

A 68k system has 16 MB of address space, so it can map the full bus directly *and* keep its local RAM/ROM at low addresses. There's no equivalent of the 6502's "which slot do I see?" problem — every slot is reachable from any 68k address in the IO region.

That makes the 68k a better target for the multi-user OS variant. With 256 KB of RAM and a full 24-bit address space, you can run a small kernel + multiple user processes + a file system without straining the address map. Adding an external MMU (a 74-series-friendly 4×4 KB page table chip, or one of the 68000-era memory mapping IC families) gives you proper process isolation.

## Open design questions

- **DRAM vs SRAM** — DRAM is cheaper per bit but needs a refresh controller (~3 chips of glue or one PAL). SRAM is plug-and-play but more expensive. Probably DRAM for the v1 board to keep the BOM honest about a "real" 68k system.
- **Bus error / abort** — the 68k has a /BERR input the bridge currently ignores. The board needs a watchdog: if a card cycle takes longer than ~10 µs without /DTACK, raise /BERR so the CPU can recover.
- **Function code (FC0–FC2)** — supervisor vs. user mode. Plumbed for future use? Or ignored for v1?
- **DTACK pull-up** — the /DTACK line on the slot connector needs a pull-up (cards drive it active-low when responding). Where does that resistor live?

## Dependencies

This board cannot be built before the **68k bridge** runs on real hardware (currently sim-only, like the 6502 bridge), and a **DRAM refresh controller** design exists if we go that route. It does not depend on any peripheral card existing.

## Next steps

1. Pick DRAM or SRAM.
2. Schematic in KiCad.
3. Bring up the bridge on a breadboard against a real 68000.
4. PCB layout, fabrication, first article.
5. Open BOM and Gerbers.

Contributions wanted: 68000 hardware reviewer, KiCad library curator, anyone who's done a 68k DRAM refresh circuit before.
