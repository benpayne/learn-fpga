<!--
SYNC IMPACT REPORT
==================
Version change: (none) → 1.0.0
Rationale: Initial ratification. No prior constitution existed; MAJOR version
established as the baseline governance document.

Modified principles: none (initial adoption)

Added sections:
  - Core Principles I-VI
  - Hardware Design Standards
  - Development Workflow and Quality Gates
  - Governance

Removed sections: none

Principles derived from:
  - Explicit user direction: cocotb-based verification, simulate-before-hardware,
    bottom-up test composition, Verilog/HW focus
  - Observed practice in features 003 and 004, where each principle either
    demonstrably paid off or its absence caused a real defect

Templates requiring updates:
  ✅ .specify/templates/plan-template.md   — Constitution Check gate now has gates to evaluate
  ✅ .specify/templates/spec-template.md   — no change needed; principles are process, not scope
  ✅ .specify/templates/tasks-template.md  — no change needed; Principle III maps to existing phases
  ⚠  specs/004-int8-matmul-accel/plan.md   — its Constitution Check says "no constitution exists";
     re-evaluate against this document before /speckit.tasks

Follow-up TODOs: none. All placeholders resolved.
-->

# learn-fpga (FemtoRV) Constitution

This project builds hardware. Hardware fails differently from software: a defect can be
invisible until it corrupts data hours later, a fix costs minutes of synthesis rather than
seconds of compilation, and the only debugging instrument may be a serial console. These
principles exist because that asymmetry makes discipline cheaper than debugging.

## Core Principles

### I. Simulate Before Hardware (NON-NEGOTIABLE)

RTL MUST pass simulation before it is synthesized onto a board. A change that has never been
simulated MUST NOT be programmed into hardware, however small it appears.

Simulation iterates in seconds; hardware iterates in minutes and can only be observed through
whatever output the design already supports. Every defect caught in simulation is caught with
full internal visibility and no board time.

Passing simulation is necessary but not sufficient. A module MUST also be confirmed to
**synthesize** — a standalone synthesis run against that module's own top, without full board
place-and-route — before its implementation is considered complete. Simulation proves a module's
logic is correct; it says nothing about whether the tool can produce gates from that logic, and
a module that cannot be synthesized has not satisfied "simulate before hardware". It has
satisfied a check that hardware was never going to reach.

Exception: changes that cannot be simulated at all — pin constraints, physical wiring — are
exempt, but MUST be isolated into their own change so that a hardware failure has exactly one
candidate cause.

### II. Cocotb Is the Verification Record

Every RTL module MUST have a cocotb testbench under `FemtoRV/TEST/`, runnable from the host
with no board attached. A module without a passing testbench is not complete, regardless of
whether it appears to work on hardware.

Testbenches MUST be registered in `TEST/Makefile` so they are runnable by name. A test that
only exists in someone's shell history is not a test.

Working on hardware is not evidence of correctness — it is evidence of not having hit the
failing case yet.

### III. Bottom-Up Verification: Unit, Then Subsystem, Then Integrated

Verification MUST proceed from the smallest testable piece upward. Each level MUST have its own
pass/fail criterion, evaluated before the next level begins:

1. **Unit** — one module against a reference, in simulation.
2. **Subsystem** — modules composed, still in simulation, with realistic stimulus.
3. **Hardware, isolated** — on the board, exercising the new logic alone, with everything else
   held constant.
4. **Hardware, integrated** — in the real system.

Each step MUST change exactly one variable relative to the step before. When step 4 fails and
steps 1-3 passed, the fault is in integration, and that is a far smaller search space than
"somewhere in the design".

Random sampling MUST NOT be relied upon as the sole verification method for logic whose known
failure modes concentrate on rare boundary conditions. Where such a boundary is identifiable —
by inspecting the algorithm's own branch conditions — verification MUST include a
**deterministic, enumerated sweep** of that boundary space in addition to any random vectors,
however many.

A large sample count is not evidence of coverage for a defect class it is structurally unlikely
to reach. Both of this project's floating-point rounding defects survived a thousand random
vectors each; a subsequent two million *targeted* random trials reached the failing region zero
times, and 540 enumerated cases covered it completely.

### IV. A Golden Reference Precedes Hardware

Any computation implemented in hardware MUST have a host-side reference implementation, and
hardware results MUST be compared against it.

Where the arithmetic permits, the comparison MUST be **bit-exact**. Integer datapaths make this
free and unambiguous. Floating-point datapaths MUST specify rounding and accumulation order
deliberately if bit-exactness is claimed, or state explicitly what weaker criterion is used and
why.

Rationale, from experience: in feature 003 the inference port was validated on the host against
the real model before it ever ran on the FPGA. When the board then misbehaved, correctness of
the mathematics was already established, so the search narrowed immediately to loading and
memory. That single decision converted an open-ended debugging problem into a bounded one.

### V. Profiles Are Additive; Shared RTL Demands Regression

New build configurations MUST be added alongside existing ones, never by editing a working
configuration in place. Both MUST remain buildable from the same checkout.

