# Phase 0 Research: int8 MatMul Accelerator

**Branch**: `004-int8-matmul-accel` | **Date**: 2026-08-20

Findings are marked **VERIFIED** (checked against source or measured), **MEASURED** (from
feature 003 hardware runs), or **MEASURE** (an estimate that must be replaced).

The architectural reasoning lives in `FemtoRV/RTL/ACCEL/DESIGN.md` and is not repeated here.
This document records what changed after checking assumptions against the actual sources.

---

## R1. Q8_0 format — VERIFIED against upstream `runq.c`, and it differs from the design's assumption

The design assumed Q8_0 interleaves 32 int8 weights with one fp32 scale, giving a 9-word
framing overhead. **That is wrong.** Reading `runq.c`:

```c
typedef struct {
    int8_t* q;    // quantized values
    float*  s;    // scaling factors
} QuantizedTensor;

res[i].q = (int8_t*)p;  p = (int8_t*)p + size_each;
res[i].s = (float*)p;   p = (float*)p  + size_each / GS;
```

**Weights and scales are stored as separate contiguous blocks**, not interleaved: the whole
int8 array first, then the whole scale array.

**This is better for the accelerator, and it changes the datapath.**

- The weight `q` stream is dense int8 — **exactly 4 weights per 32-bit word within the block, no
  interleaved framing**, so the inner loop runs the lanes at full rate. Averaged over the small
  separate scale block the effective figure is 3.76 weights/word at the default GS=64, versus
  the 3.56 the design assumed from an interleaved GS=32 layout.
- Scales are a second, much smaller stream: `size/GS` floats. At the default GS=64, a 64x64
  matrix has 64 scales = 256 bytes, about 1.5% of the data.

**Precision correction (confirmed against upstream `init_quantized_tensors`)**: the q-then-s
split is **per tensor**, not per file. For the multi-layer arrays (wq/wk/wv/wo/w1/w2/w3) the
layout is layer0.q, layer0.s, layer1.q, layer1.s, ... — NOT every layer's q followed by every
layer's s. The original wording here ("all int8 values for a tensor come first, followed by all
scale factors") was true but easy to over-generalise to the whole file, which would misparse it.

This does not change the accelerator design: it operates on one matrix at a time and receives
`w_q_base` and `w_s_base` as separate descriptor fields, so per-tensor separation is exactly
what it wants. It does matter for the loader and the host tools.

Order within the file: the three RMSNorm tensors (rms_att, rms_ffn, rms_final) come first as
plain fp32 and are **not quantized**; `wcls` appears only when `shared_classifier == 0`.

**Decision**: **prefetch the scale block into BRAM at the start of each operation**, then stream
int8 weights as one dense burst sequence. This gives a clean single-stream inner loop at 4
MACs/cycle, with a short setup transfer beforehand. It also avoids needing two concurrent read
streams into the same burst port.

**Alternatives considered**: interleaving two burst streams (more control logic, no benefit
since scales are tiny); fetching each scale on demand (breaks the dense burst pattern and
would cost far more than prefetching them all).

## R2. The activation vector is ALSO quantized — VERIFIED

This was not in the design and it matters:

```c
for (int k = 0; k < GS; k++)
    ival += ((int32_t) x->q[j + k]) * ((int32_t) w->q[in + j + k]);
val += ((float) ival) * w->s[(in + j) / GS] * x->s[j / GS];
```

`x` is a `QuantizedTensor` too. `runq.c` calls `quantize(&s->xq, x, dim)` before each matmul.

**Consequences**:

1. The MAC is **int8 x int8 -> int32**, with both operands quantized. Simple, exact, and
   integer throughout — which is what makes bit-exact verification straightforward.
2. The scale applied per group is the **product of two scales**, `w->s * x->s`. The
   accelerator needs both, or needs the CPU to pre-multiply them.
3. **The CPU must quantize the activation vector before each operation.** That is new scalar
   work this feature adds — small (dim=64 or hidden=172 elements, involving a max-abs pass and
   a divide per element) but non-zero, and it lands in the scalar remainder that already
   dominates. **MEASURE this in User Story 1**; if it is significant, quantizing `x` in
   hardware becomes worth considering.

**Decision**: stage 1 has the CPU quantize `x` and pass `x->q` plus `x->s` to the accelerator,
matching `runq.c` exactly so results can be compared bit-for-bit. Revisit only if measurement
justifies it.

## R3. Group size is a file parameter, not a constant — VERIFIED

`GS` is read from the checkpoint header (`fread(&group_size, ...)`), not fixed. The accelerator
must treat it as a runtime value, not a synthesis constant. It bounds the int32 accumulator's
range before each rescale, so it also affects saturation behaviour (see R9).

**VERIFIED default: 64.** `export.py` declares `def version2_export(model, filepath,
group_size=64)` and backs off by halving while `dim % group_size != 0`. Checked against this
model's tensor sizes — token embedding 32768, wq/wo 4096, wk/wv 2048, w1/w2/w3 11008 — all
multiples of 64, so **no backoff is expected and GS should be 64**.

