# Implementation Plan: Minimal RISC-V SoC for llama2.c

**Branch**: `003-llama2-minimal-soc` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-llama2-minimal-soc/spec.md`

## Summary

Strip the existing full-featured SoC to a minimal profile — processor, external RAM, serial
console, SD card — then bring up a small language model on it end to end and measure where
per-token time actually goes.

The approach is additive rather than destructive. A new board define selects a new
configuration file, board makefile, and pin file; the existing profile is untouched and stays
buildable from the same checkout. The model is loaded from an SD card because it is ~1 MB and
effectively immutable, while the program continues to arrive over serial because it is small
and rebuilt constantly. Almost every piece needed already exists in the repository: the SDRAM
controller, cache, BIOS monitor with XMODEM upload, SD driver, FAT library, hardware floating
point, and a wraparound-safe cycle counter.

The real deliverable is not the demonstration — it is the timing breakdown from User Story 5,
which decides what a future matrix-multiply accelerator should target.

## Technical Context

**Language/Version**: C (RISC-V bare metal, rv32imafc / ilp32f); Verilog-2001 for RTL;
Python 3 for host tooling and simulation
**Primary Dependencies**: Yosys + nextpnr-ecp5 + ecppack (synthesis); riscv64-unknown-elf-gcc
8.3.0 (in-tree at `FIRMWARE/TOOLCHAIN`); newlib libm for `expf`/`logf`/`powf`/`sqrtf`;
existing in-tree FAT library and SD driver; cocotb + Icarus for RTL simulation
**Storage**: FAT-formatted SD card for model and vocabulary artifacts; 8 MB external SDRAM
for runtime; 32 KB on-chip ROM for the monitor
**Testing**: cocotb testbenches for RTL (host-runnable); hardware-in-the-loop for all
functional acceptance — see the spec's Testing Support section
**Target Platform**: Colorlight i5, ECP5 LFE5U-25F, 25 MHz, FemtoRV petitbateau (RV32IMFC)
**Project Type**: Embedded FPGA SoC plus bare-metal firmware, inside an existing repository
**Performance Goals**: model loads from card in <60 s (SC-005); rebuild-to-running loop
<60 s (SC-005a); generation ≥0.5 tokens/s (SC-008); timing categories cover ≥90% (SC-010)
**Constraints**: 8 MB external RAM total; ≥40% of logic and memory blocks must remain free
(SC-004); the existing full profile must not regress (SC-011); 115200 8N1 is the only I/O
**Scale/Scope**: one new build profile, one new firmware program, ~1 MB model, 5 user stories

No unresolved NEEDS CLARIFICATION items. The one open *quantity* is SD throughput, which is
an estimate rather than an unknown decision — it is tracked as R6/**MEASURE** in research.md
and is the first hardware measurement to take.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**No constitution file exists.** `.specify/memory/constitution.md` is absent — the
`.specify/memory/` directory has never been created in this repository.

**Result**: no gates are defined, so there are none to violate and nothing blocks progress.
This is recorded as an explicit finding rather than a silent pass.

**Recommendation**: this project has real, repeatedly-encountered principles that would make
good gates — additive build profiles over destructive edits, no unverified performance claims
in documentation, hardware-in-the-loop results recorded as measurements rather than
estimates, and cocotb coverage for new RTL. Running `/speckit.constitution` would make those
enforceable on future features. Not required for this one.

**Post-Phase-1 re-check**: unchanged; still no gates. The design introduces no complexity
requiring justification — see Complexity Tracking below.

## Project Structure

### Documentation (this feature)

```text
specs/003-llama2-minimal-soc/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output — 11 findings, R1-R11
├── data-model.md        # Phase 1 output — 8 entities
├── quickstart.md        # Phase 1 output — operator runbook
├── contracts/           # Phase 1 output
│   ├── build-targets.md
│   └── console-interface.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 — created by /speckit.tasks, not by this command
```

### Source Code (repository root)

```text
FemtoRV/
├── RTL/
│   ├── CONFIGS/
│   │   ├── colorlight_i5_config.v          # UNCHANGED — full profile
│   │   └── colorlight_i5_llm_config.v      # NEW — minimal profile
│   ├── femtosoc_config.v                   # EDIT — 3 lines, add dispatch branch
│   └── femtosoc.v                          # UNCHANGED
├── BOARDS/
│   ├── colorlight_i5.lpf                   # UNCHANGED
│   ├── colorlight_i5.mk                    # UNCHANGED
│   ├── colorlight_i5_llm.lpf               # NEW — trimmed pin file
│   └── colorlight_i5_llm.mk                # NEW — synth targets
├── Makefile                                # EDIT — 1 line, include new board mk
└── FIRMWARE/
    ├── monitor/                            # UNCHANGED — console, XMODEM, jump
    ├── llama2/                             # NEW
    │   ├── Makefile
    │   ├── llama2.c                        # port: no mmap, no host file I/O
    │   ├── model_load.c                    # card → SDRAM, with validation
    │   ├── profile.c                       # per-category cycle accounting
    │   ├── llama2.ld                       # links at 0x800000
    │   └── tools/fetch_model.sh            # host-side artifact preparation
    └── examples/
        ├── sdram_test.c                    # ADAPT — strip GPU output
        └── sd_dir.c                        # REFERENCE — FAT usage pattern
