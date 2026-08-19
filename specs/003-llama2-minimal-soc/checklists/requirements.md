# Specification Quality Checklist: Minimal RISC-V SoC for llama2.c

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-18
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

**Iteration 2 — 2026-08-18 — all 16 items pass. Spec is ready for planning.**

Iteration 1 had two failures, both traceable to a single unresolved marker in FR-018 (the
exact model artifact). The user selected the smallest pre-trained model published upstream
(~260K parameters, ~1 MB at full precision), which resolved both:

- *No [NEEDS CLARIFICATION] markers remain* — now PASSES; zero markers in the spec.
- *All functional requirements have clear acceptance criteria* — now PASSES; FR-018 states a
  concrete size and precision, and is covered by SC-005 through SC-009.

Resolving this surfaced one additional requirement worth recording. The selected model was
trained with a reduced vocabulary and needs its own matching vocabulary file rather than the
default one used by the larger models. A mismatched pair produces plausible-looking but wrong
text, which is a failure mode that could easily be misdiagnosed as a numerical or memory bug.
FR-018a and a new assumption were added to make the pairing an explicit, checked requirement.

**Iteration 3 — 2026-08-18 — re-validated after the loading-path change. All 16 items still pass.**

The original spec routed both the model and the program over the serial connection. At roughly
1 MB, the model takes close to two minutes that way, and because working memory is volatile
that cost was being paid on every reset rather than once. The spec now splits loading by how
often each artifact changes: the model is read from local card storage with no host
involvement, and the program continues to arrive over the serial connection because it is
small and is rebuilt constantly.

This reverses the earlier decision to strip local storage. That decision was based on freeing
capacity, but card access here is driven in software over general-purpose pins rather than by
a dedicated hardware block, so retaining it costs almost nothing against the headroom targets
in SC-004. FR-003 was narrowed and FR-003a added to make the reasoning explicit rather than
leaving the reversal looking arbitrary.

Changes: Overview, User Story 1, User Story 3 (rewritten), FR-003/003a, FR-010/010a/010b,
FR-011, FR-012/012a, SC-005/005a, four new edge cases covering card failure modes, a new
Storage Card entity, Dependencies, Assumptions, Testing Support, and Out of Scope.

One assumption is explicitly flagged as unverified: the 60-second target in SC-005 is set
against an estimate of software-driven card throughput, not a measurement. It should be
confirmed early, and it is a development-loop convenience rather than a functional constraint,
so it can move without affecting the feature.

**Deliberate interpretation on "no implementation details".** The specification body
consistently uses capability-level language ("language model program", "external RAM",
"serial console") rather than naming modules, file formats, or transfer protocols. Domain
terms that define the scope itself — the processor architecture and the workload — appear
only in the title and the quoted user input, where they identify *what* is being built
rather than *how*. Marked as passing on that basis.

**Note on story independence.** The template asks for independently deliverable slices.
Hardware bring-up is strictly layered, so the five stories are dependency-ordered instead,
and the spec says so explicitly. Each story still has its own observable pass/fail signal on
the board, which preserves the intent of independent testability.
