---
description: "Task list for 003-llama2-minimal-soc"
---

# Tasks: Minimal RISC-V SoC for llama2.c

**Input**: Design documents from `/specs/003-llama2-minimal-soc/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: The spec does not request TDD. RTL simulation tests are included only where new
hardware is written (none is, in this feature). What the spec *does* mandate is
hardware-in-the-loop verification, so acceptance tasks appear inside each story phase and are
marked **[HW]**.

**Organization**: Tasks are grouped by user story. Hardware bring-up is strictly layered, so
stories are sequential rather than parallel — but each remains independently verifiable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[HW]**: Requires the physical board and operator assistance
- **[Story]**: Which user story this task belongs to

## Path Conventions

Repository root is `/opt/wip/learn-fpga`. Feature work lands in the existing `FemtoRV/` tree
per plan.md. All paths below are repo-relative.

---

## Operator-Assisted Sessions

The user asked for hardware testing to be planned explicitly. Every **[HW]** task below
belongs to one of three batched sessions so that board time is concentrated rather than
constantly interrupting. Each **[HW]** task states the exact command, the expected output,
and what to record.

| Session | Tasks | Purpose | Est. bench time |
|---|---|---|---|
| **A** | T014-T019 | Boots, capacity, RAM integrity, and the SD throughput risk | ~30 min |
| **B** | T026-T030 | Model loads and verifies; program uploads and runs | ~30 min |
| **C** | T036-T039, T044-T046 | Generation, determinism, timing breakdown | ~45 min |

Before each session the developer confirms all host-side tasks for it are complete. After
each session the recorded numbers are written back into this file and into `research.md`
where they replace estimates.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the new build profile. Purely additive — no existing behaviour changes.

- [X] T001 [P] Create minimal profile config at `FemtoRV/RTL/CONFIGS/colorlight_i5_llm_config.v`, defining `COLORLIGHT_I5`, `NRV_IO_LEDS`, `NRV_IO_UART`, `NRV_IO_TIMER`, `NRV_IO_SDCARD`, `NRV_IO_SDRAM`, `NRV_IO_HARDWARE_CONFIG`, `NRV_FEMTORV32_PETITBATEAU`, `NRV_FREQ 25`, `NRV_RAM 32768`, `NRV_RESET_ADDR 0`, and ending with `NRV_CONFIGURED`; omit GPU, SYNTH, PS2, SEGMENT, INT_CONTROLLER
- [X] T002 Add dispatch branch to `FemtoRV/RTL/femtosoc_config.v`: insert `` `ifdef COLORLIGHT_I5_LLM `` including the new config **before** the existing `COLORLIGHT_I5` branch, and wrap the existing `COLORLIGHT_I5` include in `` `ifndef NRV_CONFIGURED `` so the first match wins (research R1)
- [X] T003 [P] Create trimmed pin file `FemtoRV/BOARDS/colorlight_i5_llm.lpf` by copying `colorlight_i5.lpf` and keeping only `pclk` with its `FREQUENCY` constraint, `RESET`, `D1_pin`-`D8_pin`, `TXD`/`RXD`, the SD card group (`sd_cs_n`/`sd_mosi`/`sd_miso`/`sd_clk`) and the SDRAM group (`sdram_clk`/`sd_addr`/`sd_d`/`sd_ba`/`sd_we`/`sd_ras`/`sd_cas`); delete gpdi, ps2, segments, audio, and SPI-flash pins — note `sd_d`/`sd_addr` are SDRAM, not the card (research R3)
- [X] T004 [P] Create board makefile `FemtoRV/BOARDS/colorlight_i5_llm.mk` with `colorlight_i5_llm.synth`, `.prog_fast`, `.prog`, and `.firmware_config` targets, passing `-DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DACTIVE_LOW_LEDS` to yosys and using the new `.lpf`; omit the `font_data.hex` copy that the full profile performs
- [X] T005 Add `include BOARDS/colorlight_i5_llm.mk` to `FemtoRV/Makefile` alongside the existing board includes
- [X] T006 [P] Create firmware skeleton `FemtoRV/FIRMWARE/llama2/` with a `Makefile` modelled on `FIRMWARE/examples/Makefile` (linking `-lfemtorv32 -lfemtoc -lm`) and `llama2.ld` linking at `0x800000` per the memory layout in data-model.md entity 2

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Prove the profile builds, prove the existing profile still builds, and retire the
single largest open risk in the plan.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T007 Build the minimal profile with `cd FemtoRV && make colorlight_i5_llm.firmware_config && make colorlight_i5_llm.synth`, resolving any synthesis errors; the two expected failure modes are an undefined `femtoPLL` (T002/T004 defines wrong) and unmatched pin constraints (T003 trimming wrong)
- [ ] T008 Verify no regression: `cd FemtoRV && make colorlight_i5.firmware_config && make colorlight_i5.synth` still succeeds unchanged, satisfying SC-011 and FR-002 — this guards the shared `femtosoc_config.v` edit from T002
- [X] T009 Record logic, memory-block, multiplier, and PLL utilisation from the T007 nextpnr report into `specs/003-llama2-minimal-soc/research.md` under R2, replacing the **MEASURE** placeholder, and check against SC-004 (≥40% logic and ≥40% memory blocks free)
- [X] T010 [P] Adapt `FemtoRV/FIRMWARE/examples/sdram_test.c` into a serial-only memory test covering the full usable range `0x800000`-`0xEFFFFF`, removing all `GPU_WRITE`/`gpu_*` output which does not exist in this profile, and reporting errors plus sustained transfer rate (FR-006)
- [X] T011 [P] Create `FemtoRV/FIRMWARE/examples/sd_bench.c` — a minimal serial-only SD read benchmark using the `sd_init`/`fl_attach_media`/`fl_fopen`/`fl_fread` pattern from `sd_dir.c`, reading a large file and reporting bytes, elapsed seconds, and KB/s using `cycles()`; strip all GPU output
- [X] T012 [P] Create `FemtoRV/FIRMWARE/llama2/tools/fetch_model.sh` to download the ~260K-parameter model and its **matching reduced-vocabulary** tokenizer, printing the byte length and checksum of each (contracts/build-targets.md)
- [~] T013 Run `fetch_model.sh`, copy `model.bin` and `tokenizer.bin` to the root of a FAT-formatted card, and verify the header fields against data-model.md entity 3 with a host-side hexdump — this is the **VERIFY** item in research R5 and must be done before the on-board loader trusts the layout
  - [X] host side: fetch_model.sh run; header verified (dim=64 hidden=172 layers=5 heads=8 kv=4 vocab=512 seq=512); weight layout confirmed to INCLUDE freq_cis tables (264,128 floats = 1,056,512 B = filesize-28)
  - [ ] **[HW]** copy model.bin + tokenizer.bin to a FAT card and fit it to the board — *Session A/B*

**Checkpoint**: Both profiles build; test programs compile; card is prepared.

---

## Phase 3: User Story 1 — A minimal platform that boots (Priority: P1) 🎯 MVP

**Goal**: A stripped build that boots to a serial prompt with substantial capacity freed.

**Independent Test**: Program the board, see a monitor prompt, read the resource report.

- [ ] T014 [HW] [US1] Program the board with `openFPGALoader -c cmsisdap -v --file-type bin femtosoc_llm.bit` from `FemtoRV/`, confirming the volatile load succeeds — *Session A*. **NOTE: use `femtosoc_llm.bit`, not `femtosoc.bit`.** Both profiles write to `femtosoc.bit`, so whichever synthesised last wins; the minimal profile's output was preserved as `femtosoc_llm.bit` (259,704 bytes). To regenerate it: `make colorlight_i5_llm.synth && cp femtosoc.bit femtosoc_llm.bit`
- [ ] T015 [HW] [US1] Connect at 115200 8N1 (`screen /dev/ttyACM0 115200`), reset the board, and confirm the monitor prompt appears within 5 seconds (SC-002); press `H` and confirm the `H D E S L G C M` command list — *Session A*
- [ ] T016 [US1] Record the boot-to-prompt time and the T009 resource figures in `specs/003-llama2-minimal-soc/tasks.md` under Session A results, confirming SC-004 is met

**Checkpoint**: US1 complete — a usable minimal platform exists.

---

## Phase 4: User Story 2 — External RAM proven correct (Priority: P2)

**Goal**: Prove SDRAM is sound under the access patterns the model will use, so that later
incoherent output can never be blamed on RAM.

**Independent Test**: Full-range memory test reports zero errors and a transfer rate.

- [ ] T017 [HW] [US2] Upload the T010 memory test with monitor `L`, start it with `G`, and run it over the full `0x800000`-`0xEFFFFF` range; confirm zero errors and record the reported sustained transfer rate — *Session A*
- [ ] T018 [HW] [US2] Repeat the memory test three consecutive times confirming zero errors on every run (SC-003), recording results in `specs/003-llama2-minimal-soc/tasks.md`; a single intermittent failure here must be resolved before any later story is trusted — *Session A*
- [ ] T019 [HW] [US2] Upload and run the T011 SD benchmark (`FemtoRV/FIRMWARE/examples/sd_bench.c`) via monitor `L`/`G`, recording bytes, elapsed time, and KB/s — *Session A*
- [ ] T020 [US2] Write the T019 throughput into `research.md` R6 replacing the 30-80 KB/s estimate, and into `spec.md` SC-005 if the 60-second target needs revising; if throughput implies >60 s for 1 MB, evaluate the R6 escalation options **before** proceeding to Phase 5

**Checkpoint**: US2 complete — RAM is trustworthy and the loading strategy is confirmed or
revised on real numbers.

---

## Phase 5: User Story 3 — Getting programs and model data onto the board (Priority: P3)

**Goal**: Model loads from card with no host involvement; program arrives over serial.

**Independent Test**: Load the model from the card and verify it against a host checksum;
separately upload and start a program.

- [X] T021 [P] [US3] Implement header parsing and validation in `FemtoRV/FIRMWARE/llama2/model_load.c` per data-model.md entity 3: read the seven `int32` fields, handle negative `vocab_size` as the unshared-classifier signal, bounds-check every field, and confirm file length matches the length implied by the header (FR-015)
- [X] T022 [US3] Implement the card-to-SDRAM load in `model_load.c`, reading `/model.bin` into `0x900000` in chunks and refusing before loading if the implied size exceeds the 1 MB region (FR-008)
- [X] T023 [US3] Implement tokenizer loading in `model_load.c` reading `/tokenizer.bin` into `0xA00000`, and **assert the token count equals `abs(vocab_size)`**, failing loudly on mismatch (FR-018a) — this is the highest-value check in the feature because a mismatch produces fluent-but-wrong text rather than an error
- [X] T024 [US3] Implement the distinguishable failure paths in `FemtoRV/FIRMWARE/llama2/model_load.c` per `contracts/console-interface.md`: no card, unreadable filesystem, missing file, truncated file, oversized header, token-count mismatch, and card removed mid-load (FR-012)
- [X] T025 [US3] Implement the Load Report output in `model_load.c` — bytes, elapsed, KB/s, verification result, and the parsed model dimensions (FR-012a, data-model.md entity 8)
- [ ] T026 [HW] [US3] Upload the loader with monitor `L`/`G` and load the model from the card; confirm the reported byte count and checksum match the T012 host values (FR-011) — *Session B*
- [ ] T027 [HW] [US3] Use monitor `D 900000` to spot-check that weights landed at the expected address, and `D A00000` for the tokenizer — *Session B*
- [ ] T028 [HW] [US3] Verify each failure path from T024 by testing at minimum: card removed, and a deliberately truncated `model.bin` — confirm each is reported distinguishably rather than hanging or proceeding — *Session B*
- [ ] T029 [HW] [US3] Confirm the model load is repeatable on demand without a host transfer (FR-010b) by running it twice in one power cycle, noting the outcome in `specs/003-llama2-minimal-soc/tasks.md` — *Session B*
- [ ] T030 [HW] [US3] Confirm SC-005: 1 MB loads and verifies within 60 seconds with no host involvement; record the actual time in `specs/003-llama2-minimal-soc/tasks.md` — *Session B*

**Checkpoint**: US3 complete — the delivery path works and the development loop is fast.

---

## Phase 6: User Story 4 — The model generates text (Priority: P4)

**Goal**: Coherent English prose over serial, token by token.

**Independent Test**: Start generation and watch at least 100 tokens appear without hang or
corruption.

- [ ] T031 [US4] Port the reference implementation into `FemtoRV/FIRMWARE/llama2/llama2.c`, removing the memory-mapped file load in favour of a pointer to weights already resident at `0x900000`, and removing all host file I/O (research R8)
- [ ] T032 [US4] Replace dynamic allocation of the run state with static allocation at fixed addresses from data-model.md entity 2, sizing the KV cache as `2 × n_layers × seq_len × kv_dim × 4` bytes and bounds-checking it against the region (FR-008)
- [ ] T033 [US4] Replace the wall-clock RNG seed and any host timing calls with `cycles()` from `LIBFEMTORV32/cycles_32.c` (research R9)
- [ ] T034 [US4] Implement incremental token output to serial in `FemtoRV/FIRMWARE/llama2/llama2.c` as each token is produced — not buffered to the end, since it is the operator's only progress indicator on a multi-minute run (`contracts/console-interface.md`)
- [ ] T035 [US4] Implement clean termination on reaching the requested token count or `seq_len` (FR-016) and report the achieved generation rate on completion (FR-017)
- [ ] T036 [HW] [US4] Upload `llama2.bin` with monitor `L` and start it with `G 800000`; confirm text appears incrementally — *Session C*
- [ ] T037 [HW] [US4] Generate at least 100 consecutive tokens confirming no hang, crash, or corruption (SC-006), and confirm the output reads as recognisable English prose (SC-007); paste a sample into `specs/003-llama2-minimal-soc/tasks.md` — expect simple, sometimes repetitive text, which is correct for a model this small — *Session C*
- [ ] T038 [HW] [US4] Run generation twice with identical model, prompt, and seed and confirm byte-identical output (SC-009, FR-014), recording both transcripts for comparison in `specs/003-llama2-minimal-soc/tasks.md` — *Session C*
- [ ] T039 [HW] [US4] Confirm SC-008 (≥0.5 tokens/second) and SC-005a (rebuild → upload → restart in under 60 s without reloading the model); record both in `specs/003-llama2-minimal-soc/tasks.md` — *Session C*

**Checkpoint**: US4 complete — the headline outcome is demonstrated.

---

## Phase 7: User Story 5 — Knowing where the time goes (Priority: P5)

**Goal**: An evidence-based per-token timing breakdown that decides what a future accelerator
should target.

**Independent Test**: Run measurement mode and confirm categories account for ≥90% of
per-token time.

- [X] T040 [US5] Implement per-category cycle accounting in `FemtoRV/FIRMWARE/llama2/profile.c` with mutually exclusive counters for matrix multiply, attention, normalisation, rotary position encoding, and sampling, using `cycles()` and accumulating across a run
- [X] T041 [US5] Compute `other` as a residual — total minus the sum of named categories — so the coverage claim is proven rather than estimated (FR-020, data-model.md entity 7)
- [X] T042 [US5] Implement the Performance Report output in `FemtoRV/FIRMWARE/llama2/profile.c` per `contracts/console-interface.md`: token count, elapsed, rate, per-category percentages, largest category by name, and coverage percentage
- [ ] T043 [US5] Add a measurement mode flag to the generation entry point in `FemtoRV/FIRMWARE/llama2/llama2.c` so profiling can be enabled without a separate binary
- [ ] T044 [HW] [US5] Run generation in measurement mode over at least 100 tokens and paste the full report into `specs/003-llama2-minimal-soc/tasks.md` — *Session C*
- [ ] T045 [HW] [US5] Confirm coverage ≥90% (SC-010) and that the largest category is named explicitly in the T044 report captured in `specs/003-llama2-minimal-soc/tasks.md` — *Session C*
- [ ] T046 [US5] Record the measured breakdown in `research.md` under R9, replacing the expectation with the finding, and state plainly whether matrix multiply or the transcendental functions dominate

**Checkpoint**: US5 complete — the accelerator decision now rests on measurement.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T047 [P] Update `specs/003-llama2-minimal-soc/quickstart.md` with the real measured numbers from Sessions A-C, replacing the illustrative figures in the load and report examples
- [ ] T048 [P] Update `CLAUDE.md` with the minimal profile build commands, its resource figures, and the measured generation rate, alongside the existing full-profile entries
- [ ] T049 Walk `quickstart.md` end to end from a clean checkout to confirm SC-012 — someone who did not implement this can reach generated text unaided; fix any step that requires knowledge not written down
- [ ] T050 [P] Record the follow-on findings for the accelerator work: measured SDRAM bandwidth from T017, the timing breakdown from T046, and whether software wins (precomputed rotary tables, fast `expf`) should precede any RTL
- [ ] T051 Confirm SC-011 one final time — `make colorlight_i5.synth` still produces a working full-profile image after all changes

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies; T001-T006 mostly parallel, but T002 and T005 touch shared files
- **Foundational (Phase 2)**: depends on Setup; **blocks all user stories**
- **US1 (Phase 3)**: depends on Foundational
- **US2 (Phase 4)**: depends on US1 — needs a booting board
- **US3 (Phase 5)**: depends on US2 — RAM must be proven before loading anything into it
- **US4 (Phase 6)**: depends on US3 — nothing to run without weights loaded
- **US5 (Phase 7)**: depends on US4 — nothing to measure without generation
- **Polish (Phase 8)**: depends on all stories

### Why stories are sequential here

The template assumes stories are independent slices. Hardware bring-up is not: each layer is
physically required by the next. What is preserved is *independent verifiability* — each story
has its own pass/fail signal on the board, and work can stop at any checkpoint with a
coherent, demonstrable result.

### Critical path risk

T019/T020 (SD throughput) sits in Phase 2 rather than in US3 where it thematically belongs.
This is deliberate: it is the only unmeasured quantity in the plan, and if it lands far below
estimate the entire loading strategy changes. Discovering that after the inference program is
written would be expensive. It is placed as a foundational risk-retirement task and runs in
the first hardware session.

### Parallel Opportunities

- T001, T003, T004, T006 in parallel (different new files)
- T010, T011, T012 in parallel (different files, all host-side)
- T021 parallel with T012/T013 (independent of card preparation)
- T047, T048, T050 in parallel during Polish
- Within hardware sessions, tasks are strictly sequential — one board, one operator

---

## Parallel Example: Phase 1 Setup

```bash
# These four create independent new files and can be written together:
Task: "Create FemtoRV/RTL/CONFIGS/colorlight_i5_llm_config.v"
Task: "Create FemtoRV/BOARDS/colorlight_i5_llm.lpf"
Task: "Create FemtoRV/BOARDS/colorlight_i5_llm.mk"
Task: "Create FemtoRV/FIRMWARE/llama2/ skeleton with Makefile and llama2.ld"

