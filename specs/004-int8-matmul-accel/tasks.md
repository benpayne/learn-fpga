---
description: "Task list for 004-int8-matmul-accel"
---

# Tasks: int8 MatMul Accelerator

**Input**: Design documents from `/specs/004-int8-matmul-accel/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md
**Governing**: `.specify/memory/constitution.md` v1.0.0

**Tests are MANDATORY here, not optional.** This feature contains RTL, so constitution
Principles I-III apply: every module needs a cocotb testbench registered in `TEST/Makefile`,
and those testbenches MUST pass before any synthesis or hardware task runs.

**Organization**: grouped by user story. Hardware work is layered, so stories are
dependency-ordered — but each has its own pass/fail signal and the sequence deliberately puts
the cheapest risk-retirement first.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependencies)
- **[HW]**: requires the physical board and operator assistance
- **[Story]**: which user story this task belongs to

## Path Conventions

Repository root is `/opt/wip/learn-fpga`. All paths below are repo-relative.

---

## Operator-Assisted Sessions

Three batched hardware sessions, as feature 003 established. Each **[HW]** task states its
command, expected output, and what to record.

| Session | Tasks | Purpose | Est. |
|---|---|---|---|
| **A** | T022-T025 | Quantized model on the board — **confirms** the T014 verdict | ~30 min |
| **B** | T053-T055 | Standalone accelerator test, counters, error paths | ~30 min |
| **C** | T060-T062, T069-T071 | Integrated generation twice, plus profiling | ~60 min |

**Session A is no longer the gate.** T014 decides 8-bit versus 16-bit from host-side divergence
measurements, before any board is involved (FR-004c). Session A confirms that verdict on real
hardware. The ordering matters: a no-go answer costs minutes on the host rather than a
build-flash-upload cycle.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: scaffolding that later phases fill in. No behaviour yet.

- [X] T001 [P] Create `FemtoRV/RTL/ACCEL/` module skeletons — `acc_mac.v`, `acc_weight_fetch.v`, `acc_regs.v`, `acc_top.v` — each with a documented port list per constitution "Interfaces" (direction, width, meaning) and no logic yet
- [X] T002 [P] Add `acc_mac_tb`, `acc_unit_tb`, `acc_arb_tb` entries to `FemtoRV/TEST/Makefile`, following the existing `sdram_burst_tb` pattern (constitution Principle II requires registration)
- [X] T003 Allocate accelerator IO bits in `FemtoRV/RTL/DEVICES/HardwareConfig_bits.v`: `IO_ACC_IDX_bit = 10` and `IO_ACC_DAT_bit = 11`, with comments recording that they are mutually exclusive with `IO_FGA_CNTL_bit`/`IO_GPU_bit` and `IO_FGA_DAT_bit`/`IO_SYNTH_bit` because the 20-bit IO space is full (research R7)
- [X] T004 [P] Create `FemtoRV/FIRMWARE/llama2/tools/` scaffolding for the quantization script and host reference

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: shared definitions and the regression baseline that later comparisons need.

**⚠️ CRITICAL**: no user story work begins until this phase completes.

- [X] T005 Create `FemtoRV/FIRMWARE/llama2/q8_format.h` defining the Q8_0 checkpoint layout from research R1/R4 — magic `0x616b3432`, version 2, 256-byte header, Config, shared-classifier flag, group size, then per-tensor `q` block followed by `s` block — shared by host tools and firmware so they cannot disagree
- [X] T006 Record the full-profile regression baseline: run `cd FemtoRV && make colorlight_i5.synth`, and save LUT/BRAM/PLL/Fmax into `specs/004-int8-matmul-accel/research.md` under a new R14. Constitution Principle V makes this the reference every later shared-RTL change is checked against, so it must be captured **before** anything is modified

**Checkpoint**: skeletons exist, format is defined once, regression baseline recorded.

---

## Phase 3: User Story 1 — Reduced-precision model in software (Priority: P1) 🎯 MVP

**Goal**: quantize the model, run it with no new hardware, and decide whether 8-bit is viable.

**Independent Test**: generate text on the board from a quantized model and compare quality
against the fp32 output from feature 003.

**⚠️ NO RTL IN THIS PHASE.** Per plan.md's Phase 2 notes, this story and its decision must
complete before any hardware work begins — it is both the go/no-go and the source of the
golden reference.

- [X] T007 [P] [US1] Write `FemtoRV/FIRMWARE/llama2/tools/quantize_model.sh` producing a Q8_0 checkpoint from the fp32 model, reporting size, checksum, group size, and the size ratio versus fp32 (SC-003 is stated as a ratio)
- [X] T008 [P] [US1] Port upstream `runq.c` to `FemtoRV/FIRMWARE/llama2/tools/runq_host.c` as the host golden reference, with a flag to dump intermediate dot-product results for a chosen layer and matrix (needed by T030 and T037)
- [X] T009 [US1] Run T007 and record the actual quantized size, checksum and group size in `specs/004-int8-matmul-accel/research.md`; confirm the header matches `q8_format.h`
- [X] T010 [US1] Run `runq_host` with seed 2026 for 110 steps and save the output as the golden reference transcript in `specs/004-int8-matmul-accel/`
- [X] T011 [P] [US1] Build an fp32 host reference at `FemtoRV/FIRMWARE/llama2/tools/run_host.c` from feature 003's ported inference, with a flag to dump the per-position logit vector. Feature 003's host harness lived in a scratch directory and was discarded, so it must be recreated — and it is the baseline the quantized model gets measured against
- [X] T012 [US1] Extend `FemtoRV/FIRMWARE/llama2/tools/runq_host.c` (T008) with the same per-position logit dump, so both models can be compared position by position on identical inputs
- [X] T013 [US1] Write `FemtoRV/FIRMWARE/llama2/tools/kl_compare.py` computing, over at least 200 token positions with the same prompt and seed: mean and 99th-percentile KL divergence between the two models' softmax distributions, and the top-1 agreement rate. Record all three in `specs/004-int8-matmul-accel/research.md` (FR-004, FR-004c)
- [ ] T014 [US1] **EARLY DECISION GATE (FR-004a, FR-004b)** — read T013's figures against SC-002's thresholds (mean KL < 0.01 nats, top-1 agreement > 95%) and against the generated text, and record an explicit 8-bit go/no-go with its basis in `specs/004-int8-matmul-accel/research.md`. **This runs entirely on the host and blocks all RTL work.** If no-go, switch to 16-bit before writing any integer datapath — that change alters the basis of bit-exact verification, so taking it later is far more disruptive
- [ ] T015 [US1] Port the quantized inference into `FemtoRV/FIRMWARE/llama2/runq.c` — no mmap, no host file I/O, weights already resident, static allocation at the fixed addresses from data-model entity 2, reusing feature 003's serial output and profiler
- [ ] T016 [US1] Implement activation quantization in `FemtoRV/FIRMWARE/llama2/quantize.c`, matching upstream `quantize()` exactly so results compare bit-for-bit (research R2 — the activation vector is quantized too, which the design document had missed)
- [ ] T017 [US1] Extend `FemtoRV/FIRMWARE/llama2/model_load.c` to autodetect format by magic — `0x616b3432` means Q8_0 with a 256-byte header, absence means feature 003's legacy 28-byte layout — and reject a mismatch loudly (research R4; a wrong-format load is the silent-wrong-output failure this project keeps guarding against)
- [ ] T018 [US1] Update the memory map in `FemtoRV/FIRMWARE/llama2/model_load.h` for the quantized model's much smaller footprint (~0.3 MB versus 1.06 MB), keeping the 2 MB region and noting in the comment that region size, not memory, is what caps model capacity (research R5)
- [ ] T019 [US1] Add per-operation timing for activation quantization to `FemtoRV/FIRMWARE/llama2/profile.c` as a new category, so T025 can measure the scalar cost this feature adds
- [ ] T020 [US1] Build with `cd FemtoRV/FIRMWARE/llama2 && make llama2.bin` and confirm it links clean and fits below the model region
- [ ] T021 [US1] Copy the quantized model to a FAT card and verify its header on the host with a hexdump against `q8_format.h`
- [ ] T022 [HW] [US1] Program the feature-003 minimal bitstream and run the quantized model with `(cd FemtoRV/FIRMWARE/llama2 && make upload)`; confirm it loads and generates — *Session A*
- [ ] T023 [HW] [US1] Confirm the on-board output is byte-identical to the T010 golden reference for the same prompt and seed, recording the transcript in `specs/004-int8-matmul-accel/research.md` — *Session A*
- [ ] T024 [HW] [US1] Compare quantized output against feature 003's fp32 transcript and record both texts side by side in `specs/004-int8-matmul-accel/research.md` — *Session A*
- [ ] T025 [HW] [US1] Record the quantized generation rate and the activation-quantization cost from T019 in `specs/004-int8-matmul-accel/research.md` — *Session A*
- [ ] T026 [US1] **CONFIRM the T014 decision on hardware**: check that the on-board generated text is consistent with the host-side verdict and record any disagreement in `specs/004-int8-matmul-accel/research.md`. T014 already made the go/no-go from measured divergence, so this is confirmation rather than the decision — but a surprise here (board output materially worse than the host predicted) means something differs between host and firmware and MUST be resolved before RTL work proceeds
- [ ] T027 [US1] Update `spec.md` SC-003 and SC-004 with the measured size ratio and capacity figure, replacing the estimates (constitution Principle VI)

**Checkpoint**: US1 complete — quantization viability settled, golden reference exists, and the
software baseline is measured. **Only now does hardware work begin.**

---

## Phase 4: User Story 2 — Accelerator correct in simulation (Priority: P2)

**Goal**: prove the arithmetic and control in simulation, with no board.

**Independent Test**: cocotb testbenches produce bit-identical results to the host reference.

- [ ] T028 [US2] Specify the `acc_mac.v` interface in its port list before writing logic — lane count and element width as parameters (constitution "Parameterisation"; FR-011 makes this load-bearing for the 16-bit fallback)
- [ ] T029 [US2] Write `FemtoRV/TEST/acc_mac_tb.py` **before** the implementation: drive random int8 vectors, compare against a Python model of the host reference, cover sign and boundary cases
- [ ] T030 [US2] Implement `FemtoRV/RTL/ACCEL/acc_mac.v` — parameterised int8 lanes, int32 accumulate, per-group rescale by the product of weight and activation scales (research R2). Write the multiply behaviourally; do not hand-instantiate DSP primitives (research R6)
- [ ] T031 [US2] Run `acc_mac_tb` and confirm bit-identical results over at least 1000 randomised cases (SC-005); record the count
- [ ] T032 [US2] Implement `FemtoRV/RTL/ACCEL/acc_weight_fetch.v`, modelled on `RTL/SDRAM/video_fetch_engine.v` — **prefetch the scale block into BRAM at operation start, then stream the dense int8 `q` block** (research R1: weights and scales are separate contiguous blocks, not interleaved, so the inner loop is single-source at full lane rate)
- [ ] T033 [US2] Implement `FemtoRV/RTL/ACCEL/acc_regs.v` — CSRs and descriptor queue per data-model entities 4 and 5, including the mandatory `PERF_CYCLES`/`PERF_STALL` counters (FR-008) and descriptor validation with distinguishable error codes (FR-009, contracts/accelerator-interface.md)
- [ ] T034 [US2] Implement `FemtoRV/RTL/ACCEL/acc_top.v` wiring MAC, fetch engine, register block, weight FIFO, activation BRAM and result BRAM
- [ ] T035 [US2] Write `FemtoRV/TEST/acc_unit_tb.py` driving `acc_top` against a simulated SDRAM, using the model's real matrix shapes (64x64, 64x172, 172x64, 64x512)
- [ ] T036 [US2] Run `acc_unit_tb`; confirm bit-identical results and that the weight FIFO never underruns at full burst rate; record achieved words/cycle
- [ ] T037 [US2] Cross-check one full matrix against `runq_host`'s dumped intermediates from T008, so the simulation is validated against the same reference the hardware will be
- [ ] T038 [US2] Verify descriptor rejection paths in simulation — `n % gs != 0`, unsupported `gs`, out-of-range `n`/`d`, oversized `d` — each producing its distinct error code and not starting (FR-009)
- [ ] T039 [US2] Verify abort returns the unit to idle from mid-operation within a bounded time and flushes the FIFO (FR-010), extending `FemtoRV/TEST/acc_unit_tb.py`

**Checkpoint**: US2 complete — arithmetic and control proven without a board.

---

## Phase 5: User Story 3 — Memory sharing is fair (Priority: P3)

**Goal**: prove neither the processor nor the accelerator is starved, and choose the burst
length from measurement.

**Independent Test**: simulate under synthetic processor load; measure both parties.

**⚠️ This phase edits RTL shared with the working profile.** Constitution Principle V applies.

- [ ] T040 [US3] Parameterise the IDLE-state arbitration priority in `FemtoRV/RTL/SDRAM/muchtoremember_burst.v` so the CPU-first order is selectable, defaulting to the existing burst-first behaviour. **Do not simply reorder** — the display profile depends on burst-first, where a starved scanline is visible corruption (research R10, plan Complexity Tracking)
- [ ] T041 [US3] Add the accelerator starvation guard to `FemtoRV/RTL/SDRAM/muchtoremember_burst.v` — force a burst after N consecutive denied rounds — and expose its trigger count for observation (FR-017; the design expects it never to fire, and that assumption must be checked rather than trusted)
- [ ] T042 [US3] Write `FemtoRV/TEST/acc_arb_tb.py` with a synthetic CPU traffic generator at configurable intensity, measuring accelerator words/cycle and CPU worst-case wait
- [ ] T043 [US3] Run `FemtoRV/TEST/acc_arb_tb.py` with the CPU generator idle; confirm at least 0.9 words/cycle (SC-006)
- [ ] T044 [US3] Run `FemtoRV/TEST/acc_arb_tb.py` with periodic CPU misses; confirm CPU worst-case wait stays within one burst and accelerator throughput degrades gradually rather than collapsing (SC-007, SC-008)
- [ ] T045 [US3] Sweep burst length across 16/32/64/128/256 words and record the measured efficiency-versus-latency table in `research.md`, **replacing the estimated table in the design document** (FR-020, constitution Principle VI)
- [ ] T046 [US3] Choose the burst length from T045's measurements and record the choice and its basis in `specs/004-int8-matmul-accel/research.md`
- [ ] T047 [US3] **Regression (constitution Principle V, SC-014, FR-021)**: run `cd FemtoRV && make colorlight_i5.synth` and confirm resources, timing and behaviour match the T006 baseline. This is mandatory, not a formality — the arbitration change touches RTL the working profile depends on

**Checkpoint**: US3 complete — sharing policy measured and the full profile proven unharmed.

---

## Phase 6: User Story 4 — Accelerator correct on hardware, isolated (Priority: P4)

**Goal**: first hardware exercise, with the language model deliberately not involved.

**Independent Test**: standalone test on the board versus a processor-computed reference.

- [ ] T048 [US4] Enable the accelerator in `FemtoRV/RTL/CONFIGS/colorlight_i5_llm_config.v` and instantiate `acc_top` in `FemtoRV/RTL/femtosoc.v` at the site `video_fetch_engine` occupies, connecting it to the SDRAM burst port and selecting the CPU-first arbitration parameter (research R10)
- [ ] T049 [US4] Map the result BRAM at `0x100000` in `FemtoRV/RTL/femtosoc.v` so the CPU reads results with ordinary loads rather than IO transactions (research R8, data-model entity 6)
- [ ] T050 [US4] Synthesize with `make colorlight_i5_llm.synth`; record LUT/BRAM/DSP/PLL usage and Fmax in `research.md` and confirm at least 25% logic free (SC-013) and timing met with margin (constitution "Timing")
- [ ] T051 [US4] Write `FemtoRV/FIRMWARE/examples/acc_test.c` — a standalone test that writes a known weight matrix and quantized vector to SDRAM, runs one operation, and compares against a processor-computed reference; serial output only
- [ ] T052 [US4] Add an `upload_acc_test` target to `FemtoRV/FIRMWARE/examples/Makefile` at load address `0x800000`, following the `upload_sdram_memtest` pattern from feature 003 (**not** the generic `upload_%` rule, which uses the RetroKernel address)
- [ ] T053 [HW] [US4] Program `femtosoc_llm.bit` and run `(cd FemtoRV/FIRMWARE/examples && make upload_acc_test)`; confirm the result matches the reference exactly — *Session B*
- [ ] T054 [HW] [US4] Record `PERF_CYCLES` and `PERF_STALL` and compare achieved words/cycle against T036's simulated figure — *Session B*
- [ ] T055 [HW] [US4] Verify at least two descriptor rejection paths and the abort path on real hardware via `FemtoRV/FIRMWARE/examples/acc_test.c`, recording results in `specs/004-int8-matmul-accel/research.md` — *Session B*
- [ ] T056 [US4] Run `cd FemtoRV && make colorlight_i5.synth` again after the `RTL/femtosoc.v` changes and record the result against the T006 baseline (SC-014)

**Checkpoint**: US4 complete — the accelerator works on silicon, in isolation.

---

## Phase 7: User Story 5 — Weight multiplies accelerated (Priority: P5)

**Goal**: first end-to-end benefit; attention still on the processor.

**Independent Test**: generated text byte-identical to the US1 software run.

- [ ] T057 [US5] Implement `FemtoRV/FIRMWARE/llama2/acc_driver.c` and `acc_driver.h` per contracts/accelerator-interface.md — descriptor issue, status polling, counter reads, and a timeout that aborts rather than waiting forever
- [ ] T058 [US5] Confirm the completion spin loop in `FemtoRV/FIRMWARE/llama2/acc_driver.c` fits the CPU instruction cache by inspecting `llama2.list`; if it does not, waiting generates SDRAM traffic that competes with the transfer being waited on (FR-015, contracts note)
- [ ] T059 [US5] Replace the weight `matmul` call in `FemtoRV/FIRMWARE/llama2/runq.c` with the accelerator path, keeping the software implementation available behind a compile-time switch for A/B comparison
- [ ] T060 [HW] [US5] Run `(cd FemtoRV/FIRMWARE/llama2 && make upload)` and confirm output is **byte-identical** to T023's software transcript for the same prompt and seed (SC-009) — *Session C*
- [ ] T061 [HW] [US5] Record the generation rate in `specs/004-int8-matmul-accel/research.md`; expect roughly 2.5x over the US1 baseline, consistent with accelerating ~61% of the work — *Session C*
- [ ] T062 [HW] [US5] Re-run the profiler (`MEASURE_MODE 1` in `FemtoRV/FIRMWARE/llama2/runq.c`) and confirm the matmul category has collapsed and attention is now the largest; record the breakdown in `specs/004-int8-matmul-accel/research.md` — *Session C*
- [ ] T063 [US5] If the speed-up is well short of expectation, use `PERF_STALL`/`PERF_CYCLES` to attribute it to bandwidth or control logic (SC-015) and record the finding before proceeding

**Checkpoint**: US5 complete — the accelerator is doing useful work end to end.

---

## Phase 8: User Story 6 — Attention accelerated (Priority: P6)

**Goal**: the feature's actual target rate.

**Independent Test**: generated text still byte-identical; rate meets SC-011.

- [ ] T064 [US6] Add attention score and weighted-sum modes to `FemtoRV/RTL/ACCEL/acc_top.v` and `acc_weight_fetch.v` — same datapath, different address pattern (contracts/accelerator-interface.md)
- [ ] T065 [US6] Extend `FemtoRV/TEST/acc_unit_tb.py` to cover both attention modes against the host reference; confirm bit-identical (constitution Principle II — new RTL needs its testbench before hardware)
- [ ] T066 [US6] Extend `FemtoRV/FIRMWARE/llama2/acc_driver.c` with the attention modes, leaving softmax between them on the processor
- [ ] T067 [US6] Route the attention computation in `FemtoRV/FIRMWARE/llama2/runq.c` to the accelerator, keeping the software path behind the same compile-time switch
- [ ] T068 [US6] Re-synthesize with `make colorlight_i5_llm.synth` and confirm resources and timing still meet SC-013; record in `specs/004-int8-matmul-accel/research.md`
- [ ] T069 [HW] [US6] Run `(cd FemtoRV/FIRMWARE/llama2 && make upload)` and confirm output is still **byte-identical** to T023 (SC-010) — *Session C*
- [ ] T070 [HW] [US6] Record the generation rate in `specs/004-int8-matmul-accel/research.md` and confirm at least 8 tokens/second (SC-011) — *Session C*
- [ ] T071 [HW] [US6] Re-run the profiler; confirm accelerated categories are under 15% of per-token time (SC-012) and record the full breakdown and the scalar remainder in `specs/004-int8-matmul-accel/research.md` — *Session C*
- [ ] T072 [US6] Measure the KV-cache stride waste in attention mode — the cache is laid out `[layer][pos][kv_dim]` with a 128-byte stride, smaller than the burst, so neighbouring heads are fetched too. Record the measured cost and decide from it whether a strided mode is worth adding (contracts note; do not add it speculatively)

**Checkpoint**: US6 complete — the feature's value is realised.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T073 [P] Update `specs/004-int8-matmul-accel/quickstart.md` with all measured numbers, replacing the illustrative ones
- [ ] T074 [P] Update `FemtoRV/RTL/ACCEL/DESIGN.md` to correct the two assumptions Phase 0 overturned — Q8_0 uses separate blocks rather than interleaving, and the activation vector is quantized too — so the design document stops disagreeing with the implementation
- [ ] T075 [P] Update `CLAUDE.md` with the accelerator build commands, its resource figures, and the final measured rate
- [ ] T076 Walk `quickstart.md` end to end from a clean checkout to confirm SC-012's reproducibility intent; fix any step needing knowledge not written down
- [ ] T077 [P] Record follow-on findings for the next feature in `specs/004-int8-matmul-accel/accelerator-outcome.md`: the measured scalar remainder, the clock-increase opportunity from feature 003's 40.76 MHz ceiling, and whether int8's capacity gain is worth exploiting with a larger model
- [ ] T078 Final full-profile regression — `make colorlight_i5.synth` still produces a working image after every change (SC-014, constitution Principle V)
- [ ] T079 Re-evaluate this feature against `.specify/memory/constitution.md` and record the result, including whether the Principle V deviation was handled as the plan claimed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup; **blocks all stories**
- **US1 (Phase 3)**: depends on Foundational. **Blocks every later phase** — see below
- **US2 (Phase 4)**: depends on US1's decision gate (**T014**, host-side — not the later hardware confirmation at T026)
- **US3 (Phase 5)**: depends on Foundational (T006 baseline); may run alongside US2
- **US4 (Phase 6)**: depends on US2 and US3
- **US5 (Phase 7)**: depends on US4
- **US6 (Phase 8)**: depends on US5
- **Polish (Phase 9)**: depends on all stories

### The one hard gate

**T014 blocks all RTL work, and it runs entirely on the host.** It decides whether this feature
targets 8-bit or 16-bit by measuring the divergence between the quantized and full-precision
models' predicted token distributions — mean and p99 KL, plus top-1 agreement — rather than by
reading two paragraphs of generated text and forming an opinion.

Writing integer arithmetic before that answer risks building a datapath a no-go verdict
discards, and the fallback changes the basis of bit-exact verification, which every later
stage's pass/fail depends on.

**Why the measurement comes before the board**: both models' distributions are obtainable on the
host, so the verdict needs no hardware. A no-go answer therefore costs minutes rather than a
build-flash-upload cycle. T026 confirms the verdict on real hardware; it does not make it.

### Why stories are sequential

Hardware bring-up is layered: each stage is physically required by the next. What is preserved
is independent verifiability — each story has its own pass/fail, and work can stop at any
checkpoint with a coherent result. This mirrors constitution Principle III.

### Parallel Opportunities

- T001, T002, T004 in parallel (different new files)
- T007 and T008 in parallel (script versus host C program)
- **US3 (Phase 5) can run alongside US2 (Phase 4)** — different files, and the arbitration work
  only needs the T006 baseline. This is the largest genuine parallelism available
- T073, T074, T075, T077 in parallel during Polish
- Within a hardware session, tasks are strictly sequential — one board, one operator

---

## Parallel Example: US2 and US3 together

```bash
# Different files, no shared dependencies beyond Phase 2:
Task: "Implement FemtoRV/RTL/ACCEL/acc_mac.v"            # US2
Task: "Parameterise priority in RTL/SDRAM/muchtoremember_burst.v"  # US3
Task: "Write FemtoRV/TEST/acc_mac_tb.py"                 # US2
Task: "Write FemtoRV/TEST/acc_arb_tb.py"                 # US3
```

Both must converge before US4, which needs the accelerator and the arbitration together.

---

## Implementation Strategy

### MVP (User Story 1 only)

Phase 1 → Phase 2 → Phase 3, then **stop and evaluate**. This produces a quantized model
running on existing hardware, a measured software baseline, a golden reference, and — most
importantly — the answer to whether 8-bit is viable at all.

That is a genuine deliverable even if the accelerator is never built: it is a 3.5x reduction in
model size, which is what makes a larger model possible regardless of what computes it.

### Incremental Delivery

1. Setup + Foundational → scaffolding and regression baseline
2. + US1 → quantized model runs, decision recorded (**MVP**)
3. + US2 → arithmetic proven in simulation
4. + US3 → sharing policy measured, full profile proven unharmed
5. + US4 → accelerator works on silicon
6. + US5 → ~2.5x, output unchanged
7. + US6 → target rate reached (**the point of the feature**)

### Cost control

Sessions A, B and C are the only hardware time. Everything else runs on the host, which is why
Phases 4 and 5 are simulation-only and why the decision gate sits before them.

---

## Notes

- **[P]** = different files, no dependencies
- **[HW]** = needs the board; batched into Sessions A, B, C
- Every [HW] task states its command, expected result, and what to record
- Estimates in `research.md`, `spec.md` and `DESIGN.md` must be replaced with measurements as
  they arrive — T027, T045, T050, T071, T072 and T074 exist for exactly that (constitution
  Principle VI)
- Commit after each task or logical group