That gives `(64 + 4) / 64 = 1.0625` bytes per weight, **26.6% of fp32**, and 3.76 weights per
32-bit word once the separate scale block is amortised in.

**Decision**: `GS` is an operation-descriptor field. Support the common power-of-two values;
reject others explicitly rather than silently mis-computing (FR-009). Task T009 must record the
value the tool actually emits — if a backoff occurs, the storage ratio and lane framing change
and every figure derived from GS=64 needs revisiting.

## R4. Quantized file header — VERIFIED

256-byte header, magic `0x616b3432` ("ak42"), version 2, then the Config struct, a
shared-classifier flag, and the group size. Different from the legacy format feature 003 used
(28-byte header, no magic).

**Decision**: the loader must handle both, or the model-load path must be told which it is
reading. The magic number makes autodetection easy and is worth doing — a wrong-format load is
exactly the kind of failure that produces plausible-but-wrong output.

## R5. Model size collapses — and the memory map should be revisited

At **1.0625 bytes per parameter** (64 int8 + one 4-byte scale per GS=64 group) versus 4:

| | fp32 | Q8_0 |
|---|---|---|
| stories260K weights | 1,056,512 B | **~293,000 B** |

The current map (feature 003) gives weights a 2 MB region. Quantized, the same model needs
under 0.3 MB, and the 2 MB region would hold a model of roughly 1.8M parameters.

**Decision**: keep the 2 MB region for now — it is already allocated and unused space costs
nothing — but note that the capacity ceiling is set by the *region*, not the memory. Growing to
the ~5.6M parameters SC-004 targets requires enlarging the region, which is a one-line change
given the 3 MB currently marked free. Do it when a larger model actually exists.

## R6. int8 MAC hardware cost — cheap enough that DSPs are optional

An 8x8 signed multiply is roughly 60-80 LUTs if implemented in logic; four lanes is on the
order of 300 LUTs. The minimal profile has **66% of 24,288 LUTs free (about 16,000)** and 20
spare `MULT18X18D` blocks.

**Decision**: let the synthesis tool choose. Do not hand-instantiate DSP primitives in stage 1
— write the multiply behaviourally and check what yosys infers. Four int8 lanes fit either way,
and hand-mapping is premature optimisation that also hurts portability.

**This confirms the design's claim that int8 is cheaper than fp32**: an fp32 multiplier needs a
24-bit mantissa multiply plus exponent handling, alignment and normalisation — several hundred
LUTs plus DSPs *per lane*, and harder timing.

## R7. IO address space is FULL — VERIFIED, and this needs a decision

`HardwareConfig_bits.v` opens with "We got a total of 20 bits for 1-hot addressing of IO
registers", and `io_word_address` is `[19:0]`. **Bits 0-19 are all allocated.**

However, the minimal profile omits most of those devices. Free in this profile: bits 3-7
(OLED, LED matrix), 9 (buttons), **10-11 (FGA/GPU and synth)**, 12 (7-segment), 14 (interrupt
controller), 15-16 (PS2). Twelve bits are available.

**Decision**: allocate the accelerator **two** bits following the existing FGA pattern — one
"register index" and one "data" — because a single one-hot address cannot carry a 32-bit base
address plus a register selector in one write. Take bits 10 and 11, the slots the GPU and synth
occupied. Declare them mutually exclusive with those devices exactly as `IO_GPU_bit` already
does with `IO_FGA_CNTL_bit`.

**Alternatives considered**: a single bit with an index packed into `wdata[12:8]` as the GPU
does (fails for 32-bit address values); adding IO address bits (changes the memory map and
touches the CPU decode — far more invasive).

## R8. Results should be memory-mapped, not read through IO

Reading `d` results through an IO register costs a bus transaction each. For the classifier,
`d`=512, which is 512 IO reads.

**Decision**: map the accelerator's result BRAM into the address space so the CPU reads results
with ordinary loads. `0x100000` is free in the minimal profile — feature 003's Pico work used
that address for shared BRAM, but that work is on a different branch and is not present here.

This also avoids any cache-coherency question: results never enter SDRAM, so no stale copy can
exist.

## R9. Accumulator saturation — behaviour must be defined, not discovered

`int32` accumulating `GS` products of two int8 values: worst case per product is 127*127 =
16,129, so the default GS=64 gives at most 1,032,256 — far inside int32. **No saturation is
possible within a group**, which is presumably why `runq.c` never checks for it.

**Decision**: use int32 accumulation per group and rescale at group boundaries, matching
`runq.c` exactly. Document that overflow is structurally impossible for GS <= 133,144 rather
than adding saturation logic that would never fire and could not be tested meaningfully. The
edge case in the spec is therefore satisfied by proof rather than by code.

## R10. SDRAM reuse and the arbitration change

Carried over from `FemtoRV/RTL/ACCEL/DESIGN.md` section 9a, verified there against the RTL:

- The burst port on `muchtoremember_burst.v` is generic (arbitrary address, 1-256 word length)
  and needs **no changes**.
