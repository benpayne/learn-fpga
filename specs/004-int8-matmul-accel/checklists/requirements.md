# Specification Quality Checklist: int8 MatMul Accelerator

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-19
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

**Iteration 2 — 2026-08-19 — all 16 items pass. Spec is ready for planning.**

Iteration 1's two failures both stemmed from one unresolved decision: what to do if 8-bit
quantization degrades this very small model too much. Resolved — the fallback is 16-bit
floating point, decided at the end of User Story 1 before any hardware is built.

Resolving it surfaced a consistency problem that had to be fixed rather than left:

- **SC-003 and SC-004 were written assuming 8-bit and would have been unachievable under the
  fallback.** 8-bit gives roughly a 3.5x capacity gain; 16-bit gives roughly 2x. Both criteria
  now state a threshold for each path, and SC-004 says plainly that the fallback roughly halves
  the capacity gain — which is its main cost and the reason 8-bit is preferred where quality
  allows.
- **FR-011a added**: the 16-bit path needs a host reference implementation that does not exist
  upstream and would have to be written. That is real additional scope carried only by the
  fallback, and it should be visible before the switch is made rather than discovered after.
- **A verification consequence was recorded in Assumptions**: integer accumulation is exactly
  reproducible, so 8-bit hardware can be compared bit-for-bit with no ambiguity. Matching
  16-bit floating point exactly requires hardware and reference to agree on rounding and
  accumulation order — achievable, but it must be specified deliberately. This is a further
  reason to prefer 8-bit, and a reason the fallback must be taken early if at all.
- **FR-011 strengthened** and marked load-bearing: parameterising the design by element width
  is what makes the fallback affordable rather than a restart, so it must be honoured even if
  the fallback is never used.
- **FR-004b added**: the quality decision must be recorded with its evidence, so a later reader
  can tell whether the fallback was taken and why.

**Iteration 3 — 2026-08-20 — still 16/16. Divergence measurement made concrete.**

FR-004 required the reduced-versus-full-precision divergence to be "quantified, not merely
judged by eye", but named no instrument, and SC-002 set no threshold. The task that judged
quality was therefore going to be someone reading two paragraphs and forming an opinion — for a
decision that gates every subsequent task in the feature.

Now specified as **KL divergence between the two models' predicted token distributions**, with
mean, 99th percentile, and top-1 agreement over at least 200 positions. SC-002 carries
thresholds (mean KL < 0.01 nats, top-1 agreement > 95%).

The more consequential change is *when*: FR-004c requires the measurement on the host, before
any hardware run. Both models' distributions are obtainable there, so the go/no-go no longer
waits on a board — a no-go answer costs minutes instead of a build-flash-upload cycle. The
decision gate moved from the middle of the hardware session to the host-side work that precedes
it, and the board run became confirmation.

An assumption was added recording that the thresholds come from published work on far larger
models and may not transfer to a 260K-parameter model with dim=64. The measured values must be
recorded regardless, and the developer's reading of the text remains the final call.

**Deliberate interpretation on "no implementation details".** The specification uses
capability-level language throughout — "the accelerator", "reduced precision", "memory sharing
policy" — rather than naming modules, signals, or register layouts. Those live in
`FemtoRV/RTL/ACCEL/DESIGN.md`, which this spec deliberately does not duplicate. Quantitative
targets are stated as outcomes, not mechanisms.

**Note on story independence.** As in feature 003, hardware work is layered and the six stories
are dependency-ordered rather than independently deliverable. Each still has its own observable
pass/fail signal, and the ordering is deliberate: User Story 1 involves no hardware at all and
exists to retire the feature's largest risk before anything expensive is built.
