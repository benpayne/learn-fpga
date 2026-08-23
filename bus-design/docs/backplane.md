# Retro-Active Backplane Reference

This document specifies the physical backplane for the Retro-Active bus: how slots are numbered, how the backplane decodes slot selection, how interrupts are wired back to the host, and what each connector pin carries.

Status: **DRAFT** — aligned with the [Architecture page](../../retroweb/src/pages/architecture.astro) and the pure-74 [6502](../../retroweb/src/content/blog/nine-chips-6502-bridge.md) and [68k](../../retroweb/src/content/blog/twelve-chips-68k-bridge.md) bridge posts. Expect pin assignments to settle as the spec moves toward v1.0.

## Slot model

The bus supports **up to 16 slots**, numbered 0 through 15. Each slot gets a 64 KB register window in the host's address space.

Slot numbers are encoded into the bus address:

| Address bits | Purpose |
|---|---|
| `ADDR[23:20]` | IO-region tag — must be `0x4` for a card cycle |
| `ADDR[19:16]` | Slot number (0 – 15) |
| `ADDR[15:0]` | Per-slot register space (64 KB per card) |

Slot 0 lives at `0x400000 – 0x40FFFF`, slot 1 at `0x410000 – 0x41FFFF`, and so on through slot 15 at `0x4F0000 – 0x4FFFFF`.

## Slot selection

The backplane decodes `ADDR[19:16]` into 16 active-low chip-selects using a single **74LS154** (4-to-16 line decoder with active-low outputs). The decoder's enable inputs gate the decode so a slot only sees its `SLOT_SEL_n` go low when an actual card cycle is in progress:

```text
   ADDR[19:16]  ──►  A,B,C,D          74LS154       ──►  /Y0 ──► slot 0 SLOT_SEL_n
                                                         /Y1 ──► slot 1 SLOT_SEL_n
                                                         ...
   ADDR[23:20] == 4 ──►  G1 (enable low)              /Y15 ──► slot 15 SLOT_SEL_n
   WSTRB[0..3] OR RSTRB ──►  G2 (enable low)
```

- `A B C D` inputs take the 4-bit slot number
- Enables `/G1` and `/G2` must both be low for any output to assert
- Output goes low only for the selected slot; all other slots see `SLOT_SEL_n` high and ignore the cycle

Building up the enable:

- **IO-region match**: `(ADDR[23:20] == 0x4)` can be decoded with a single 74LS85 4-bit magnitude comparator, or with a handful of NAND/XOR gates, or — most commonly — with three AND gates and an inverter (one pack of 74LS08 + one 74LS04).
- **Cycle active**: `WSTRB[3:0] | RSTRB` is four NOR terms collapsed into one OR output; a 74LS32 quad OR does it in one chip, or you can OR-reduce with spare gates elsewhere.

### Backplane chip count

For slot selection alone:

| Part | Quantity | Purpose |
|---|---|---|
| 74LS154 | 1 | 4-to-16 slot decoder |
| 74LS85 or 74LS86/32 | 1 | `ADDR[23:20] == 0x4` comparator |
| 74LS32 | 1 (shared) | `WSTRB \| RSTRB` OR-reduce (uses ~1 gate; share with other needs) |

**~2–3 chips for slot selection on the backplane**, independent of how many slots are actually populated. That's a negligible cost amortised across every card in the system.

## Interrupt routing

Each slot connector carries a dedicated active-low `IRQ_n` pin. Slot 0's `IRQ_n` is wired back to one pin on the host-side interrupt controller, slot 1's to another, and so on through slot 15. **Slots do not share IRQ lines.**

The host-side interrupt controller aggregates the 16 lines into whatever the CPU wants:

### 6502-family hosts (and other single-IRQ CPUs)

The interrupt controller ORs all 16 `IRQ_n` lines onto the CPU's `/IRQB` input, and exposes a status register telling the CPU which slots are currently asserting. A typical register layout:

| Address | Bits | Purpose |
|---|---|---|
| Base + 0 | `[15:0]` | Pending mask — one bit per slot; set when slot N's IRQ is low |
| Base + 2 | `[15:0]` | Enable mask — set bit N to allow slot N's IRQ to reach the CPU |
| Base + 4 | `[15:0]` | Edge/level mode per slot (optional) |

Clear pending bits by writing a 1 to the corresponding bit of the pending register — a pattern borrowed directly from the FemtoRV reference implementation.

