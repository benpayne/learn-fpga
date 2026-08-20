# Implementation Plan: int8 MatMul Accelerator

**Branch**: `004-int8-matmul-accel` | **Date**: 2026-08-20 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-int8-matmul-accel/spec.md`

## Summary

Add a hardware matrix-multiply unit to the minimal SoC from feature 003, using 8-bit integer
weights, and route both the weight multiplies (61.3% of per-token time) and attention (27.4%)
to it.

The approach is dictated by a measurement rather than a preference: at batch 1 every weight is
read exactly once, so the accelerator is memory-bound and lane count must track bandwidth, not
ambition. One 32-bit port at 25 MHz delivers four int8 weights per cycle, which is four MAC
lanes and no more. The engineering effort is in the streaming orchestrator and the memory
arbitration, not in a multiplier array.

Roughly half the memory-side work already exists: feature 003 established that the SDRAM
controller's burst port is generic and hardware-proven, and that the video fetch engine it
served is present but inert in this profile. The genuinely new RTL is the MAC datapath, the
control FSM, and the CPU-facing registers.

The work is sequenced so the largest risk is retired first and for free: **User Story 1 builds
no hardware at all.** It quantizes the model, runs it on the existing board, and answers whether
8-bit ruins quality on a model this small — with a documented fallback to 16-bit if it does.

## Technical Context

**Language/Version**: Verilog-2001 for RTL; C (RISC-V bare metal, rv32imafc / ilp32f) for
firmware; C on the host for the reference implementation; Python 3 for testbenches and tooling
**Primary Dependencies**: Yosys + nextpnr-ecp5 + ecppack; in-tree riscv64-unknown-elf-gcc 8.3.0;
cocotb + Icarus Verilog; upstream `runq.c` as the Q8_0 reference and `export.py` for quantization
**Storage**: FAT SD card for the quantized model; 8 MB external SDRAM at runtime; on-chip BRAM
for activations, scales and results
**Testing**: cocotb testbenches for all arithmetic and arbitration (host-runnable); bit-exact
comparison against the host reference; hardware-in-the-loop for every generation measurement
**Target Platform**: Colorlight i5, ECP5 LFE5U-25F, 25 MHz, FemtoRV petitbateau, minimal profile
from feature 003
**Project Type**: FPGA accelerator plus bare-metal firmware, inside an existing repository
**Performance Goals**: >= 8 tok/s (SC-011) against 1.38 measured; >= 90% of the memory roofline
with no contention (SC-006); accelerated categories under 15% of per-token time (SC-012)
**Constraints**: >= 25% logic free after the accelerator (SC-013); the full-featured profile must
still build (SC-014); bit-exact agreement with the host reference at every stage
**Scale/Scope**: one accelerator block, ~4 MAC lanes, three operating modes, one arbitration
change to shared RTL

No unresolved NEEDS CLARIFICATION items. Two quantities are estimates that the plan converts to
measurements: the quality impact of quantization (User Story 1) and the burst-length trade-off
(User Story 3).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**No constitution file exists.** `.specify/memory/constitution.md` is still absent, as it was in
feature 003.

**Result**: no gates are defined, so there are none to violate. Recorded explicitly rather than
passed silently.

**Recommendation, now stronger than in feature 003**: this project has demonstrated principles
worth enforcing — additive build profiles over destructive edits, no unverified performance
claims in documentation, measurements recorded in place of estimates, cocotb coverage for new
RTL, and bit-exact references before hardware. Feature 003 followed all of these and it visibly
paid off. This feature changes *shared* RTL for the first time, which makes a written
no-regression rule more valuable than before. `/speckit.constitution` would make them binding.

**Post-Phase-1 re-check**: unchanged. One item is recorded in Complexity Tracking below.

## Project Structure

### Documentation (this feature)

```text
specs/004-int8-matmul-accel/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 — 13 findings, R1-R13
├── data-model.md        # Phase 1 — 8 entities
├── quickstart.md        # Phase 1 — staged runbook
├── contracts/           # Phase 1
│   ├── accelerator-interface.md
│   └── build-and-verify.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 — created by /speckit.tasks
```

### Source Code (repository root)

```text
FemtoRV/
├── RTL/
│   ├── ACCEL/                                  # exists: DESIGN.md
│   │   ├── DESIGN.md                           # architecture rationale (already written)
│   │   ├── acc_mac.v                           # NEW — int8 MAC lanes + int32 accumulate
│   │   ├── acc_weight_fetch.v                  # NEW — modelled on video_fetch_engine.v
│   │   ├── acc_regs.v                          # NEW — CSRs + descriptor queue
│   │   └── acc_top.v                           # NEW — assembles the above
│   ├── SDRAM/
│   │   └── muchtoremember_burst.v              # EDIT — arbitration priority, parameterised
│   ├── DEVICES/HardwareConfig_bits.v           # EDIT — accelerator IO bits (reuse 10, 11)
│   ├── CONFIGS/colorlight_i5_llm_config.v      # EDIT — enable the accelerator
│   └── femtosoc.v                              # EDIT — instantiate; replaces video_fetch_engine
├── FIRMWARE/
│   ├── llama2/
│   │   ├── runq.c                              # NEW — quantized inference (port of upstream)
│   │   ├── quantize.c                          # NEW — activation quantization
│   │   ├── acc_driver.c / acc_driver.h         # NEW — descriptor issue, status, counters
│   │   └── tools/
│   │       ├── quantize_model.sh               # NEW — host model conversion
│   │       └── runq_host.c                     # NEW — golden reference
│   └── examples/acc_test.c                     # NEW — standalone hardware test
└── TEST/
    ├── acc_mac_tb.py                           # NEW — stage 0
    ├── acc_unit_tb.py                          # NEW — stage 1
    ├── acc_arb_tb.py                           # NEW — stage 2
    └── Makefile                                # EDIT — entries for the three above
