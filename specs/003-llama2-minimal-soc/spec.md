# Feature Specification: Minimal RISC-V SoC for llama2.c

**Feature Branch**: `003-llama2-minimal-soc`
**Created**: 2026-08-18
**Status**: Draft
**Input**: User description: "minimal RISC-V SoC with SDRAM and serial for llama2.c, please include getting llama2.c running with the 120k model as well in this spec, since were running on real hardware you'll need some support from me to test I presume. Let's plan that into the tasks later."

## Overview

Reduce the existing full-featured retro-computing SoC to a minimal platform containing only a RISC-V processor, external RAM, a serial console, and local card storage, then bring up a small language model end-to-end on that platform so it generates text over the serial connection.

Loading is deliberately split by how often each artifact changes. Model weights are large and effectively immutable, so they live on local storage and are loaded on board without host involvement. The program is small and changes on every edit, so it continues to arrive over the serial connection. This keeps the slow path off the development loop: the multi-minute transfer is paid once when the model is placed on the card, not on every reset.

This feature delivers two things: a lean, well-characterised hardware platform with substantial free capacity, and a measured performance baseline for language-model inference on it. Both are prerequisites for the follow-on work of designing a matrix-multiply accelerator; neither the accelerator nor any change to processor speed is part of this feature.

## User Scenarios & Testing *(mandatory)*

The stories below are ordered by build sequence. Hardware bring-up is inherently layered — each story depends on the one before it — so priority here reflects the order in which value can be delivered and verified on real hardware, not independent parallel slices. Each story is, however, independently *testable*: each has its own observable pass/fail signal on the board.

### User Story 1 - A minimal platform that boots (Priority: P1)

A developer selects a new build configuration that includes only the processor, external RAM, status indicators, the serial console, and local card storage. They build it, program the board, and see an interactive prompt on their terminal. All display, audio, keyboard, and wireless hardware is absent from this configuration. Card storage is kept because it is driven in software over general-purpose pins and therefore costs almost none of the capacity this story exists to free up.

**Why this priority**: Nothing else in this feature can be attempted until a stripped build exists and boots. The freed capacity is also the central deliverable — it is what makes future accelerator hardware possible.

**Independent Test**: Build the configuration from a clean checkout, program the board, and confirm an interactive prompt appears on the serial console. Read the build's resource report to confirm the expected free capacity. Delivers a usable development platform on its own.

**Acceptance Scenarios**:

1. **Given** a clean checkout, **When** the developer runs the documented build command for the minimal configuration, **Then** a programmable device image is produced with no errors.
2. **Given** the device image is programmed onto the board, **When** the board is powered on or reset, **Then** an interactive prompt appears on the serial console.
3. **Given** a completed build, **When** the developer reads the resource report, **Then** unused logic and memory capacity meet the headroom targets in Success Criteria.
4. **Given** the pre-existing full-featured configuration, **When** it is built, **Then** it still succeeds and behaves exactly as before this feature.

---

### User Story 2 - External RAM proven correct and characterised (Priority: P2)

A developer runs a memory test from the serial console that writes and reads back the entire usable range of external RAM, reporting any errors and the sustained transfer rate achieved.

**Why this priority**: The language model depends completely on external RAM correctness under sustained streaming access. A latent RAM fault would surface later as incoherent generated text and would be extremely difficult to distinguish from a software defect. Proving RAM first removes that ambiguity permanently. The measured transfer rate also establishes the ceiling that later accelerator work is designed against.

**Independent Test**: Issue the memory test command from the serial prompt and observe a pass result covering the full range, plus a reported transfer rate.

**Acceptance Scenarios**:

1. **Given** a booted board, **When** the developer runs the memory test over the full usable external RAM range, **Then** it reports zero errors.
2. **Given** the memory test completes, **When** the developer reads the output, **Then** a sustained transfer rate is reported in a documented unit.
3. **Given** the memory test is run three times consecutively, **When** results are compared, **Then** all three runs report zero errors.

---

### User Story 3 - Getting programs and model data onto the board (Priority: P3)

A developer places the model file once on a storage card and, from then on, loads it on the board with no host transfer at all. Separately, they transfer their compiled program from the host over the serial connection each time they rebuild it, and start it running.

**Why this priority**: This is the delivery path for everything that follows, and its structure determines how fast the development loop can be. The two artifacts have very different change rates: the model is roughly a megabyte and effectively never changes, while the program is far smaller and changes on every edit. Routing both over the serial connection would mean paying a multi-minute transfer on every reset, because working memory is volatile and loses its contents. Loading the model from local storage moves that cost off the loop entirely, while the program keeps the flexibility and immediacy of a direct host transfer.