When a change touches RTL shared by more than one configuration, **every** affected
configuration MUST be rebuilt and verified before the change is considered complete. The
regression is mandatory, not a formality.

Before adding a second consumer of any shared, mutable resource — an output filename, a build
directory, a generated config file — the existing single-consumer assumption MUST be found and
removed first. Such collisions fail **silently**: the wrong bitstream flashed under a name that
does not identify it, a testbench exercising another module's design, firmware built for the
other profile. Nothing errors, and the result looks like a hardware fault rather than a build
accident.

Rationale: a working bitstream is a valuable, hard-won artifact. Editing it in place to try
something new destroys the only known-good reference at exactly the moment it is most needed
for comparison — and so does quietly overwriting it from a second consumer that believed it
owned the name.

### VI. Measurements Replace Estimates

Performance and resource claims in documentation MUST state whether each number is measured,
simulated, or estimated. Estimates MUST be marked as such and MUST be replaced with measurements
once available.

Where a tool reports the same quantity at several stages, the claim MUST identify **which stage**
it comes from, and MUST use the final one. A place-and-route tool that prints an estimated
frequency after placement and the real one after routing offers two numbers under one name; only
the second describes the design.

A documented estimate that has silently become the record of truth is worse than no number at
all, because it will be trusted.

Where a specification sets a numeric target derived from an estimate, the task that measures
the real value MUST also update the specification.

## Hardware Design Standards

These are the Verilog patterns this project holds to. Deviations MUST be justified in the
design or plan document, not decided silently in the RTL.

**Synchronous design**
- Single clock domain per module. Crossings MUST be explicit, documented, and synchronized.
- All flip-flops MUST have a defined reset. Reset polarity MUST be consistent within a module.
- No inferred latches. Every `always` block that assigns a signal MUST assign it on all paths.

**Portability and inference**
- Prefer behavioural descriptions the synthesis tool can infer over hand-instantiated vendor
  primitives. Memories and arithmetic SHOULD be written so yosys infers BRAM and DSP blocks.
- Hand-instantiate a primitive only when inference has been tried and demonstrably fails, and
  record why.

**Parameterisation**
- Sizes, widths, depths and counts MUST be parameters, not literals scattered through the code.
- Where a design decision may plausibly be revisited — data width, burst length, lane count —
  it MUST be a parameter from the outset. Retrofitting parameterisation is a rewrite.

**Conditional inclusion**
- Peripheral instantiation MUST be guarded by the same `` `ifdef `` that controls the
  peripheral's presence. An unguarded include forces every configuration to carry the
  dependency, whether it uses the device or not.

**Timing**
- Maximum frequency MUST be recorded for each build. A change that reduces timing margin MUST
  be justified.
- Designs MUST meet timing with margin, not merely pass.

**Interfaces**
- Module interfaces MUST be documented at the port list: direction, width, and meaning.
- Handshakes MUST define behaviour when the consumer is not ready.
- A module that can stall or fail MUST expose that state to software. Hardware whose behaviour
  cannot be observed from the CPU cannot be diagnosed on a board.

## Development Workflow and Quality Gates

**Before writing RTL**
- The interface MUST be specified before the implementation, so that testbench and RTL can be
  written against the same contract.
- Where a reference implementation is required by Principle IV, it MUST exist first.

**Before synthesizing**
- Unit and subsystem simulations MUST pass (Principles I-III).
- New testbenches MUST be registered in `TEST/Makefile`.

**Before programming a board**
- Synthesis MUST complete without errors, and resource and timing figures MUST be recorded.
- Every configuration sharing the changed RTL MUST still build (Principle V).

**Hardware sessions**
- Hardware work MUST be batched. Each hardware task MUST state its exact command, expected
  output, and what to record, so a session can be executed without re-derivation.
- Results MUST be written back into the specification or research document, replacing estimates
  (Principle VI).

**Definition of done**
A change is complete when: simulation passes, hardware behaviour is verified against the
reference, every affected configuration still builds, measurements have replaced estimates in
the documentation, and the testbench is committed alongside the RTL.

## Governance

This constitution takes precedence over convenience and over habit. Where a principle makes a
task slower, that cost has already been weighed against the debugging it prevents.

**Amendment procedure**
- Amendments MUST be proposed as a change to this file with an updated Sync Impact Report.
- The rationale MUST state what experience motivated the change. Principles derived from a real
  defect or a real success are durable; principles adopted on speculation are not.
- Dependent templates and in-flight plans MUST be reviewed for consistency in the same change.

**Versioning**
- MAJOR — a principle is removed or redefined in a backward-incompatible way.
- MINOR — a principle or section is added, or guidance is materially expanded.
- PATCH — clarification, wording, or a non-semantic refinement.

**Compliance**
- Every feature plan MUST evaluate its Constitution Check gate against this document and record
  the result, including when it passes.
- A justified deviation MUST be recorded in the plan's Complexity Tracking with the simpler
  alternative that was rejected and why. An unrecorded deviation is a defect in the plan.
- `CLAUDE.md` carries runtime development guidance and MUST remain consistent with these
  principles.

**Version**: 1.1.0 | **Ratified**: 2026-08-20 | **Last Amended**: 2026-08-21
