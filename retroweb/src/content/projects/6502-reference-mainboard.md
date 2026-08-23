---
title: "6502 Reference Main Board"
description: "A finished 6502-based main board: CPU, the 6502 bus bridge, ROM, RAM, a slot interrupt controller, and four backplane connectors on one PCB. The starter board for an 8-bit Retro-Active build."
image: ./6502-reference-mainboard-card.svg
components:
  - "MOS 6502 (or WDC 65C02 — pin-compatible)"
  - "Retro-Active 6502 bridge (PAL build, 4 chips, or pure-74 build, 9 chips)"
  - "8 KB or 32 KB ROM (boot loader + monitor)"
  - "32 KB or 64 KB RAM"
  - "Slot interrupt controller (1× 22V10 + 1× 74LS244)"
  - "4 × DIN 41612 96-pin backplane connectors"
  - "Reset / clock / power circuitry"
order: 4
links:
  - label: "Bus standard (Architecture)"
    url: "/learn-fpga/architecture/"
  - label: "6502 Bridge project"
    url: "/learn-fpga/projects/6502-bridge/"
  - label: "Backplane reference"
    url: "https://github.com/benpayne/learn-fpga/blob/master/bus-design/docs/backplane.md"
---

This is the **starter board** for an 8-bit Retro-Active build. The bus standard and the bridge get you abstract behaviour; this gets you a piece of FR-4 you can put a 6502 into, plug peripheral cards into, and turn on.

Status: **planned** (design phase).

## What's on the board

A minimum viable main board is six functional blocks on one PCB:

1. **CPU** — a real MOS 6502 or WDC 65C02 in a 40-pin DIP socket. Both are pin-compatible; the 65C02 is more forgiving and runs faster.
2. **The bridge** — the [4-chip PAL build](/learn-fpga/projects/6502-bridge/) drives the bus. The bridge's `BUS_ADDR_BANK` parameter is set to `0x40` for this board, mapping the 6502's full 64 KB onto slot 0's register window.

Wait — that decision actually pushes back on the rest of the design. If the 6502 sees only one slot, every peripheral it talks to has to live in that slot. So the board needs to combine slot-0 services on one card, *or* expose a small bank register that lets software pick which slot it sees. The latter is the right answer for any non-trivial system. We'll prototype the simple "slot-0 only" case first and add the bank register in revision B.

3. **ROM** — 8 KB minimum (boot loader + monitor); 32 KB if you want headroom for an editor or a small BASIC. Mapped at the top of the 6502's address space (0xE000–0xFFFF or 0x8000–0xFFFF).
4. **RAM** — 32 KB or 64 KB SRAM, mapped from 0x0000 upward. Anything not RAM, ROM, or the bridge window gets bus cycles.
5. **Slot interrupt controller** — collects 16 `IRQ_n` lines from the backplane, ORs them into the 6502's `/IRQB`, and exposes a status register so software can find which slot fired. One 22V10 plus a 74LS244 for the read-back path; lives in a fixed register at the top of the 6502 IO window.
6. **Backplane** — four DIN 41612 96-pin connectors wired per the [backplane reference](https://github.com/benpayne/learn-fpga/blob/master/bus-design/docs/backplane.md), with the slot decoder and shared CLK/RESET on-board.

## Why a 4-slot baseline

Real builds want 6 or 8 slots, but the first PCB should be small enough to be cheap and quick to revise. Four slots is enough for video + audio + I/O + one experiment, which is the right shape for a first build. The spec supports 16; later board revisions can grow to 6 or 8 (or you build a separate passive backplane card and the main board has a single slot to plug into it — that's the path to a full 16-slot rack).

## Open design questions

- **Bank register vs. slot-0 only.** Decide for v1.
- **Clock**: a single 25 MHz crystal feeds the bus, and the 6502 runs from a divided-down 1 MHz / 2 MHz / 4 MHz clock derived from it? Or two separate oscillators?
- **ROM type**: a 27C256 EEPROM (still made, but UV-erasable variants are nostalgic) or a Flash device with an in-system programmer?
- **Power**: 5 V only, or a switch to support 3.3 V cards via level shifters in the slot pins?

## Dependencies

This board cannot be built before the **6502 bridge** is on real hardware (currently sim-only) and a **slot interrupt controller** design exists (probably a 22V10 program plus the read-back buffer; needs to be drawn). It does not depend on any peripheral card existing — but it's not useful without at least one.

## Next steps

1. Settle the bank-register decision.
2. Draft a schematic in KiCad.
3. Bring up the bridge on a breadboard against a real 6502 (a step beyond simulation).
4. PCB layout, fabrication, first article.
5. Open the BOM and Gerbers under a permissive license; document a build log.

Contributions wanted: schematic review, KiCad libraries for the chosen connectors, a 6502 board reviewer who's done this before.
