---
title: "Video Card"
description: "Reference video peripheral: HDMI digital output (and optional VGA), text and bitmap modes, character ROM and palette on the card. Drops into any Retro-Active backplane slot."
image: ./video-card-card.svg
components:
  - "Small FPGA (ICE40 LP1K-class, ~1k LUT) for TMDS encoding and scanout"
  - "32 KB VRAM (1× SRAM)"
  - "Character ROM (8×16 VGA-style font, 4 KB)"
  - "16-entry RGB444 palette register file"
  - "HDMI connector + level shifters"
  - "Optional: passive RGB+sync header for VGA"
order: 6
links:
  - label: "Bus standard"
    url: "/learn-fpga/architecture/"
  - label: "Reference HDMI GPU (FemtoRV co-processor)"
    url: "/learn-fpga/projects/femtorv-coprocessor/"
---

A reference **video card** for the Retro-Active backplane. Drops into any slot, presents itself as a video device, drives an HDMI display.

Status: **design phase** — much of the underlying GPU design already exists in the [FemtoRV co-processor](/learn-fpga/projects/femtorv-coprocessor/) and just needs to be re-packaged as a slot card with bus-protocol wrapping.

## Modes

Three display modes the card supports out of the box:

1. **Text mode** — 80×30 characters, 16-bit cells: `{bg[3:0], fg[3:0], char[7:0]}`. CGA-style 4-bit IRGB palette per cell. Character ROM holds an 8×16 VGA font; palette is 16 RGB444 entries software-programmable.
2. **Bitmap mode** — 1, 2, or 4 bits per pixel into a 32 KB VRAM, paged for double-buffering. 4 bpp gives a 320×200 indexed image with the card's 16-entry palette.
3. **Framebuffer mode** — 16 bpp RGB565 from external memory (read directly from the host's RAM, typically over the bus via a burst-read mechanism the bus supports).

## Why an FPGA on the card

Pure 74-series HDMI is impractical — TMDS encoding plus the 250 MHz serial clock for 720p needs gate-level structures that don't exist in standard logic families. A small ICE40 LP1K gives you the encoder, the line-buffer, and the scanout state machine in ~700 LUTs.

This is a place where the bus standard's "implementation neutral" stance gets tested: a builder who *won't* use programmable logic anywhere can still build a video card, but they're looking at a CRTC chip (Motorola MC6845) plus discrete RGB DAC and a VGA connector — no HDMI. We'll publish both options. The FPGA path is the canonical reference; the 74-only path gets its own follow-up.

## Bus interface

The card lives in one slot's 64 KB register window. Within that window:

| Range | Purpose |
|---|---|
| `+0x0000 – +0x000F` | Mode + control registers |
| `+0x0010 – +0x002F` | Palette (16 × 16-bit RGB444 + 4 reserved) |
| `+0x0030 – +0x00FF` | Reserved / future |
| `+0x1000 – +0x4FFF` | Character buffer (16 KB, text mode) |
| `+0x4000 – +0xBFFF` | Bitmap VRAM (32 KB, bitmap mode) |
| `+0xC000 – +0xFFFF` | Status / vsync / hpos read-back |

Writes go through `WSTRB[0..1]` (the card uses both byte lanes); reads return the corresponding bytes via `RSTRB`. VBlank fires the card's `IRQ_n` on the slot connector.

## Dependencies

- **Bus standard** (done — slot register window is 64 KB, byte-lane addressing settled)
- **A main board** to plug the card into ([6502](/learn-fpga/projects/6502-reference-mainboard/) or [68000](/learn-fpga/projects/68000-reference-mainboard/))
- A **video driver** in the [driver library](/learn-fpga/projects/driver-library/) so software can use the card without poking registers directly

## Next steps

1. Pull the [FemtoRV GPU](/learn-fpga/projects/femtorv-coprocessor/) RTL into a card-shaped module with the bus interface as its only external port.
2. Validate it in cocotb against the multi-slot test harness.
3. PCB layout for the smallest practical card.
4. Document the register map as a public spec.

Contributions wanted: reviewers who've done HDMI on small FPGAs, anyone with strong opinions on where text-mode attribute bits should live.
