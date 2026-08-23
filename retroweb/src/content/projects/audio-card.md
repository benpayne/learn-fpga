---
title: "Audio Card"
description: "Reference audio peripheral: 4-voice 4-operator FM synthesis plus sampled PCM playback, mixed and emitted via I²S DAC. Drops into any Retro-Active backplane slot."
image: ./audio-card-card.svg
components:
  - "Small FPGA (ICE40 LP1K-class) for the synth core"
  - "I²S audio DAC (PCM5102 or similar)"
  - "1024-sample × 16-bit PCM ring buffer"
  - "8 voice-preset registers (FM operator parameters)"
  - "Sine ROM (2 KB, 12-bit lookup)"
  - "Optional: PWM headphone output for builds without a DAC"
order: 7
links:
  - label: "Bus standard"
    url: "/learn-fpga/architecture/"
  - label: "Reference FM synth (FemtoRV co-processor)"
    url: "/learn-fpga/projects/femtorv-coprocessor/"
---

A reference **audio card**. FM synthesis (the OPL/YM2151 idiom — four operators per voice, four voices time-multiplexed) plus a sampled-audio ring buffer for PCM playback. Output to an I²S DAC.

Status: **design phase**, building on the synth that already runs on the [FemtoRV co-processor](/learn-fpga/projects/femtorv-coprocessor/).

## What the card does

Two audio engines on one card, mixed at the output stage:

### FM synthesizer

- 4 voices, each 4-operator (FM with feedback)
- 8 program presets in registers (operators × envelope × algorithm)
- Voice → preset assignment + per-voice frequency / gate / volume
- Sine ROM lookup (2 KB, 12-bit) shared across operators via TDM
- Output: 16-bit signed at 48 kHz

### PCM playback

- 1024-sample × 16-bit ring buffer in BRAM
- Software writes samples; the card consumes at 48 kHz
- Half-empty interrupt fires `IRQ_n` so the host can refill
- Output: 16-bit signed, summed with the FM stage via a saturating 17-bit adder

### Output stage

- I²S serial out to an external DAC (PCM5102 is the canonical choice — cheap, 24-bit capable, no driver needed)
- BCLK / LRCLK / DATA / GAIN pins
- Optional secondary path: 1-bit PWM out for ultra-cheap builds (no DAC; usable but lossy)

## Bus interface

Lives in one slot's 64 KB window:

| Range | Purpose |
|---|---|
| `+0x0000 – +0x000F` | Master volume / enable / mode |
| `+0x0010 – +0x003F` | Per-voice control (freq, gate, preset, vol) × 4 voices |
| `+0x0040 – +0x00FF` | Preset registers (operator × envelope × algo) × 8 presets |
| `+0x0100 – +0x017F` | PCM ring buffer status (read pointer, level, half-empty mask) |
| `+0x0180 – +0x097F` | PCM ring buffer (write window — 1 KB visible at a time, mapped through a write pointer) |

Half-empty interrupt is the card's main reason to fire `IRQ_n`. Software responds by writing the next 512 samples through the ring-buffer window.

## Why an FPGA again

Same answer as the [video card](/learn-fpga/projects/video-card/): four-operator FM at 48 kHz with envelope generators is several hundred ANDs/ORs and a multiplier per cycle. Out of reach for pure 74-series; comfortable in a small FPGA. The FemtoRV reference build does this at full speed in roughly 700 LUTs.

## Dependencies

- **Bus standard** (done)
- **A main board** to plug the card into
- An **audio driver** in the [driver library](/learn-fpga/projects/driver-library/) — the existing `play.c` reference is a good starting point
- Software that wants to make noise: a tracker-style player or a FreeDOS-port-of-Adlib-Tracker, both excellent test cases

## Next steps

1. Re-package the existing FM synth as a slot-shaped module.
2. Add a small write-only "preset upload" API distinct from per-voice control so musicians don't fight the registers.
3. Card layout (this one is a small board — DAC, power, connector).
4. Document the register map and preset format.

Contributions wanted: musicians who can write convincing test instruments, hardware reviewers familiar with I²S DACs, anyone willing to write a tracker for the platform.
