---
title: "The Retro-Active Roadmap"
pubDate: 2026-05-03
summary: "The bus is the start, not the finish. Here's the full landscape — main boards, peripheral cards, bootloaders, kernels, drivers — and the order they need to land in to make a working ecosystem."
tags: [roadmap, project, architecture, community]
---

So far this site has been about one thing: the **common bus**. Two CPU bridges, a backplane decoder, a pile of cocotb tests, a hundred or so words on what the spec promises. That work is necessary but it's nowhere near sufficient. A bus that nobody plugs anything into is just a piece of inert FR-4.

This post sketches the rest of the iceberg. The goal is to make the *full shape* of a Retro-Active platform legible in one read, so that anyone showing up to the project — to build hardware, to write firmware, to port an OS, to debug somebody else's driver — can find their corner and know what depends on what.

Five buckets of work. Each one has its own page in [Projects](/learn-fpga/projects/) starting today. The text here is the connective tissue.

## Where we are

Done, working in simulation:

- The **bus standard** itself, with 16 slots, per-slot IRQ lines, `74LS154`-decoded slot select, and a pin assignment that fits in DIN 41612.
- A [6502 host bridge](/learn-fpga/projects/6502-bridge/) — 9 chips pure-74, or 4 with a single 22V10.
- A [68000 host bridge](/learn-fpga/projects/68k-bridge/) — 12 chips pure-74, or 6 with a 22V10.
- Multi-card test suites for both CPUs that prove slot isolation: writes to one card don't leak to another, cycles to unpopulated slots correctly fail.

That's the floor. Everything below — the boards, the cards, the firmware — assumes the bus contract holds. If it doesn't, that's a v1.0 spec issue and we go back. So far it's holding.

## Where we're going

A complete Retro-Active *system* — not a bridge, but something a person can boot and use — needs five new pieces of work to come together:

1. **Reference main boards** — the CPU plus the bridge plus RAM, ROM, an interrupt controller, and the slot connectors, all on one PCB. One per CPU family. Today, the bridges live abstractly; tomorrow you order a PCB.
2. **Reference peripheral cards** — at minimum: video, audio, I/O. These are the cards the main board's slots are *for*.
3. **A bootloader** — what the main board's ROM does at power-on. Probe storage, load kernel, jump.
4. **A kernel layer** — small enough to live on every supported CPU, structured as a microkernel so the same core can run a single-user "DOS plus Unix shell" environment *and* a multi-user OS variant on the same hardware.
5. **A portable driver library** — one C source per card type, recompiled for each host CPU via the appropriate GCC backend. Plug a card into any system and the same driver source talks to it.

Each of those is a separate project (literally — see [Projects](/learn-fpga/projects/)). They're sequenced by dependency, not by glamour: bootloaders matter even though kernels are more fun, because there's no kernel without a way to load it.

## Hardware: what plugs in to what

```text
         ┌──────────── Main Board ────────────┐
         │  CPU + Bridge + RAM/ROM + IRQ ctlr │
         │  + 4–8 backplane slot connectors   │
         └────────────────┬───────────────────┘
                          │ Retro-Active bus
                ┌─────────┴─────────────┐
                │                       │
       ┌────────┴───────┐     ┌─────────┴────────┐
       │   Video card   │     │   Audio card     │
       └────────────────┘     └──────────────────┘

          (similar slot for IO, more peripherals, a second host CPU,
           an interrupt controller card — anything that speaks the bus)
```

Two main boards are planned: a [6502 reference](/learn-fpga/projects/6502-reference-mainboard/) and a [68000 reference](/learn-fpga/projects/68000-reference-mainboard/). Both are intentionally minimum-viable: enough RAM/ROM to boot, the host's bridge, the interrupt controller for that host, and four slots. The cards do everything else.

The first three peripheral cards are deliberately the ones every retro computer needs:

- A [video card](/learn-fpga/projects/video-card/) — text and bitmap modes, HDMI out for the modern peripheral side, optional VGA for purists. The character ROM and palette live on the card.
- An [audio card](/learn-fpga/projects/audio-card/) — FM synthesis and sampled playback, I²S DAC, mixer registers exposed in the slot's register window.
- An [I/O card](/learn-fpga/projects/io-card/) — SD-card mass storage, a UART for serial console, a PS/2 keyboard port. Eventually USB host, but not v1.

A 4-slot system populated with all three plus the host fills the chassis comfortably. An 8-slot chassis leaves room for a second host (think 6502 + 68000 in the same backplane — the bus is CPU-independent, after all) or specialty cards.

## Software: bootloader, kernel, drivers

The hardware can be ready to ship before the software is, but a hardware-only platform is a coffee table. Software is where the ecosystem actually shows up.

