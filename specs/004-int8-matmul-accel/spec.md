# Feature Specification: int8 MatMul Accelerator

**Feature Branch**: `004-int8-matmul-accel`
**Created**: 2026-08-19
**Status**: Draft
**Input**: User description: "ok let's turn this plan with the int8 support into a spec that we can implement."

## Overview

Add a hardware matrix-multiply accelerator to the minimal SoC built in feature 003, so that
the two operations which dominate language-model inference — the weight matrix multiplies and
the attention computation — run in dedicated hardware instead of on the processor. Weights are
stored at reduced precision (8-bit integer) rather than full precision.

Feature 003 measured exactly where the time goes: matrix multiplies are 61.3% of per-token
time and attention is 27.4%, together 88.7%. Everything in this specification follows from
that measurement rather than from assumption.

**Two outcomes are expected, and they are not equally important.** Throughput improves from
1.38 to roughly 11.7 tokens/second. But reduced precision is chosen mainly for **capacity**:
it raises the largest model that fits in available memory from roughly 1.5 million parameters
to roughly 5.6 million. The throughput difference between full and reduced precision is only
about 11%, because the remaining processor work dominates either way. Anyone expecting a
fourfold speed-up from narrower weights will be disappointed; the gain is in what can be run
at all.

## User Scenarios & Testing *(mandatory)*

Stories are ordered by delivery sequence. Hardware work is layered and each story depends on
the one before, but every story has its own observable pass/fail signal and can be stopped at.
The first story deliberately involves **no hardware at all** — it exists to retire the largest
risk before anything expensive is built.

### User Story 1 - Reduced-precision model runs in software (Priority: P1)

A developer converts the model to 8-bit weights on their host machine, runs it on the existing
board with no new hardware, and reads the generated text to judge whether reduced precision has
damaged output quality. They record the resulting speed as a baseline and keep the host version
as a reference for every later comparison.

**Why this priority**: This retires the feature's single largest risk for the cost of a
software change. Quantization error is proportionally worse on small models, and the current
model is very small. If quality collapses here, the entire feature must change direction — and
finding that out before any hardware exists costs days instead of weeks. It also produces the
exact-match reference that makes every later hardware test conclusive rather than approximate.

**Independent Test**: Convert the model, run it on the board, read the output. No hardware
changes, no simulation.

**Acceptance Scenarios**:

1. **Given** a full-precision model, **When** the developer runs the conversion tool, **Then** a reduced-precision model is produced along with a record of its size and a checksum.
2. **Given** the converted model on the board, **When** generation runs with the same prompt and seed as the full-precision version, **Then** the output is coherent English of comparable quality.
3. **Given** both versions running on the host, **When** their predicted token distributions are compared position by position, **Then** the mean and 99th-percentile divergence and the top-choice agreement rate are recorded — before any hardware is involved.
4. **Given** those figures, **When** they are read against the thresholds in Success Criteria, **Then** the 8-bit go/no-go can be decided without waiting for a board.
5. **Given** a completed run, **When** the developer reads the summary, **Then** the reduced-precision generation rate and model size are reported.
6. **Given** the host reference implementation, **When** it is run on the same inputs, **Then** it produces results that later hardware stages can be compared against exactly.
7. **Given** the recorded divergence figures and the generated text, **When** the developer judges quality, **Then** an explicit go/no-go decision on 8-bit is recorded — and if it is no-go, the feature switches to 16-bit weights before any hardware work begins.

---

### User Story 2 - The accelerator computes correct results in simulation (Priority: P2)

A developer runs a simulation of the accelerator against the host reference and confirms it
produces identical results, with no access to a board.

**Why this priority**: Simulation iterates in seconds where hardware iterates in minutes.
Every arithmetic and control error that can be caught here costs a fraction of what it costs
once a board is in the loop. Integer arithmetic is exactly reproducible, so "identical" here
means bit-for-bit — an unambiguous pass/fail rather than a judgement call.