**Independent Test**: With a model file present on the card, load it on the board and verify its integrity against a checksum computed on the host. Separately, transfer a program from the host and confirm it starts.

**Acceptance Scenarios**:

1. **Given** a storage card holding the model file, **When** the developer issues the load command, **Then** the model is read into working memory with no host involvement and its integrity is confirmed.
2. **Given** a booted board, **When** the developer transfers a program from the host over the serial connection, **Then** the board confirms receipt and the program can be started.
3. **Given** the model has already been loaded, **When** the developer transfers a new build of the program and starts it, **Then** the model does not need to be loaded again for that same power cycle.
4. **Given** no storage card is present, or the model file is missing from it, **When** the developer issues the load command, **Then** the failure is reported clearly rather than proceeding with unpopulated memory.
5. **Given** a transfer or card read is interrupted or corrupted partway, **When** the developer inspects the result, **Then** the failure is reported rather than silently accepted.

---

### User Story 4 - The model generates text (Priority: P4)

A developer starts the language model program with a small pre-trained model resident in external RAM and watches it generate a passage of English prose token by token on the serial console.

**Why this priority**: This is the headline outcome of the feature and the proof that the platform is genuinely capable of the target workload. It is sequenced last among functional stories because it depends on all three preceding stories being sound.

**Independent Test**: Start the model program from the serial prompt and observe generated text appearing on the console, continuing for at least one full passage without hanging or producing corrupted output.

**Acceptance Scenarios**:

1. **Given** a model and program resident in external RAM, **When** the developer starts generation, **Then** text appears on the serial console incrementally as tokens are produced.
2. **Given** generation is running, **When** at least 100 tokens have been produced, **Then** the program has not hung, crashed, or emitted corrupted output.
3. **Given** generation completes, **When** the developer reads the output, **Then** it is recognisable English prose in the style of the training data rather than random characters.
4. **Given** the same model, starting prompt, and random seed, **When** generation is run twice, **Then** both runs produce identical output.
5. **Given** generation completes, **When** the developer reads the summary, **Then** the achieved generation rate is reported.

---

### User Story 5 - Knowing where the time goes (Priority: P5)

A developer runs the model in a measurement mode that reports how per-token time divides across the major categories of work, so that a decision about what to accelerate in hardware can be made from evidence rather than assumption.

**Why this priority**: The entire purpose of this platform is to host a future accelerator. Building that accelerator without knowing which operations actually dominate risks large effort for negligible end-to-end gain. This story converts the feature from a demonstration into a decision input.

**Independent Test**: Run the measurement mode and confirm it reports a per-category time breakdown that accounts for essentially all of the measured per-token time.

**Acceptance Scenarios**:

1. **Given** a completed generation run, **When** the developer reads the measurement report, **Then** per-token time is broken down across named categories of work.
2. **Given** the breakdown, **When** the category times are summed, **Then** they account for at least 90% of total measured per-token time.
3. **Given** the report, **When** the developer reviews it, **Then** the single largest category is identified explicitly.

---

### Edge Cases

- **Capacity exhaustion**: What happens when the model data, program, working memory, and stack together exceed available external RAM? The system must detect and report this rather than silently overwriting one region with another.
- **Corrupted or partial transfer**: How does the system handle a transfer that is interrupted, truncated, or corrupted in flight? It must be detectable before the model is started, not diagnosed later from nonsense output.
- **Card absent or unreadable**: What happens when no storage card is fitted, the card is unformatted, or its filesystem is damaged? The system must say so plainly rather than hanging or loading garbage.
- **Model file missing or truncated on the card**: What happens when the expected file is absent, or is shorter than its header claims? This must be caught before generation starts.
- **Stale model on the card**: What happens when the card holds an older model than the program expects? The mismatch must be detectable rather than producing quietly wrong output.
- **Card removed mid-load**: What happens if the card is physically removed while a load is in progress? The system must fail visibly rather than continuing with partial data.
- **Malformed model file**: What happens when a model file with unexpected dimensions, a wrong header, or mismatched byte order is loaded? The program must reject it with a clear message rather than reading past the end of the data.
- **Sequence length limit**: What happens when generation reaches the model's maximum sequence length? It must terminate cleanly rather than reading beyond allocated working memory.
- **Numerical breakdown**: What happens if attention or normalisation produces a non-finite value? Output must not degrade silently into repeated or garbage tokens without any indication.
- **Console starvation**: What happens to serial output while the processor is fully occupied with computation for long stretches? Characters must not be dropped or reordered.
- **Reset during generation**: What happens if the board is reset mid-generation? It must return to a usable prompt, with the expectation that model data in volatile RAM is lost and must be re-transferred.
- **Sustained streaming stress**: Does external RAM remain reliable under continuous high-rate access for the duration of a long generation run, as opposed to the short bursts a memory test produces?

