---
title: "Driver Library"
description: "One C source per card type. Compiles against any host CPU through the appropriate GCC backend. The connective tissue that makes the card ecosystem actually portable."
image: ./driver-library-card.svg
components:
  - "Portable C drivers, one per card type"
  - "Compiles against cc65, m68k-elf-gcc, i386-elf-gcc, riscv32-unknown-elf-gcc"
  - "Drivers register with the kernel by card type ID"
  - "Standard API: open / read / write / control / poll"
  - "Hardware abstraction layer (HAL) per CPU for register access"
order: 13
links:
  - label: "Microkernel (uses driver services)"
    url: "/learn-fpga/projects/microkernel/"
  - label: "Roadmap blog post"
    url: "/learn-fpga/blog/the-retro-active-roadmap/"
---

The piece of the project that makes the rest *worth doing*.

A bus standard, however clean, is not by itself an ecosystem. An ecosystem is a community where someone designs a card, somebody else writes a driver for it, and a third person plugs that card into a different CPU's machine and the same driver compiled for *their* CPU just works. Without that, every host gets its own driver per card and the project's "implementation-neutral bus" promise dies in detail.

The driver library is the contract that keeps that promise.

Status: **design phase**.

## The contract

Every card driver is a C source file. It implements a small standard API:

```c
struct card_driver {
    uint16_t card_type_id;       // 0x0001 = video, 0x0002 = audio, ...
    const char *name;             // "video-ref-v1"
    int (*probe)(slot_t *slot);   // returns 1 if compatible
    int (*open)(slot_t *slot, int mode);
    ssize_t (*read)(slot_t *slot, void *buf, size_t len);
    ssize_t (*write)(slot_t *slot, const void *buf, size_t len);
    int (*control)(slot_t *slot, int op, void *arg);  // ioctl-equivalent
    int (*close)(slot_t *slot);
    void (*irq_handler)(slot_t *slot, uint32_t irq_status);
};
```

The driver author sees this. The kernel sees this. Nobody sees the host CPU's specifics inside the driver code itself.

## How CPU portability is achieved

Two layers:

1. **Driver code is plain portable C.** No assembly, no machine-specific intrinsics, no register-keyword tricks. Just enums, structs, math, and calls into the HAL.

2. **A tiny per-CPU HAL** handles things that *do* differ:
   - Register read / write at a slot's window (the actual load/store instruction differs by CPU; the HAL turns it into a function call with consistent semantics)
   - Memory barriers / cache management (hosts that need them; many don't)
   - Time and delay (`hal_udelay()`, `hal_now()`)
   - Big-endian vs little-endian byte order (the bus is byte-lane-indexed, but the host might or might not need to byte-swap multi-byte values it reads from card registers)

The HAL is ~1 KB per CPU. Same driver source compiles against four HALs and you get four binaries that all do the same thing.

## Concrete example

A video card driver looks like this (excerpts):

```c
/* video_ref_v1.c — driver for the Retro-Active reference video card */

#include "card_driver.h"
#include "hal.h"

#define V_REG_MODE      0x0000
#define V_REG_PALETTE   0x0010
#define V_TEXT_BUFFER   0x1000

static int video_open(slot_t *s, int mode) {
    hal_reg_write8(s, V_REG_MODE, mode);
    return 0;
}

static ssize_t video_write(slot_t *s, const void *buf, size_t len) {
    /* writes to the text buffer at the cursor position */
    const char *p = buf;
    for (size_t i = 0; i < len; i++) {
        hal_reg_write8(s, V_TEXT_BUFFER + s->priv.cursor, p[i]);
        s->priv.cursor++;
    }
    return len;
}

static int video_probe(slot_t *s) {
    return hal_reg_read16(s, 0x0000) == 0x0001;  /* card type ID */
}

const struct card_driver video_ref_v1_driver = {
    .card_type_id = 0x0001,
    .name = "video-ref-v1",
    .probe = video_probe,
    .open = video_open,
    .write = video_write,
    /* ... */
};
```

Compiles with `cc65 -O -c video_ref_v1.c` for the 6502, with `m68k-elf-gcc` for the 68k, with the appropriate command line for x86 / RISC-V. Produces an object that the kernel can link in.

## Drivers in the v1 library

Initial set tracks the v1 hardware:

| Driver | Card | Status |
|---|---|---|
| `video-ref-v1` | [Video card](/learn-fpga/projects/video-card/) | Spec only |
| `audio-ref-v1` | [Audio card](/learn-fpga/projects/audio-card/) | Spec only |
| `sd-fat32` | [I/O card](/learn-fpga/projects/io-card/) SD subsystem | Reference exists in RetroKernel |
| `uart-ref-v1` | [I/O card](/learn-fpga/projects/io-card/) UART | Reference exists |
| `ps2kbd-ref-v1` | [I/O card](/learn-fpga/projects/io-card/) PS/2 | Reference exists |
| `ic-6502` | 6502 main board's interrupt controller | Spec only |
| `ic-68k-ipl` | 68k main board's IPL encoder | Spec only |

Future cards (network, USB, RTC, GPIO) add their own drivers.

## Vendor drivers

The library accepts third-party drivers under the same API. A community card doesn't *have* to upstream into the main library; vendor drivers can ship as separate object files that the kernel loads at boot. The contract is the API, not the source tree.

## On the wire / on the disk

The convention for distributing a built driver:

- ELF object file (`.o`)
- Compiled for the appropriate ABI (`.6502.o`, `.m68k.o`, `.i386.o`, `.riscv32.o`)
- Lives at `/lib/drivers/<name>.<arch>.o` on the SD card
- The bootloader / kernel scans `/lib/drivers/` at boot, loads drivers matching the host's arch + the cards present in the slot map

## Open design questions

- **Static vs dynamic linking.** Static (drivers compiled into the kernel image) is simpler and smaller; dynamic (drivers loaded at boot) is more flexible. Probably static for v1, dynamic later.
- **Versioning.** When the API evolves, how do drivers declare which version they support?
- **Concurrent access.** Two threads opening the same card at once — the driver author's responsibility to handle? The kernel's? Convention?
- **Shared cards.** Same card serving multiple processes (e.g. two terminals on one video card). Driver author's responsibility, exposed via `control()`?

## Dependencies

- The **bus standard** (done, register-window addressing settled)
- The **microkernel** (driver registration is a kernel concern)
- At least one card to drive
- A **GCC backend** for each supported CPU

## Next steps

1. Settle the API — write the header, get review.
2. Write the HAL for one CPU (probably 68000 first; least painful).
3. Write `uart-ref-v1` as the first complete driver.
4. Validate with the kernel + bootloader.
5. Open the library to community drivers.

Contributions wanted: driver authors for any card you'd like to see exist, API reviewers, anyone with experience designing a stable C driver ABI.