**Independent Test**: Run the simulation testbench; compare its output against the host
reference for randomly generated inputs.

**Acceptance Scenarios**:

1. **Given** random input vectors and weight matrices, **When** the accelerator's arithmetic unit is simulated, **Then** results are bit-for-bit identical to the host reference across thousands of cases including boundary and sign cases.
2. **Given** matrix shapes matching those the model actually uses, **When** a full multiply is simulated, **Then** the result is bit-for-bit identical to the host reference.
3. **Given** a simulated memory that delivers data in bursts with gaps, **When** a multiply runs, **Then** the arithmetic unit is never starved of data mid-operation.
4. **Given** a completed simulation, **When** throughput is reported, **Then** it is expressed as a fraction of the theoretical memory limit.

---

### User Story 3 - Processor and accelerator share memory fairly (Priority: P3)

A developer simulates the accelerator running at full rate while the processor also requests
memory, and confirms that neither is starved: the processor's worst-case wait stays bounded,
and the accelerator still achieves close to full throughput.

**Why this priority**: This is the integration risk that cannot be discovered later without
being expensive. Both the processor and the accelerator need the same memory. Getting the
sharing policy wrong shows up as either sluggish processor performance — which is invisible
until it silently halves everything else — or an accelerator that never reaches its potential.
Both failure modes are hard to diagnose on hardware and easy to measure in simulation.

**Independent Test**: Run the simulation with a synthetic processor traffic generator at
several intensities; measure both parties' throughput and worst-case latency.

**Acceptance Scenarios**:

1. **Given** no competing processor traffic, **When** the accelerator runs, **Then** it sustains at least 90% of the theoretical memory rate.
2. **Given** the processor requesting memory periodically, **When** the accelerator is running, **Then** the processor's worst-case wait is bounded and known.
3. **Given** heavy processor traffic, **When** the accelerator runs, **Then** its throughput degrades gradually rather than collapsing, and it is never starved indefinitely.
4. **Given** several transfer sizes are tried, **When** results are compared, **Then** the trade-off between memory efficiency and processor waiting time is measured and a size is chosen from evidence.
5. **Given** the existing full-featured build, **When** it is rebuilt, **Then** it still works — the sharing policy change must not break the display-driven configuration that depends on the old policy.

---

### User Story 4 - The accelerator computes correctly on real hardware (Priority: P4)

A developer programs a board containing the accelerator and runs a small standalone test that
computes one matrix multiply and compares it against a result computed by the processor. The
language model is not involved.

**Why this priority**: This is the first time real hardware is exercised, and it changes only
one variable — everything else has already been proven in simulation. Isolating the
accelerator from the model means a failure here is unambiguously the accelerator.

**Independent Test**: Run the standalone test on the board and compare against the
processor-computed reference.

**Acceptance Scenarios**:

1. **Given** a board programmed with the accelerator, **When** the standalone test runs, **Then** the result matches the processor-computed reference exactly.
2. **Given** a completed operation, **When** the developer reads the performance counters, **Then** achieved throughput and time spent waiting for memory are both reported.
3. **Given** a build containing the accelerator, **When** resource usage and timing are read, **Then** the design fits with margin and meets its timing target.
4. **Given** the existing full-featured build, **When** it is rebuilt, **Then** it still succeeds unchanged.

---

### User Story 5 - Weight multiplies run on the accelerator (Priority: P5)

A developer replaces the processor's matrix-multiply routine with a call to the accelerator and
generates text. Attention still runs on the processor.

**Why this priority**: The first end-to-end benefit, and the point at which the accelerator
demonstrably does useful work. It is separated from attention so that only one thing changes
at a time.

**Independent Test**: Generate text with the same prompt and seed as the software-only
reduced-precision run and compare the output.

**Acceptance Scenarios**:

