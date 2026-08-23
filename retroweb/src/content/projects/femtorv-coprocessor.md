---
title: "FemtoRV Retro Co-Processor"
description: "A RISC-V co-processor for vintage computers — HDMI GPU, PS/2 keyboard, FM synth, SD card, all on a $15 FPGA."
image: ./femtorv-board.svg
components:
  - "Colorlight i5 (ECP5 LFE5U-25F)"
  - "FemtoRV petitbateau (RV32IMFC core)"
  - "8 MB SDRAM (EM638325) with write-through cache"
  - "HDMI tri-mode GPU (text, bitmap, 640×400×16bpp framebuffer)"
  - "4-voice 4-operator FM synthesizer + 48 kHz PCM mixer"
  - "PS/2 keyboard controller with interrupt-driven scan decoder"
  - "SD card over SPI, FAT32 read"
  - "Custom 32-source edge-triggered interrupt controller"
links:
  - label: "Source code on GitHub"
    url: "https://github.com/benpayne/learn-fpga"
  - label: "Project CLAUDE.md (developer notes)"
    url: "https://github.com/benpayne/learn-fpga/blob/master/CLAUDE.md"
order: 1
---

## What it is

The **FemtoRV Retro Co-Processor** is a working demonstration of the
Retro-Active pattern: a small, updatable RISC-V core that lives next to a
vintage CPU and hands it all the peripherals a modern user expects — HDMI
output, PS/2 keyboard input, SD-card mass storage, and audio synthesis — on
a commodity FPGA board that costs about the price of a restaurant lunch.

The core is Bruno Levy's **FemtoRV petitbateau**, the RV32IMFC variant of
the FemtoRV family, running at 25 MHz on the ECP5-based Colorlight i5. It
is small enough to live comfortably beside a 6502, 68000, or Z80, and
open-source enough that every peripheral, every driver, and every bitstream
can be rebuilt from scratch with Yosys, nextpnr, and a RISC-V GCC.

## Why co-process?

Vintage CPUs are charming, but their I/O is a liability. A real 6502 has no
way to speak HDMI. A real Z80 can't read a FAT32 SD card without a heroic
driver stack. Every modern peripheral a retro builder wants to add ends up
eating a card slot and a weekend of timing analysis.

The co-processor moves that work to a chip that's built for it. The host
CPU talks to a simple memory-mapped interface; FemtoRV takes care of the
rest — scan-code decoding, scanline generation, FM synthesis, filesystem
parsing. Firmware updates are a `make && openFPGALoader`, not a board
respin.

## Numbers

| Metric               | Value                                  |
| -------------------- | -------------------------------------- |
| CPU performance      | **4.7 MIPS**, **4.38 DMIPS** (Dhrystone 2.1) |
| FPU performance      | **952 KFLOPS**                         |
| Memory bandwidth     | **3 MB/sec** (memcpy, 64 KB block)     |
| DMIPS/MHz            | 0.175                                  |
| LUT usage            | **57 %** (13,937 / 24,288)             |
| Block RAM            | 71 % (40 / 56)                         |
| Timing margin        | Max 32.6 MHz — **30 %** slack at 25 MHz |

That headroom matters: it means every peripheral listed below is running
concurrently, and the core still has cycles to spare for the host
interface.

## What it can do today

- Boot from SD card into a RetroKernel shell (Unix-style `ls`, `cat`,
  `cp`, `rm`, `mkdir`, and a program loader with XMODEM upload)
- Render an 80-column, 16-color text console to HDMI at 640×400
- Display RGB565 framebuffers pulled from SDRAM via a burst scanline
  fetch engine and ping-pong line buffer
- Play 4-voice 4-operator FM synthesis mixed with 48 kHz PCM samples
  over I²S or a PWM DAC
- Decode PS/2 scan codes into ASCII with modifier tracking, via a
  32-source edge-triggered interrupt controller
- Execute cached reads from 8 MB of external SDRAM with zero stall on
  hit, served by a 64-entry direct-mapped write-through cache

Everything above has cocotb testbenches in `FemtoRV/TEST/` and has been
verified on hardware.

## The vision

This project is the proof of concept for the wider Retro-Active idea: if
the community agrees on a common bus and a common peripheral interface,
one well-engineered co-processor can ride along with a 6502 SBC, an
FPGA-recreated Amiga, or a restored vintage workstation. The same SD
driver, the same font ROM, the same FM voice presets all come along for
free.

## What's next

The near-term roadmap: a VT100/ANSI terminal mode on the GPU, LFO and
operator feedback for the synth, a 2-way set-associative SDRAM cache, and
— most importantly — a physical retro bus interface so the co-processor
can drop into a real vintage card cage instead of sitting on a bench next
to one.

Source, schematics, and build instructions are all on GitHub. Patches and
pull requests very welcome.
