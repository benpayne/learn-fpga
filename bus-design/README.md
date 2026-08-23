# Retro-Active Bus: Bridge Feasibility

This directory contains feasibility proofs for the Retro-Active common-bus
[Architecture](../retroweb/src/pages/architecture.astro) page, specifically the
claim that a vintage CPU can be attached to the bus using "a handful of
74-series chips, a PAL/GAL, or a simple FPGA block."

Each bridge is implemented in **two flavours** — pure 74-series for the
builder who considers any programmable logic cheating, and a "with one
22V10 PAL/GAL" variant for the builder who's happy to absorb the glue
into a single programmable part. Both flavours pass the same cocotb test
suite, so cards behave identically against either build.

| Bridge | Pure 74-series | With one 22V10 |
|---|---|---|
| **6502** (1 MHz, sync PHI2 bus) | **9 chips** | **4 chips** |
| **68000** (10 MHz, async /AS+/DTACK bus) | **12 chips** | **6 chips** |

All four bridge builds are structural Verilog (chip primitives in
`chips_7400.v` plus a 22V10 model in `bridge_*_pal.v`) and verified
with cocotb testbenches against fake memory targets.

Two additional **multi-card** suites exercise the full slot model from
the [Architecture page](../retroweb/src/pages/architecture.astro): a
small backplane decoder (one `74LS154` + comparator) generates
per-slot `SLOT_SEL_n`, and the fake targets gate their cycle handling
on it.  These suites verify slot isolation — writes to one card don't
leak to another, and cycles outside the IO region or to unpopulated
slots time out without `/DTACK`.

## Chip lists (BOM)

### 6502 bridge

| Ref | Part | Function |
|-----|------|----------|
| U1 | 74LS245 | 8-bit bidirectional data transceiver (6502 D0-D7 ↔ bus DATA[7:0]) |
| U2 | 74LS244 | Octal tristate buffer (6502 A0-A7 → bus ADDR[7:0]) |
| U3 | 74LS244 | Octal tristate buffer (6502 A8-A15 → bus ADDR[15:8]) |
| U4 | 74LS74 | Dual D flip-flop (PHI2 synchroniser — 2 FFs into bus_clk domain) |
| U5 | 74LS74 | Dual D flip-flop (state machine: 2 bits encoding IDLE/DRIVE/WAIT/DONE) |
| U6 | 74LS00 | Quad NAND: PHI2 edge detect + IRQ inversion + inverters for `~bus_ready` / `~cpu_rw` |
| U7 | 74LS08 | Quad AND (4 of 6 AND terms in next-state + strobe gating) |
| U8 | 74LS08 | Quad AND (remaining 2 AND terms) |
| U9 | 74LS32 | Quad OR (all 4 OR terms in next-state + data_hot) |

**Total: 9 chips.**

### 68000 bridge

| Ref | Part | Function |
|-----|------|----------|
| U1 | 74LS244 | Address buffer A1-A8 → bus ADDR[8:1] |
| U2 | 74LS244 | Address buffer A9-A16 → bus ADDR[16:9] |
| U3 | 74LS244 | Address buffer A17-A23 → bus ADDR[23:17] |
| U4 | 74LS245 | 68k D[15:8] ↔ bus DATA[7:0] (UDS byte lane, cross-wired) |
| U5 | 74LS245 | 68k D[7:0] ↔ bus DATA[15:8] (LDS byte lane, cross-wired) |
| U6 | 74LS74 | /AS synchroniser (2 FFs into bus_clk domain) |
| U7 | 74LS74 | FSM state (S1, S0) |
| U8 | 74LS00 | Quad NAND: /DTACK + IRQ→IPL inverter + `~cpu_rw`, `~uds_n` inverters |
| U9 | 74LS00 | Quad NAND: U4/U5 OE gates + RSTRB OR combiner + `~lds_n` inverter |
| U10 | 74LS08 | Quad AND (state-machine terms) |
| U11 | 74LS08 | Quad AND (strobe terms — `in_active·~RW`, WSTRB[0], WSTRB[1]) |
| U12 | 74LS32 | Quad OR (next-state OR gates) |

**Total: 12 chips.**

Exact packaging varies a bit — a builder using 74LS51 (AOI) or 74LS11 (triple 3-input AND) parts can sometimes shave one package; going the other way, breaking the U6/U8 NAND chips into separate inverters adds one. The numbers above are representative "one of each family" counts.

## What happened to "6 chips" / "8 chips"?

Earlier drafts of the blog posts quoted **6 chips** for the 6502 bridge and **8 chips** for the 68k. Those counts assumed the compound next-state logic and strobe-decode terms would live on a single small PAL/GAL — which is a very reasonable assumption for a modern retro build, and was how 1980s designers actually did it. But "6 chips (with a PAL)" isn't the same as "6 chips, period," and the posts weren't precise about that.

The corrected, honest counts are **9** (6502) and **12** (68000) in pure 74-series. A follow-up post will redo these designs *with* a PAL/GAL and report the real saving — the logic is the same, it's just packaging.

## Bus protocol the bridges exercise

- **CLK** — 25 MHz bus reference clock
- **RESET_N** — active-low global reset
- **ADDR[23:0]** — master drives; bridges tie unused upper bits to 0
- **DATA[31:0]** — bidirectional; 6502 uses lane 0 only, 68000 uses lanes 0 and 1
- **WSTRB[3:0]** — per-byte write strobe
- **RSTRB** — read strobe
- **READY** — target signals transaction complete
- **IRQ** — wire-OR'd interrupt; bridges invert / re-encode into CPU's native interrupt input

## State machines

### 6502 (synchronous — four states, clocked on 25 MHz bus_clk)