# T002 and T005 edit shared existing files — do these separately, then build.
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US1
2. **STOP and VALIDATE**: a minimal platform that boots, with capacity freed and measured
3. This alone is a deliverable — it is the platform the accelerator will be built on

### Incremental Delivery

Each phase ends at a checkpoint that is demonstrable on hardware:

1. Setup + Foundational → both profiles build, capacity measured
2. + US1 → board boots to a prompt (**MVP**)
3. + US2 → RAM proven, SD throughput known
4. + US3 → model loads from card in seconds, fast development loop
5. + US4 → text generation (**headline outcome**)
6. + US5 → timing breakdown (**the deliverable that matters most**)

### Session A is the highest-value hour

Session A retires almost all the technical risk in this feature: whether the stripped profile
boots, whether enough capacity was actually freed, whether RAM is sound, and whether SD is
fast enough for the chosen loading strategy. If any of those fail, they fail before any
significant firmware has been written.

---

## Notes

- [P] = different files, no dependencies
- [HW] = requires the board; grouped into Sessions A, B, C to keep bench time concentrated
- Every [HW] task states its command, expected result, and what to record
- Commit after each task or logical group
- Estimates in `research.md` and `spec.md` must be replaced with measurements as they arrive —
  T009, T020, and T046 exist specifically for that
