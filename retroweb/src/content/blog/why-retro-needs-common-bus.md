---
title: "Why Retro Computing Needs a Common Bus"
pubDate: 2026-04-20
summary: "Every retro builder reinvents the wheel. Here's how a shared bus standard turns isolated projects into a leverage-able ecosystem."
tags: [community, architecture, bus-standard]
---

Walk through the retro computing corner of the internet and you'll see something
remarkable: dozens of talented builders, each assembling their own vision of
what a modern vintage computer should be. One person has a gorgeous HDMI card
for a Z80 system. Another has written a beautiful FAT32 driver for a 6502.
Somebody in Germany is shipping the cleanest 68k peripheral board you've ever
seen.

And almost none of it works with each other.

## The silo tax

Every project starts from zero. New builder picks a host CPU, picks a connector,
picks a signalling scheme, picks a memory map, picks an interrupt convention,
picks a driver API. Each of those decisions is defensible in isolation. Taken
together, they mean the FAT32 driver written for Project A cannot be used in
Project B without a rewrite, the HDMI card cannot be moved between systems
without a redesign, and the community's total output is a pile of clever
but unconnected monuments.

The tax we're paying is not intellectual. It's logistical. Every new card needs
its own PCB run, its own firmware, its own documentation. Every new system
re-solves problems the community solved three years ago. We're a cottage
industry of one-offs.

## What the old standards got right

The platforms we're trying to honor — the Apple II, the Amiga, the PC/AT, the
Atari ST — were successful in part because they shipped a bus. Apple II slots
gave the community a shared surface to build against. Anybody could ship a
card, and anybody who owned the machine could plug it in. The bus was
deliberately simple, deliberately documented, and deliberately stable.

That is the quiet miracle behind a lot of those ecosystems. Not the CPU. Not
the OS. The fact that four generations of hardware, software, and weird-idea
projects could all share one physical and logical socket.

Modern retro projects have mostly skipped this step. We've gone straight from
"here is a CPU" to "here is a complete integrated system," and in doing so
we've cut the community off from the leverage that bus standards provided
the originals.

## What a shared bus unlocks

Think about what changes the day there's a common interface:

- **Driver portability.** Write a FAT32 driver once. It works on every host
  CPU that speaks the bus, whether it's a 68k SBC, a 6502 homebrew, or an
  FPGA soft core. Your driver becomes part of a shared library instead of
  a one-off.
- **Card marketplace.** A builder in Sweden designs an HDMI card. A builder
  in Texas designs a PS/2 card. A user in Japan buys both and plugs them
  into his homebrew Z80 system. None of these three people had to coordinate
  with the others.
- **Shared debugging.** "My card doesn't enumerate" becomes a question the
  whole community can help answer, because everybody is working against the
  same spec.
- **Documentation leverage.** One well-written bus spec teaches dozens of
  projects. Compare that to thirteen different projects each with their own
  half-finished README.
- **Testing surface.** The bus becomes a place you can plug test fixtures
  into. Signal capture, conformance tests, regression rigs — all portable.

None of this is exotic. It's the ordinary benefit of having a standard. We
just haven't given ourselves one.

## Why now, why open-source FPGAs

The reason this conversation is worth having in 2026 and not 1996 is that
the cost of producing programmable hardware has collapsed. An ECP5-class
FPGA board costs about the price of a nice dinner. The toolchain is
open-source end to end (Yosys, nextpnr, OpenFPGALoader), which means a
bus specification can ship as Verilog modules that anybody can synthesize
and verify without a six-figure EDA license.

That changes the politics. A bus standard backed by reference Verilog you
can read, fork, and improve is very different from a bus standard backed
by a PDF and a legal agreement. It's a living artifact. You can submit a
pull request against it.

## A concrete starting point

As a strawman, here's the memory map the FemtoRV co-processor reference
implementation uses today. It's not a proposal for The Standard. It's an
existence proof that a bus map for a real, useful peripheral can fit on
one screen.

```text
0x000000-0x007FFF   32 KB BRAM           (boot ROM with SD boot loader)
0x400000+           IO devices           (one-hot addressing)
                    UART, LEDs, 7-seg, Timer,
                    PS/2 Keyboard, GPU, FM synth,
                    SD Card, Interrupt Controller,
                    Hardware Config
0x800000-0x80FFFF   64 KB kernel space   (RetroKernel)
0x810000-0x9FFFFF   ~2 MB program space
0xA00000-0xA7CFFF   512 KB framebuffer   (640x400x16 bpp, stride 2 KB)
0xA7D000-0xEFFFFF   ~4.5 MB free
0xF00000-0xFFFFF0   1 MB stack           (SDRAM, grows down)
```

And here's the shape a driver call looks like in the reference system, so
you can see how a portable API might read:

```c
// Play a PCM sample from a file on the SD card.
int fd = rk_open("/samples/boot.raw", O_RDONLY);
uint8_t buf[1024];
int n;
while ((n = rk_read(fd, buf, sizeof buf)) > 0) {
    audio_queue_pcm(buf, n);
}
rk_close(fd);
```

Imagine that exact snippet compiling and running unchanged whether the host
is a FemtoRV, a 68008, or a Z80 with an FPGA peripheral bridge. That is the
prize.

## This is a draft, on purpose

I am not proposing a final spec in this post. A bus standard cannot come
from one person in one blog post. It has to be pressure-tested against
half a dozen real projects — different host CPUs, different peripheral
ambitions, different clock domains — before it earns the right to be
called a standard.

What I am proposing is the conversation. If you've built a retro project
and you've privately wished you could reuse someone else's card or
someone else's driver, that wish is the point. Let's design the socket
that makes the wish cheap.

## How to help

- File an issue on
  [the learn-fpga repository](https://github.com/benpayne/learn-fpga/issues)
  describing what kind of card or driver you'd want portability for.
- If you have a retro project in flight, describe its bus in a blog post
  of your own. The more concrete references we have, the easier the
  common denominator is to spot.
- If you want to build a card against the tentative FemtoRV co-processor
  map, try it. Nothing teaches a spec's weaknesses faster than a second
  implementation.

The goal is simple: turn a pile of isolated monuments into an ecosystem.
The window is open. Let's use it.