1. **Given** the same model, prompt and seed, **When** generation runs with weight multiplies accelerated, **Then** the output is byte-identical to the software-only reduced-precision run.
2. **Given** a completed run, **When** the rate is compared to the software-only baseline, **Then** it shows a substantial improvement consistent with accelerating roughly three-fifths of the work.
3. **Given** a completed run, **When** the timing breakdown is re-measured, **Then** the matrix-multiply share has collapsed and attention has become the largest remaining category.
4. **Given** a disappointing speed-up, **When** the performance counters are read, **Then** they distinguish a memory-bandwidth limitation from a control-logic limitation.

---

### User Story 6 - Attention runs on the accelerator (Priority: P6)

A developer moves the attention computation onto the accelerator as well, and generates text at
the feature's full target rate.

**Why this priority**: This is where the feature's value is actually realised. Feature 003
measured attention at 27.4% — accelerating only the weight multiplies caps the end-to-end gain
at roughly 2.5x, while covering attention as well reaches roughly 8.5x. Leaving this out would
make the whole effort a poor return.

**Independent Test**: Generate text and compare both output and rate against the previous
story.

**Acceptance Scenarios**:

1. **Given** the same model, prompt and seed, **When** generation runs with attention accelerated, **Then** the output is byte-identical to the software-only reduced-precision run.
2. **Given** a completed run, **When** the rate is measured, **Then** it meets the feature's target.
3. **Given** a completed run, **When** the timing breakdown is re-measured, **Then** the remaining processor work is the dominant category and is quantified for future work.
4. **Given** attention's memory access pattern, **When** its efficiency is measured, **Then** any waste is quantified so a decision about optimising it rests on evidence.

---

### Edge Cases

- **Quantization damages a small model**: reduced precision may degrade a very small model more than a large one. This is the primary risk; User Story 1 detects it before any hardware is built, and the response is the 16-bit fallback in FR-004a. Note that the fallback changes the arithmetic from integer to floating point, which also changes how exact-match verification must be defined — so taking it late would be far more disruptive than taking it at the end of User Story 1.
- **Memory starvation in either direction**: the processor waiting too long behind accelerator transfers, or the accelerator never getting a turn during processor-heavy phases. Both must be bounded, and the bounds measured rather than assumed.
- **Existing configuration regresses**: the memory-sharing policy that this feature changes was chosen deliberately for the display-driven configuration, where starving the display causes visible corruption. That configuration must keep working.
- **Accelerator hangs or never signals completion**: the processor must not wait forever. There must be a way to abort and recover.
- **Requested dimensions exceed what the accelerator supports**: must be rejected clearly rather than silently producing wrong results.
- **Results read before they are ready**: reading output while an operation is in progress must not return partially written data.
- **Stale results after a model change**: if a new model is loaded without resetting the accelerator, previously computed values must not be mistaken for current ones.
- **Arithmetic saturation**: accumulating many products can exceed the accumulator's range; behaviour must be defined and match the reference exactly.

## Requirements *(mandatory)*

### Functional Requirements

**Reduced-precision model support**

- **FR-001**: The project MUST provide a host tool that converts a full-precision model to reduced precision, reporting the output size and a checksum.
- **FR-002**: The system MUST run the reduced-precision model on the existing hardware with no accelerator present, so quantization can be evaluated independently.
- **FR-003**: The project MUST provide a host reference implementation whose results later hardware stages can be compared against exactly.
- **FR-004**: The system MUST report the divergence between reduced- and full-precision output quantitatively, not only as a subjective judgement. The measure MUST be the Kullback-Leibler divergence between the two models' predicted token distributions at matched positions, reported as mean and 99th percentile over a run, alongside the rate at which both models agree on the most likely token.
- **FR-004c**: The divergence measurement MUST be performed on the host, before any hardware run. Both models' predicted distributions are obtainable there, so the quantization verdict does not depend on board availability and is not delayed behind it.
- **FR-004a**: If 8-bit output quality proves unacceptable, the project MUST switch to 16-bit floating-point weights rather than accepting the degradation or changing model. This decision MUST be taken at the end of User Story 1, before any accelerator hardware is built.
- **FR-004b**: The quality decision MUST be made from recorded evidence — the generated text alongside the measured divergence from full precision — and the decision and its basis MUST be written down, so a later reader can tell whether the fallback was taken and why.