## Requirements *(mandatory)*

### Functional Requirements

**Platform**

- **FR-001**: The project MUST provide a build configuration containing only the processor, external RAM, status indicators, and the serial console.
- **FR-002**: The new build configuration MUST be selectable without modifying the existing full-featured configuration, and both MUST remain buildable from the same checkout.
- **FR-003**: The minimal configuration MUST omit all display, audio, keyboard, and wireless capability.
- **FR-003a**: The minimal configuration MUST retain local card storage, which costs negligible hardware because the protocol is driven in software over general-purpose pins.
- **FR-004**: The system MUST present an interactive console over the serial connection after reset.
- **FR-005**: The build MUST report its resource utilisation so that remaining capacity can be verified against the headroom targets.

**Memory**

- **FR-006**: The system MUST provide a command that tests the full usable range of external RAM and reports errors and sustained transfer rate.
- **FR-007**: The system MUST document a memory layout that assigns non-overlapping regions to program code, model data, working memory, and stack.
- **FR-008**: The system MUST detect and report when a requested load would exceed the region allocated to it.

**Transfer**

- **FR-009**: Users MUST be able to transfer a compiled program from a host machine to the board over the serial connection and start it.
- **FR-010**: Users MUST be able to load a model data file of at least 2 MB from local card storage into a specified location in external RAM, without any host involvement.
- **FR-010a**: The system MUST be able to read files from a storage card written by an ordinary desktop computer, so that placing a model on the card requires no special tooling.
- **FR-010b**: Loading the model MUST be repeatable on demand from the console, so that a reset does not require a host transfer.
- **FR-011**: The system MUST provide a means of verifying that loaded or transferred data matches the host copy exactly.
- **FR-012**: The system MUST report load and transfer failures — including a missing card, a missing file, and corrupted or truncated data — rather than accepting them silently.
- **FR-012a**: The system MUST report the time taken and the throughput achieved when loading the model from local storage.

**Model execution**

- **FR-013**: The system MUST run a language model program that reads its weights from external RAM and emits generated text to the serial console incrementally as tokens are produced.
- **FR-014**: The model program MUST accept a starting prompt and a random seed, and MUST produce identical output for identical inputs.
- **FR-015**: The model program MUST validate the model file's dimensions and reject a malformed file with a clear message.
- **FR-016**: The model program MUST terminate cleanly on reaching either a requested token count or the model's maximum sequence length.
- **FR-017**: The model program MUST report the achieved generation rate on completion.
- **FR-018**: The system MUST support a small pre-trained model of approximately 260,000 parameters, occupying under 2 MB at full precision.
- **FR-018a**: The vocabulary artifact used MUST match the vocabulary size of the model artifact, and a mismatch between the two MUST be detected and reported rather than producing garbled text.

**Measurement**

- **FR-019**: The system MUST provide a mode that reports per-token time divided across named categories of work.
- **FR-020**: The reported categories MUST together account for at least 90% of measured per-token time.

**Documentation**

- **FR-021**: The project MUST document the complete sequence — build, program, transfer, run — such that it can be reproduced by someone who did not implement it.
- **FR-022**: The project MUST document how to obtain or produce the model artifact used.

### Key Entities

- **Build configuration**: A named selection of which hardware capabilities are present in a device image. Two must coexist: the pre-existing full-featured one and the new minimal one.
- **Memory layout**: The documented assignment of external RAM regions to program code, model data, working memory, and stack, including the size budget for each.
- **Model artifact**: The trained model file, containing dimensions and weights, transferred to the board as opaque data.
- **Vocabulary artifact**: The token-to-text mapping needed to render generated tokens as readable text. Must be the variant matching the model's vocabulary size.
- **Program image**: A compiled program transferred to the board over the serial connection and started from the console. Small and rebuilt often.
- **Storage card**: Removable local storage holding the model and vocabulary artifacts, written by a desktop computer and read by the board without host involvement. Large and rarely changed.
- **Performance report**: The per-token timing breakdown produced by the measurement mode, including total rate and per-category attribution.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can produce a programmable device image for the minimal configuration from a clean checkout using a single documented command, in under 10 minutes.
- **SC-002**: The board presents an interactive console prompt within 5 seconds of reset.
- **SC-003**: A memory test covering 100% of usable external RAM reports zero errors on three consecutive runs.
- **SC-004**: The minimal configuration leaves at least 40% of the device's logic capacity and at least 40% of its memory blocks unused.
- **SC-005**: A model data file of at least 1 MB loads from local card storage into working memory, verifies byte-identical, and completes within 60 seconds with no host involvement.
- **SC-005a**: After the model is loaded once, a developer can rebuild the program, transfer it over the serial connection, and restart generation in under 60 seconds without reloading the model.
- **SC-006**: The system generates at least 100 consecutive tokens with no hang, crash, or corrupted output.
- **SC-007**: Generated output is recognisable English prose consistent with the model's training data, as judged by reading it.
- **SC-008**: The system sustains a generation rate of at least 0.5 tokens per second, and the achieved rate is reported.
- **SC-009**: Two runs with identical model, prompt, and seed produce byte-identical output.
- **SC-010**: The per-token timing breakdown accounts for at least 90% of measured time and names the single largest category.
- **SC-011**: The pre-existing full-featured configuration still builds and runs unchanged, confirming no regression.
- **SC-012**: A person other than the implementer can follow the documentation to reach generated text on their own board without further assistance.

