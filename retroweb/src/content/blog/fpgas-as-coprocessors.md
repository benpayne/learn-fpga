---
title: "FPGAs as Co-Processors: The Missing Piece for Retro Computing"
pubDate: 2026-04-18
summary: "A $15 FPGA gives any vintage system modern peripherals: HDMI, PS/2, audio, SD cards. Here's why that pattern changes the retro computing calculus."
tags: [fpga, architecture, coprocessor]
---

The CPU in your old machine is fine.

That sentence is almost the whole thesis. A 6502, a Z80, a 68k, an 8086 —
these parts were engineered to last, and the ones still in working order
today will almost certainly still work in another thirty years. The
silicon is not the problem. The silicon is honest.

The problem is everything else. The CRT is dim or dead. The floppy drive
needs belts. The video chip has a weird green tint you've learned to
read through. The keyboard controller is a Frankenstein of a bad key
matrix and a tired rubber dome. Nothing that plugs into the back of the
machine exists on the shelf anymore. The authentic experience has
increasingly become an exercise in triage.

## The co-processor pattern

Here is the shape of a modern answer: a small RISC-V soft core running
on a cheap FPGA, sitting beside the original CPU on the bus. The old
CPU keeps doing what it's always done. The FPGA handles the things the
old CPU was never supposed to outlive — the video output, the keyboard,
the storage, the audio.

```
+-------------+            +-------------------------------+
|  Retro CPU  | <-- bus -->|   FPGA Co-Processor           |
|  68k / 6502 |            |                               |
|  Z80 / 8086 |            |   RISC-V core  +              |
+-------------+            |   HDMI / PS2 / SD / audio     |
                           +-------------------------------+
```

This is not emulation. The old CPU is real. It fetches real instructions
from real RAM. The FPGA is a peripheral — the same role the 6522 or the
TMS9918 played in the original design, but implemented in programmable
logic instead of mask-programmed silicon.

## Why not just replace the old CPU?

Because the point of retro computing is the retro computing. There is
something irreducible about watching a real Z80 execute real code through
a real bus. Emulators are wonderful. They are also not the same thing.
The community that cares about these machines cares about them as
artifacts, not just as programming environments.

The co-processor pattern respects that line. It doesn't replace the soul
of the system; it gives the soul a modern body.

## What the FPGA brings

Once you have a RISC-V core with room to spare on an ECP5 or ICE40, the
peripheral list writes itself:

- **HDMI output.** A clean, sharp modern display. 640x400 at 16 bpp, or
  higher if you're willing to run a faster pixel clock. No analog
  degradation, no broken electron gun, no tint drift. Looks like it did
  when it was new, without any of the old fragility.
- **PS/2 or USB keyboard.** Modern mechanical keyboards, scan-code
  translation to whatever matrix the host expected. Bonus: the FPGA can
  paper over keyboard quirks at the hardware level.
- **Audio.** FM synthesis for SID-style work, sampled PCM for digitized
  audio, I2S to any modern DAC. Output goes through a clean signal
  chain, not through a capacitor that dried out in 1994.
- **Storage.** FAT32 on a microSD card. Compatible with modern
  operating systems when you unplug it, with gigabytes of space for
  disk images, source code, samples, and documentation. Hot-pluggable.
  Cheap.
- **Chip-level replacements.** Sometimes the most useful thing the
  FPGA does is be a part that isn't made anymore. A dead 6522 or a
  broken CIA can be implemented in programmable logic as a drop-in
  replacement, with behavior cross-checked against the original's
  datasheet.

And all of it can be updated later, without unsoldering anything.

## Cost and toolchain

The specific board the reference implementation targets is the Colorlight
i5, which retails for $15-25 and mounts an ECP5 LFE5U-25F. It's not the
only viable board; any ECP5 or ICE40 of moderate size works. What matters
is that the entire toolchain is open source — Yosys for synthesis,
nextpnr for place and route, OpenFPGALoader for programming. There is
no vendor IDE. There is no six-month evaluation license. You install
the tools, you type `make`, you get a bitstream.

That openness is a big deal for a community project. A closed vendor
chain means every contributor pays a tax in time and money just to
participate. An open chain means a student can clone a repo on a
Tuesday and have a flashable bitstream by Wednesday.

## Real numbers from a real build

The reference build on the Colorlight i5 runs a FemtoRV `petitbateau`
core (RV32IMFC) at 25 MHz. Some working numbers from that system:

- **4.7 MIPS** sustained on register-to-register integer work.
- **4.38 DMIPS** on Dhrystone 2.1 (0.175 DMIPS/MHz).
- **952 KFLOPS** through the FPU.
- **3,034 KB/s** memcpy through the 64-entry write-through SDRAM cache.
- **640x400 at 16 bpp** HDMI output, sourced from an SDRAM framebuffer
  with scanline bursts and ping-pong line buffers.
- **48 kHz stereo audio** mixed from a 4-voice 4-operator FM synthesizer
  plus a 1024-sample PCM ring buffer.
- **71% block RAM, 57% LUT, 30% timing margin** at 25 MHz — meaning
  there's still room to add features without redoing the synthesis
  budget.

These are not class-leading numbers and they are not trying to be.
They are very much more than enough to play the peripheral role for
any realistic retro host. Nothing on this list is a limit; most of
them are comfortable defaults.

## The updatable firmware win

The part that I keep coming back to: this thing is reflashable.

A traditional peripheral card shipped in 1987 was a fixed artifact.
If the manufacturer discovered a bug, you waited for v2 and bought
another PCB. If you wanted a new feature, you bought a different card.
If the standard shifted under you, your card became a paperweight.

An FPGA-based peripheral ships a firmware, and firmware gets better.
Bug in the SD card driver? Push a new bitstream. Want to add VT100
escape codes to the HDMI text mode? Push a new bitstream. Somebody
in the community writes a better FM synth? Pull their changes and
push a new bitstream.

The card you own this year is not the same card you'll own two years
from now, and that's a feature.

## Where this is going

The near-term roadmap is ordinary: add more peripherals, smooth the
driver API, document the memory map, publish reference schematics.
The slightly-further-term roadmap is the interesting one: standardize
the bus so that the same FPGA peripheral board can be plugged into
anybody's retro system, not just the reference FemtoRV host.

If that works, the cost of bringing a vintage machine back into daily
use drops from "redesign the whole peripheral stack" to "plug in the
card." That is a different world.

The old CPU is fine. It's time to give it fresh eyes, fresh ears, and
a modern SD slot.