**Accelerator function**

- **FR-005**: The accelerator MUST compute the matrix-vector products used by the model, for the matrix shapes the model actually uses.
- **FR-006**: The accelerator MUST compute the attention score and weighted-sum operations.
- **FR-007**: Accelerator results MUST be bit-for-bit identical to the host reference for the same inputs.
- **FR-008**: The accelerator MUST report achieved throughput and time spent waiting for memory, so a shortfall can be attributed to its cause.
- **FR-009**: The accelerator MUST reject requests whose dimensions exceed what it supports, rather than producing incorrect results.
- **FR-010**: The accelerator MUST support being aborted and returned to a known idle state.
- **FR-011**: The design MUST be parameterised by element width and number of parallel arithmetic units, so the 16-bit fallback can be adopted without redesign. This requirement is load-bearing: it is what makes FR-004a affordable rather than a restart, and it MUST be honoured even if the fallback is never taken.
- **FR-011a**: If the 16-bit fallback is taken, the project MUST supply a host reference implementation for that format, since no established one exists. This is additional scope that the 8-bit path does not carry, and it MUST be accounted for before the switch is made.

**Processor interface**

- **FR-012**: The processor MUST be able to describe an operation, start it, and determine when it has completed.
- **FR-013**: The processor MUST be able to queue more than one operation, so it can do other work rather than waiting.
- **FR-014**: Reading results MUST NOT be possible while they are still being written, or must be clearly signalled as not ready.
- **FR-015**: Waiting for completion MUST NOT itself generate significant memory traffic, since that would compete with the transfer being waited on.

**Memory sharing**

- **FR-016**: Processor and accelerator MUST share memory such that the processor's worst-case wait is bounded and documented.
- **FR-017**: The accelerator MUST NOT be starved indefinitely by sustained processor traffic.
- **FR-018**: With no competing traffic, the accelerator MUST achieve at least 90% of the theoretical memory rate.
- **FR-019**: Accelerator memory traffic MUST bypass the processor's cache, since weights are read once and would otherwise evict the processor's working set on every operation.
- **FR-020**: The transfer size that governs the efficiency-versus-latency trade-off MUST be adjustable and chosen from measurement.
- **FR-021**: The existing display-driven configuration MUST continue to work, including its own memory-sharing needs.

**Verification**

- **FR-022**: Each delivery stage MUST have a pass/fail criterion that can be evaluated before the next stage begins.
- **FR-023**: Arithmetic correctness MUST be verifiable in simulation, without a board.
- **FR-024**: Memory-sharing fairness MUST be measurable in simulation under synthetic processor load, before hardware.
- **FR-025**: The project MUST document what was measured at each stage, replacing estimates with measurements as they are obtained.

### Key Entities