### Bootloader

Every main board ships with a [bootloader](/learn-fpga/projects/bootloader/) in its boot ROM. It's the BIOS, the monitor, the loader, all in one. It probes the I/O card for storage (SD card, then serial XMODEM as fallback), loads a kernel image into RAM, and jumps. It also exposes a small set of operator commands at the serial console — useful when the kernel won't load.

The existing FemtoRV monitor is the reference for this; the open question is how much it needs to change to be host-CPU-agnostic. Probably most of it ports cleanly to GCC's 6502 / 68k / 8086 backends.

### Microkernel + OS variants

The architectural bet is a [small microkernel](/learn-fpga/projects/microkernel/) that handles only the things the hardware genuinely demands — context switching, IPC, basic memory management — with everything else (file systems, network stacks, drivers) running as user-space services that talk to it via IPC.

That bet is what unlocks two OS personalities on the same kernel:

- A [single-user OS](/learn-fpga/projects/single-user-os/) — small footprint, one program at a time, file system, Unix-style shell with pipes and redirection. This is the "boot to a prompt and run things" experience. Targets the 6502 and similarly tight machines.
- A [multi-user OS](/learn-fpga/projects/multi-user-os/) — preemptive multitasking, multiple terminals, separate user accounts, the works. 16/32-bit CPUs only, because process isolation needs more address space and ideally an MMU.

Same kernel underneath. Different services and shells on top. Builders pick which one fits their hardware.

The 6502 case deserves an asterisk: with no MMU, 64 KB of address space, and no privileged-mode separation, "microkernel" is closer in spirit to "really small monitor" than to L4. We'll be honest about that on the page.

### Drivers

A [portable driver library](/learn-fpga/projects/driver-library/) is the connective tissue. Every card has a driver — one C source file, compiled against the appropriate GCC backend for the host. Card drivers register with the kernel by slot number and present a small API (open / read / write / ioctl-equivalent). The kernel doesn't know what a video card is; it only knows that slot 5 announced itself as type `0x42` and that the driver for type `0x42` is over there.

This is what lets a 68k port of FreeDOS read an SD card written by a 6502 system. The on-disk format is portable (FAT32). The driver that reads the SD card is portable. The CPU that's running the driver is not, and doesn't have to be.

## How the pieces stack

```text
                    ┌─────────────────────────────────────┐
                    │  applications / vintage app ports   │
                    └─────────────────┬───────────────────┘
                                      │
        ┌─────────────────┬───────────┴────────────┐
        │ single-user OS  │      multi-user OS     │
        └─────────────────┴───────────┬────────────┘
                                      │
                    ┌─────────────────┴───────────────────┐
                    │  microkernel  +  driver library     │
                    └─────────────────┬───────────────────┘
                                      │
                    ┌─────────────────┴───────────────────┐
                    │             bootloader              │
                    └─────────────────┬───────────────────┘
                                      │
         ┌────────────────┬───────────┴────────────┬───────────────┐
         │    Main board: CPU + bridge + RAM + ROM + slots         │
         └────────────────┴────────────────────────┴───────────────┘
                                      │
                  ╔═══════════════════╧═══════════════════╗
                  ║         Retro-Active bus              ║
                  ╚═════╤═════════════╤═════════════╤═════╝
                    ┌───┴───┐     ┌───┴───┐     ┌───┴───┐
                    │ Video │     │ Audio │     │  I/O  │
                    └───────┘     └───────┘     └───────┘
```

The dependency arrows mostly point downward. The bus has to be solid before anything else gets built (we're there). Then main boards before cards (cards can be designed in parallel but not tested until a board exists). Then bootloader before kernel (no boot, no kernel). Then microkernel before OS variants. Drivers can develop in parallel against any working card + kernel.

## How to participate

The five buckets above each have their own project page now. Pick the one that matches what you want to do, read the open questions, and weigh in on GitHub Issues. The most useful contributions at this point in the project's life are:

- **Spec critique.** If the bus, the slot model, or the interrupt routing has a hole, point at it specifically. The longer we wait to find them, the more they hurt.
- **Building hardware**, especially in pure 74-series. We have FPGA-based reference implementations of most things but the project leans heavily on having parallel discrete-logic builds — it's how we know the spec is honest.
- **Writing drivers** for any card you can simulate or breadboard, in C against the abstract API.
- **Writing OS code**, especially the microkernel and IPC primitives. Smaller, more conservative designs win here.

If none of that fits but the project still resonates, just say hi. The community is small and a friendly nuisance is more valuable than radio silence.

The next post in this series will pick one of the five buckets — probably the microkernel, because it's the riskiest part of the design — and spec it out in detail. Suggestions welcome.