```

**Structure Decision**: work lands in the existing tree following its conventions. `RTL/ACCEL/`
already exists (it holds `DESIGN.md`) and gains the RTL. Firmware extends `FIRMWARE/llama2/`
rather than forking it, so the fp32 and quantized paths share the loader and profiler.

**This feature edits shared RTL, which feature 003 deliberately avoided.**
`muchtoremember_burst.v` is used by both profiles, so its arbitration change must be
parameterised rather than simply reordered — see Complexity Tracking.

## Complexity Tracking

No constitution gates exist. One decision needs recording because it breaks the pattern feature
003 established.

| Decision | Why | Simpler alternative rejected because |
|---|---|---|
| Edit shared `muchtoremember_burst.v` rather than adding a profile-specific copy | The arbitration priority must change for the accelerator (CPU first) but must stay as-is for the display profile (burst first). Both profiles use this controller | A forked controller would duplicate ~600 lines of hardware-proven, timing-critical RTL, and any future fix would have to be applied twice. Parameterising the priority is a few lines and keeps one implementation. The cost is that SC-014's regression check becomes mandatory rather than a formality |
| Reuse IO bits 10 and 11 (GPU and synth slots) | The IO address space is full — 20 one-hot bits, all allocated (research R7) | Extending the IO address space touches the CPU address decode and the memory map for every profile. Reuse follows the precedent already set by `IO_GPU_bit`, which shares `IO_FGA_CNTL_bit` |

## Phase Status

- [x] **Phase 0 — Research**: `research.md`, findings R1-R13. Two corrected the design's
      assumptions (Q8_0 layout, activation quantization); two are hard constraints found by
      reading the source (IO space full, header format).
- [x] **Phase 1 — Design & Contracts**: `data-model.md` (8 entities), `contracts/` (2),
      `quickstart.md`, agent context updated.
- [ ] **Phase 2 — Tasks**: run `/speckit.tasks`.

## Notes for Phase 2

Four things should shape the task breakdown:

1. **User Story 1 must complete, and its decision be recorded, before any RTL is written.**
   It is the fallback decision point (FR-004a) and the source of the golden reference. Starting
   RTL in parallel would mean building integer arithmetic that a no-go answer discards.

2. **Two design assumptions were corrected in Phase 0 and the tasks must reflect the
   corrections, not the design document.** Q8_0 stores weights and scales as separate blocks,
   not interleaved (R1) — so the fetch engine prefetches scales into BRAM and then streams dense
   int8 at the full lane rate. And the activation vector is quantized too (R2), which adds CPU
   work and means the MAC is int8 x int8 with a product-of-two-scales rescale.

3. **The arbitration change needs its own verification task, separate from the accelerator.**
   It touches RTL the working profile depends on. Simulate it, then run the full-profile
   regression, before it is bundled with anything else.

4. **Batch the hardware sessions**, as feature 003 did: (1) the CPU-only quantized run, which
   is the go/no-go on quantization; (2) the standalone accelerator test plus the build
   regression; (3) integrated generation and profiling, twice — once with weight multiplies
   accelerated and once with attention added.