- **Reduced-precision model**: The converted weights plus the scaling information needed to reconstruct their values. Larger in parameter count but smaller in bytes than the full-precision original.
- **Host reference implementation**: A version of the computation running on a desktop, used as the definition of correct results for every hardware comparison.
- **Operation descriptor**: A description of one unit of work — where the weights are, where the input is, where results go, the dimensions involved, and which mode of operation.
- **Performance counters**: Per-operation measurements of throughput and memory waiting time, readable by the processor.
- **Memory sharing policy**: The rules determining which party gets memory access when both want it, including the transfer size and the guarantee that prevents either from being starved.
- **Timing breakdown**: The per-category measurement of where token time goes, re-measured at each stage to confirm the expected category has shrunk.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can convert a model to reduced precision and run it on existing hardware without any hardware changes.
- **SC-002**: Reduced-precision output is coherent English of comparable quality to full precision, and the divergence from the full-precision model is measured: mean divergence below 0.01 nats and top-choice agreement above 95% over at least 200 token positions. These thresholds are guides drawn from published work on much larger models — the measured values MUST be recorded regardless, and a reading of the generated text remains the final judgement (see Assumptions).
- **SC-003**: Reduced-precision model size is at most one third of the full-precision original with 8-bit weights, or at most one half if the 16-bit fallback is taken. **MEASURED (T009, 2026-08-20): 299,008 B versus 1,056,540 B — a ratio of 0.283.** PASS. The ratio is above the naive 0.25 because Q8_0 stores one fp32 scale per group of 64, costing 1.0625 B per weight rather than 1.0, and because the norm weights stay fp32.
- **SC-004**: The largest model that fits in available memory increases by at least a factor of three with 8-bit weights, or at least a factor of 1.9 if the 16-bit fallback is taken. **The capacity gain is roughly halved by the fallback** — this is its main cost and is the reason the 8-bit path is preferred where quality allows. **MEASURED (2026-08-20): 3.76x.** In the 2 MB weight region, fp32 holds ~524,000 parameters and Q8_0 ~1,974,000. PASS. The 8-bit path was taken (T014), so the fallback figure does not apply. Note that region size, not physical memory, is what caps this (research R5).
- **SC-005**: Accelerator results are bit-for-bit identical to the host reference across at least a thousand randomised simulation cases.
- **SC-006**: With no competing traffic, the accelerator sustains at least 90% of the theoretical memory rate. **MEASURED (T045, research R19): 91.3% at BURST_LEN=128.** PASS. 64-word bursts reach only 85.7% and would have failed this criterion — the burst length was chosen from this measurement, not from the design document's estimate, which was wrong (it assumed ~6 cycles of overhead per burst against a real 9.5-14 including tRP recovery and row crossings).
- **SC-007**: With the processor also requesting memory, its worst-case wait is bounded, documented, and no worse than the chosen transfer size implies.
- **SC-008**: Under sustained processor traffic, accelerator throughput degrades gradually and never reaches zero.
- **SC-009**: Generated text with weight multiplies accelerated is byte-identical to the software-only reduced-precision run.
- **SC-010**: Generated text with attention also accelerated is byte-identical to the software-only reduced-precision run.
- **SC-011**: Generation rate reaches at least 8 tokens per second, against the 1.38 measured in feature 003.
- **SC-012**: The final timing breakdown shows the accelerated categories reduced to under 15% of per-token time.
- **SC-013**: The design fits with at least 25% of logic capacity unused and meets its timing target. **MEASURED (T050, research R22): LUT4 13,183/24,288 = 54% used, 46% free — PASS. Timing 26.21 MHz against a 25 MHz target — PASS, but by only 4.8%.** The letter of this criterion is met and its spirit is not: this project rejected a 256-entry cache at 28.4 MHz against the same target, and later traced UART flakiness to that class of margin. BRAM at 87% and multipliers at 89% are also close to the ceiling. R22 records the cause — `acc_mac`'s single-cycle fp32 rescale — and the fix.
- **SC-014**: The existing full-featured configuration still builds and runs unchanged.
- **SC-015**: A developer can determine from the reported counters whether a throughput shortfall is caused by memory bandwidth or by control logic.

## Assumptions