- `video_fetch_engine` is instantiated under `` `ifdef NRV_IO_SDRAM `` rather than
  `` `ifdef NRV_IO_GPU ``, so it is present but inert in the minimal profile and pruned by
  yosys. The weight fetch engine replaces it at that instantiation site.
- The one required change is a **three-line reorder** of the IDLE-state priority to put the CPU
  ahead of the burst port. Bursts are already atomic, so this alone yields
  CPU-priority-at-burst-boundaries.
- **The full profile must keep working.** The existing burst-over-CPU order was correct for
  video. Make the priority a parameter or gate it on the profile, and keep feature 003's
  no-regression check.

## R10a. Reset polarity — no inversion needed at the boundary

`femtosoc.v:234` declares `wire reset = &reset_cnt;` — the counter saturates and the signal goes
HIGH once reset is released. Despite the name, `reset` therefore carries **active-low semantics**
("not in reset"), which is why femtosoc passes it straight into ports named `resetn`
(lines 447, 466, 516, 540).

**Consequence**: the accelerator's `resetn` ports connect directly to `reset`. Do not add an
inverter at the integration boundary — a skeleton review flagged one as possibly needed, and it
would hold the accelerator in reset for the entire time the rest of the SoC is running, which
would present as "the accelerator never responds" rather than as an obvious wiring error.

---

## R14. Regression baseline (T006, measured 2026-08-20)

Captured **before** any shared RTL was modified, per constitution Principle V. Every later
change to `muchtoremember_burst.v` or `femtosoc.v` is checked against this.

`make colorlight_i5.synth`, full-featured profile:

| Resource | Used | % |
|---|---|---|
| LUT4 | 13,937 / 24,288 | 57% |
| Block RAM (DP16KD) | 40 / 56 | 71% |
| Multipliers (MULT18X18D) | 15 / 28 | 53% |
| PLL (EHXPLLL) | 2 / 2 | 100% |

Identical to feature 003's recorded figures, confirming the branch starts from a known-good
state. Tasks T047, T056 and T078 re-run this comparison.

---

## R15. Measured quantization results (T009, measured 2026-08-20)

`quantize_model.sh` on the fp32 stories260K checkpoint:

| | Value |
|---|---|
| Output size | **278,608 bytes** |
| fp32 original | 1,056,540 bytes |
| Ratio | **0.264** (SC-003 wants <= 1/3 — passes) |
| Bytes per parameter | 1.0714 |
| Group size | **64 — no backoff occurred** |
| magic / version | `0x616b3432` / 2, verified |
| shared_classifier | 1 |

**Independent cross-check**: `q8_format.h`'s `q8_checkpoint_bytes()` predicted 278,608 bytes
from the header arithmetic alone, and the quantizer produced exactly that. Two implementations
written separately agreeing to the byte is meaningful evidence that both read the format the
same way.

GS=64 confirms every storage and lane-framing figure in the spec and DESIGN.md, which were
corrected from an earlier GS=32 assumption. 1.0714 rather than the theoretical 1.0625 because
of the 256-byte header and the three RMSNorm tensors that stay fp32.

---

## R11. Verification strategy

**MEASURED baseline** (feature 003): 1.38 tok/s; matmul 61.3%, attention 27.4%; SDRAM burst
~98 MB/s simulated, 5.1 MB/s via CPU measured.

The chain of references that makes each stage conclusive:

1. Host `runq.c` on the quantized model — the golden reference.
2. CPU `runq.c` on the board — proves the port and quantization, gives the software baseline.
3. Simulated accelerator vs host reference — bit-exact, integer, unambiguous.
4. Hardware accelerator standalone vs CPU-computed reference — bit-exact.
5. Integrated generation vs step 2's output — **byte-identical text**.

Step 5 is the strong one: because every operand is integer, the accelerated path must produce
*exactly* the same tokens as the software path. Any divergence is a bug, not a rounding
difference. This is the property the fp16 fallback would weaken (R12).

## R12. If the fp16 fallback is taken

Per the spec's FR-004a, resolved by the user. What changes:

- Bit-exactness stops being free. Hardware and reference must agree on rounding mode and
  accumulation order, which must be specified deliberately.
- A host reference implementation must be written; none exists upstream (FR-011a).
- Capacity gain roughly halves (~3.0M parameters rather than ~5.6M).
- Lanes drop from 4 to 2, so the accelerated portion takes 6.5 ms rather than 3.6 ms —
  **an end-to-end difference of about 3%**, because the scalar remainder dominates.

**The throughput cost of the fallback is negligible; the capacity and verification costs are
not.** That ordering should drive the decision at the end of User Story 1.

## R13. Verification split

**Host-verifiable**: model quantization, host reference, `runq.c` port compilation, all
arithmetic in simulation, all arbitration behaviour in simulation, resource and timing reports.

**Requires the operator**: programming the board, the CPU-only quantized run, the standalone
hardware test, all generation runs, all performance-counter readings and rate measurements.

Batch into three sessions as feature 003 did: (1) CPU-only quantized model — the go/no-go on
quantization; (2) standalone accelerator test; (3) integrated generation and profiling.