Minimum viable 6502-side interrupt controller in pure 74-series: one 74LS279 (quad SR latch, 4 gates) per group of 4 slots + one 74LS32 for the OR-to-CPU + one 74LS244 for the status-register read. Roughly **5–6 chips** for a 16-slot controller. A PAL/GAL collapses this further.

### 68000-family hosts (priority-encoded)

The interrupt controller feeds the 16 `IRQ_n` lines into **two cascaded 74LS148** 8-to-3 priority encoders (or one 74LS148 if only 8 slots are needed). The 148's encoded output drives `/IPL[2:0]` directly:

```text
   IRQ_n[0..7]   ──►  74LS148 #1  ──► /IPL[2:0] low half
   IRQ_n[8..15]  ──►  74LS148 #2  ──► /IPL[2:0] high half
   (cascade /EO of #2 into /EI of #1)
```

Priority is "highest slot number wins." Map slot-to-interrupt-level according to how important each card's work is — a display controller or SD card interface on a high slot, housekeeping on low slots.

Minimum viable 68k-side interrupt controller: 2× 74LS148 priority encoders + 1× 74LS32 for /INT aggregation if auto-vectoring. **3 chips** for 16-level priority encoding, no status register needed because the 68k's IPL bits tell the CPU which slot fired.

## Connector pinout

Working assumption: **DIN 41612 Type C, 96-pin** connector (three rows of 32 pins each). That fits the signal count with comfortable headroom for power and ground, and it's a readily-available part used by VMEbus, STEbus, and Eurocard systems of the 1980s — right era, right price.

Preliminary pin assignment (subject to change in v1.0):

| Row | Pins | Signals |
|---|---|---|
| A | 1–24 | `ADDR[23:0]` |
| A | 25–28 | `WSTRB[3:0]` |
| A | 29 | `RSTRB` |
| A | 30 | `READY` |
| A | 31 | `CLK` |
| A | 32 | `RESET_N` |
| B | 1–32 | `DATA[31:0]` |
| C | 1 | `SLOT_SEL_n` (this slot) |
| C | 2 | `IRQ_n` (this slot) |
| C | 3–16 | Reserved (future expansion: /BERR, /INT_ACK, arbitration, clock doubler, …) |
| C | 17–24 | GND (8 pins) |
| C | 25–32 | +5V (8 pins) |

**Budget:**

- 74 active signals (32 shared + 2 per-slot)
- 8 GND + 8 +5V = 16 power pins
- 14 reserved pins for v1.x evolution
- Total: 96 pins used / 96 available

If we later want a 5 V + 3.3 V dual-supply option, we can split four of the +5V pins to 3.3V. Ground count stays ample.

## Example: 4-slot devkit backplane

Phase 4 of the [standardization roadmap](../../retroweb/src/pages/architecture.astro) calls for a minimal reference backplane. A 4-slot build (slots 0–3) needs:

| Part | Quantity | Purpose |
|---|---|---|
| 74LS154 | 1 | Slot decoder (only outputs /Y0-/Y3 connected) |
| 74LS85 | 1 | `ADDR[23:20] == 0x4` check |
| 74LS32 | 1 | Strobe OR-reduce, assorted glue |
| DIN 41612 96-pin female | 4 | Slot connectors |
| PCB + passives + connectors | 1 set | Board |

**Total backplane: 3 ICs + 4 connectors.** No card to plug into the slots, no host board — just the passive interconnect. That's the "empty chassis" you build bridges and cards around.

The host interrupt controller is built separately — either on the host board (common for integrated builds) or on its own slot-0 card (common if you want the host to be a pure CPU module).

## What this document does NOT cover

- **Physical dimensions**: board size, slot pitch, keepout zones. A 4-slot devkit is presumably a Eurocard-sized PCB (160 × 100 mm) but the v1.0 spec hasn't fixed this.
- **Bus arbitration**: the current spec assumes a single host. Multi-master support (DMA, bus-mastering cards) would add `/BR`, `/BG`, `/BGACK` to the reserved pins.
- **Hot-swap and card presence detection**: nothing prevents it, but no signals are reserved for it yet.
- **Electrical specs**: termination resistors, drive strength, signal integrity at the 25 MHz clock. Targeting "standard 74LS/HCT drive" for now; a faster v1.1 spec might move to ABT or LVT.

These are all legitimate v1.1+ conversations. For now the goal is a working 4-slot backplane that two CPUs (6502 and 68k) can talk to through cards they don't have to write custom decode logic for.