- **Precision choice**: 8-bit integer weights with per-group scaling, matching the format used by the established upstream reference. Chosen for capacity and for having a tested reference implementation, not primarily for speed — see the Overview.
- **Quantization risk is real and unquantified**: quantization error is proportionally worse on small models, and the current model is very small. User Story 1 exists specifically to measure this before any hardware is committed.
- **Divergence thresholds are guides, not verdicts.** The 0.01-nat and 95%-agreement figures in SC-002 come from quantization work on models orders of magnitude larger than this one. On a 260K-parameter model with dim=64 they may prove too lenient or too strict. The measured values MUST be recorded and used to inform the decision; the developer's reading of the generated text is the final call, and the basis MUST be written down either way (FR-004b).
- **Fallback is 16-bit floating point, decided before hardware.** If 8-bit output is unacceptable, the project switches to 16-bit rather than accepting degraded output or introducing a model-sourcing dependency. The costs are explicit and accepted: roughly half the capacity gain (about 3.0M parameters rather than 5.6M), floating-point rather than integer arithmetic hardware, and a host reference implementation that must be written because none exists upstream. Throughput is barely affected either way — about 11.3 versus 11.7 tokens per second — because the remaining processor work dominates.
- **Group size defaults to 64**, read from the checkpoint header rather than fixed. `export.py` halves it if a dimension does not divide evenly; every quantized tensor in the current model is a multiple of 64, so no backoff is expected. A backoff would change the storage ratio and the accelerator's lane framing, so it must be recorded if it occurs.
- **Bit-exact verification survives the fallback, but differently.** With 8-bit integer weights, accumulation is exactly reproducible and hardware can be compared bit-for-bit against the reference with no ambiguity. With 16-bit floating point, matching exactly requires the hardware and the reference to agree on rounding and accumulation order. That is achievable but must be specified deliberately rather than assumed, and it is a real reason to prefer the 8-bit path.
- **Expected gain**: roughly 8.5x end-to-end, from feature 003's measurement that 88.7% of per-token time is accelerable. Accelerating only the weight multiplies would cap this near 2.5x, which is why attention is in scope.
- **The remaining processor work becomes dominant**: after this feature, roughly 86% of token time is work this accelerator does not touch. That is expected and quantified, not a failure. Addressing it is separate, later work.
- **Reuse**: feature 003 established that the existing memory controller's second access port is general-purpose and already proven in hardware, and that the display path is already absent from the minimal configuration. Substantial reuse is expected rather than a from-scratch memory interface.
- **Results stay on-chip**: outputs are small enough that they need not be written back to main memory, which avoids both a write path and any question of stale cached copies.
- **Processor speed is unchanged**: raising the clock is a known, attractive follow-on but is deliberately excluded here so that this feature's effect can be measured in isolation.
- **Hardware-in-the-loop testing**: as in feature 003, the operator must program the board and observe results; simulation covers arithmetic and sharing behaviour only.

## Testing Support Required From the Operator

As in feature 003, several stages need a physical board and cannot be closed out from the host
alone.

**Verifiable without hardware**: model conversion, host reference results, all arithmetic
correctness in simulation, all memory-sharing behaviour in simulation, resource and timing
reports from the build.

**Requires the operator**: programming the board, the standalone hardware test, all generation
runs, all performance-counter readings, and every rate measurement.

Operator-assisted work MUST be batched into as few sessions as practical, and each such step
MUST state the exact commands, the expected output, and what to record. Detailed sequencing is
deferred to planning and task breakdown.

## Dependencies

- The minimal configuration, working model pipeline, and timing measurement from feature 003.
- A physical board with the same storage and serial arrangement as feature 003.
- Simulation tooling already used in this project for hardware testbenches.
- An established reference implementation of the reduced-precision format, and a way to convert
  the model to it.
- Operator availability for the hardware stages.

## Out of Scope

- **Raising the processor clock.** Attractive and quantified as a follow-on, but excluded so
  this feature's contribution can be measured on its own.
- **Optimising the remaining processor work.** It becomes dominant after this feature, and
  that is the natural next project.
- **Obtaining or training a larger model.** The capacity this feature unlocks is the point, but
  actually exploiting it is separate work with its own risks.
- **More parallel arithmetic units than memory bandwidth can feed.** Feature 003 established
  that throughput is limited by memory, not arithmetic; adding units without adding bandwidth
  produces idle hardware.
- **Writing results back to main memory.** Outputs are small and stay on-chip.
- **Supporting precisions other than the chosen one**, beyond keeping the design parameterised
  so another could be adopted later.
- **Any change to the display, audio, or other peripherals** removed in feature 003.