```

**Structure Decision**: Work lands in the existing `FemtoRV/` tree following its established
conventions — RTL configs in `RTL/CONFIGS/`, board files in `BOARDS/`, firmware programs as
directories under `FIRMWARE/` alongside `monitor/` and `examples/`. No new top-level
directories. Only two existing files are edited, both by addition: one dispatch branch in
`femtosoc_config.v` and one `include` in the `Makefile`. Everything else is new files, which
is what keeps SC-011's no-regression guarantee cheap to honour.

`RTL/ACCEL/` is deliberately **not** created. The accelerator is out of scope; this feature
produces the platform and the measurement that will justify its design.

## Complexity Tracking

No constitution gates exist, and the design introduces no complexity requiring justification.

Two decisions worth recording because they *look* like violations of the feature's own stated
goal of minimalism:

| Decision | Why | Simpler alternative rejected because |
|---|---|---|
| Keep the SD card in a "minimal" profile | FR-010 needs ~1 MB loaded without a 2-minute serial transfer on every reset | Serial-only was the original design; it put the slow path inside the development loop. The card costs almost no capacity — the protocol is bit-banged over four GPIO pins (`femtosoc.v:791`) — so it does not compete with SC-004 |
| Define `COLORLIGHT_I5` alongside the new profile define | `femtopll.v:37` selects the board PLL by that define; without it `femtoPLL` is undefined and synthesis fails | A new PLL branch in `femtopll.v` would work but edits a shared file for no benefit. Reusing the board define keeps all board plumbing — PLL, LED polarity, FPGA family — resolving unchanged |

## Phase Status

- [x] **Phase 0 — Research**: `research.md`, findings R1-R11. No unresolved clarifications.
- [x] **Phase 1 — Design & Contracts**: `data-model.md` (8 entities), `contracts/` (2),
      `quickstart.md`, agent context updated.
- [ ] **Phase 2 — Tasks**: run `/speckit.tasks`.

## Notes for Phase 2

Three things should shape the task breakdown:

1. **Measure SD throughput early.** SC-005's 60-second target rests on an estimate of
   30-80 KB/s, not a measurement (research R6). If it lands far below, the loading strategy
   needs rethinking, and that is far cheaper to discover before the inference program is
   written than after. This belongs in the first hardware session.

2. **Batch the hardware checkpoints.** The spec requires it, and a natural grouping is:
   (1) builds + boots + resource report + memory test + SD throughput; (2) model loads and
   verifies + program uploads and runs; (3) generation + timing breakdown. Each
   operator-assisted task must state exact commands, expected output, and what to record.

3. **Two adapted files are easy to under-scope.** `sdram_test.c` and `sd_dir.c` both write
   output through `GPU_WRITE`, which does not exist in this profile. They need their output
   paths reduced to serial before they compile. Small, mechanical, but not free.