## Assumptions

- **Model artifact**: The target is the smallest pre-trained model published by the upstream llama2.c project — approximately 260,000 parameters, roughly 1 MB at full precision. It is obtained ready-made, so no training step is required. This resolves the user's reference to "the 120k model"; a 120,000-parameter variant could not be confirmed to exist upstream, and the smallest published artifact was selected instead.
- **Vocabulary artifact**: This model was trained with a reduced vocabulary and therefore requires its own matching vocabulary file, not the default one shipped for the larger models. Pairing the model with the wrong vocabulary produces readable-looking but wrong output, so the two must be verified as a matched set.
- **Precision**: Weights are used at full precision. Reduced-precision or quantised weights are deliberately excluded from this feature.
- **Processor speed**: The processor runs at its current speed. Raising it is a separate, later change.
- **External RAM capacity**: Approximately 8 MB is available, which comfortably holds the target model, program, working memory, and stack, but rules out substantially larger models.
- **Loading split**: The model is loaded from local card storage; the program is transferred over the serial connection. Both mechanisms already exist in the current design and are reused rather than replaced.
- **Storage cost**: Card storage is driven in software over general-purpose pins rather than by a dedicated hardware block, so retaining it consumes a negligible share of device capacity and does not compete with the headroom this feature is meant to free up.
- **Loading speed**: Because the card protocol is driven in software, its throughput is expected to be well below the card's own capability. The 60-second target in SC-005 is set against an estimate and should be confirmed by measurement early; it is a development-loop convenience, not a functional constraint.
- **Volatility**: Working memory loses its contents on power loss, so the model is loaded once per power cycle. Whether it also survives a processor reset is a property worth exploiting if available, but is not assumed.
- **Model quality expectations**: A model this small produces simple, sometimes repetitive prose. Success is coherent English text, not sophisticated output.
- **Hardware-in-the-loop testing**: Every acceptance scenario in this specification requires a physical board, and cannot be verified in simulation or automated testing alone. See Testing Support below.

## Testing Support Required From the Operator

The user explicitly raised this, and it is a real constraint on how this feature can be delivered. Programming the board, power-cycling it, observing the serial console, and confirming generated output all require physical access to hardware. Automated verification can cover component-level behaviour only.

What can be verified without the board: component-level simulation of hardware modules, host-side builds of both the device image and the programs, resource and capacity reports from the build, and any host-side model conversion tooling.

What requires the operator: programming the board, all boot and console behaviour, memory testing on real hardware, all host-to-board transfers, writing the model to the storage card and fitting it, all model loading from the card, all model generation, and all performance measurement.

The implementation plan MUST therefore split work into host-verifiable tasks and operator-assisted tasks, and each operator-assisted task MUST state the exact commands to run, the expected output, and what to capture and report back. Operator-assisted checkpoints should be batched so that hardware sessions are few and productive rather than frequent and interrupting. Detailed sequencing of this is deferred to the planning and task-breakdown phases, per the user's request.

## Dependencies

- Physical target board, with serial connection and programming access to the host machine.
- A storage card and a means of writing files to it from a desktop computer, plus a card slot or adapter fitted to the board.
- Host toolchain for building device images and compiling programs, already installed and working.
- The model and matching vocabulary artifacts must be downloadable to the host. No model training is required.
- Operator availability for the hardware-in-the-loop checkpoints described above.
- The existing external RAM and serial console capabilities of the current design, which are carried forward unchanged.

## Out of Scope

- The matrix-multiply accelerator itself. This feature establishes the platform and the baseline it will be measured against; the accelerator is separate follow-on work.
- Any increase in processor speed.
- Reduced-precision or quantised weights.
- Models too large to fit in available external RAM.
- Display, audio, keyboard, and wireless capability, all deliberately removed. Local card storage is deliberately retained.
- Any change to the existing full-featured configuration beyond leaving it intact.
- Executing the model directly out of local storage. The model is copied into working memory first and runs from there.
- Writing the model to the card from the board. The card is populated from a desktop computer.