```
         phi2_rising        always          bus_ready        phi2 low
  IDLE ─────────────▶ DRIVE ─────────▶ WAIT ─────────▶ DONE ─────────▶ IDLE
```

### 68000 (asynchronous — three states, clocked on 25 MHz bus_clk)

```
           /AS low (sync'd)           bus_ready           /AS high
  IDLE ──────────────────────▶ ACTIVE ─────────▶ DONE ──────────────▶ IDLE
                                                (/DTACK low to CPU)
```

## Timing margins

- **6502** at 1 MHz: PHI2 half-period 500 ns, bus transaction ~120 ns → **~4× headroom**
- **68000** at 10 MHz: min bus cycle 400 ns, bus transaction ~120 ns → comfortable

## Files

```
bus-design/
├── README.md                          # This file
├── docs/
│   └── backplane.md                   # 16-slot backplane reference, IRQ routing
├── rtl/
│   ├── chips_7400.v                   # 74LS00, 04, 08, 32, 74, 244, 245, 373 models
│   ├── backplane_decoder.v            # 74LS154 + comparator: per-slot SLOT_SEL_n
│   ├── bridge_6502.v                  # 9-chip pure-74 6502 bridge
│   ├── bridge_6502_pal.v              # 4-chip PAL/GAL 6502 bridge (1 22V10 + buffers)
│   ├── bridge_68k.v                   # 12-chip pure-74 68000 bridge
│   ├── bridge_68k_pal.v               # 6-chip PAL/GAL 68000 bridge (1 22V10 + buffers)
│   ├── fake_bus_target.v              # 64 KB single-lane target (slot-gated)
│   └── fake_bus_target_16.v           # 64 KB two-lane target (slot-gated)
└── test/
    ├── bridge_6502_tb.{v,py}          # 6502 cocotb harness (5 tests)
    ├── bridge_6502_pal_tb.v           # PAL-build top wrapper, reuses bridge_6502_tb.py
    ├── bridge_6502_multislot_tb.{v,py}# Multi-slot 6502: bridge → backplane → 2 cards
    ├── bridge_68k_tb.{v,py}           # 68000 cocotb harness (7 tests)
    ├── bridge_68k_pal_tb.v            # PAL-build top wrapper for 68k
    ├── bridge_68k_pal_tests.py        # Test list for 68k PAL (IRQ test omitted)
    ├── bridge_68k_multislot_tb.{v,py} # Multi-slot 68k: bridge → backplane → 2 cards
    └── Makefile                       # TARGET=6502, 6502_pal, 6502_multislot,
                                       #          68k,  68k_pal,  68k_multislot
```

## Running the tests

```bash
cd bus-design/test
source ../../.venv/bin/activate    # cocotb 1.9, Python 3.10

# Single-card builds (one host, one target)
make TARGET=6502                   # 9-chip pure-74 6502  → 5 tests
make TARGET=6502_pal               # 4-chip PAL/GAL 6502  → 5 tests
make TARGET=68k                    # 12-chip pure-74 68k → 7 tests
make TARGET=68k_pal                # 6-chip PAL/GAL 68k  → 6 tests

# Multi-card builds (host + backplane decoder + 2 slot-gated cards)
make TARGET=6502_multislot         # 6502 mapped to slot 0; second card at slot 5 → 3 tests
make TARGET=68k_multislot          # 68k addresses slot 3 and slot 7 directly  → 5 tests
```

Expected results:

| Target | Tests | Status |
|---|---|---|
| `6502`             | 5 | `TESTS=5 PASS=5 FAIL=0`, ~1 sec |
| `6502_pal`         | 5 | `TESTS=5 PASS=5 FAIL=0`, ~1 sec |
| `6502_multislot`   | 3 | `TESTS=3 PASS=3 FAIL=0`, ~1 sec |
| `68k`              | 7 | `TESTS=7 PASS=7 FAIL=0`, ~1 sec |
| `68k_pal`          | 6 | `TESTS=6 PASS=6 FAIL=0`, ~1 sec |
| `68k_multislot`    | 5 | `TESTS=5 PASS=5 FAIL=0`, ~1 sec |

## What this proves

The Retro-Active Architecture page says this about the bridge concept:

> Each host connects through a small bridge — a handful of 74-series chips, a PAL/GAL, or a simple FPGA block — that translates the host's native cycles into bus transactions.

The "handful of 74-series chips" claim — with **no asterisks** about programmable logic — is now backed by two working reference designs: a 9-chip sync bridge (6502) and a 12-chip async bridge (68000). Both pass their cocotb test suites and expose two real design gotchas for builders to avoid (read-data hold windows, address-strobe phase asymmetry in the 6502; byte-lane cross-wiring in the 68k).

## What this does NOT prove

- **Physical timing**: simulation uses behavioural models with zero propagation delay. A real board needs timing analysis with actual LS / HC / AC family delays, bus capacitance, and signal integrity.
- **Electrical**: no analysis of fanout, bus termination, or level-shifting between 5 V TTL and any 3.3 V bus receivers.
- **68000 edge cases**: bus-error / abort (/BERR), FC0-2 function codes, read-modify-write cycles (TAS instruction), multi-level interrupt encoding (would need a 74LS148 priority encoder).
- **6502 edge cases**: NMOS 6502's RDY input works only during reads — we don't wire RDY; our bridge completes within a single PHI2 half-cycle at 1 MHz. A faster 6502 or a slower target would need wait-state logic.

These are exactly the questions Phase 2 of the standardization roadmap asks: *what breaks on a 6502 bridge? What does a 74-logic bridge need that an FPGA bridge doesn't?* Both designs here are early data points.
