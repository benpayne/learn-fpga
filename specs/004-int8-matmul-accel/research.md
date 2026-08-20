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

**CORRECTION (research R15, T009, 2026-08-20): the "no backoff, GS=64" claim below was
WRONG for this model.** It checked only that each tensor's *total* element count divides GS
evenly (matching `export.py`'s own — incomplete — backoff check against `dim`). It missed that
runtime `runq.c`'s `matmul()`/`quantize()` ALSO require GS to divide `hidden_dim` (172 here,
not a multiple of 64), because those functions group per matmul-row / per-activation-vector,
not per whole tensor. The measured, verified-by-generated-text value for this model is
**GS=4**, not 64. See R15 for the full explanation and corrected figures — every number below
this line in this subsection is the SUPERSEDED estimate, kept only so the mistake and its
correction are both visible.

**~~VERIFIED default: 64.~~ SUPERSEDED — see correction above.** `export.py` declares `def
version2_export(model, filepath, group_size=64)` and backs off by halving while `dim %
group_size != 0`. Checked against this model's tensor sizes — token embedding 32768, wq/wo
4096, wk/wv 2048, w1/w2/w3 11008 — all multiples of 64, so **no backoff is expected and GS
should be 64**. *(This reasoning checked total tensor size only; it did not check `hidden_dim`,
which is what actually forces the backoff to GS=4 — see R15.)*

~~That gives `(64 + 4) / 64 = 1.0625` bytes per weight, **26.6% of fp32**, and 3.76 weights per
32-bit word once the separate scale block is amortised in.~~ At the actual GS=4: `(4 + 4) / 4 =
2.0` bytes per weight, **50% of fp32** for the quantized portion.

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

## R15. Measured quantization results (T009, measured 2026-08-20) — CORRECTED, GS != 64

**An earlier version of this section reported GS=64 with no backoff. That was WRONG and has
been replaced.** A GS=64 checkpoint loads without error, matches `q8_checkpoint_bytes()`
byte-for-byte, and LOOKS fine by every size/header check — but running it through
`runq_host` produces degenerate, repeated-token garbage ("there there there there ... upon
upon upon..."), not merely "some divergence". This is exactly the silent-wrong-output failure
class this project is built to catch, and it was only caught by actually generating text and
reading it (T010's verification step), not by any size or checksum check. **Trust generated
text over header arithmetic.**

**Root cause**: two DIFFERENT divisibility requirements exist, and only one of them was
checked.

1. Total tensor size divisible by GS — what upstream `export.py`'s `quantize_q80()` asserts
   (`w.numel() % group_size == 0`), and what `q8_format.h`'s `q8_checkpoint_bytes()` and this
   feature's earlier size arithmetic verified. GS=64 passes this for every tensor in this
   model, including w2 (11,008 elements, evenly divisible by 64).

2. **`dim % GS == 0` AND `hidden_dim % GS == 0`** — NOT checked by `export.py` (which only
   backs off against `dim`; see R3), but REQUIRED by runtime `runq.c`. `matmul()`'s inner loop
   (`for (j = 0; j <= n - GS; j += GS)`) resets at the start of every output row, using `n` as
   a PER-ROW length — `n = dim` for the wq/wk/wv/wo/w1/wcls calls, but **`n = hidden_dim` for
   the w2 call**, and `quantize()` uses the same `n` (via integer division `n / GS`) to size
   the activation vector it fills. If GS does not divide `n`, the last `n % GS` elements of
   EVERY row of that matmul — and of the corresponding quantized activation vector, whose own
   `quantize()` silently leaves that tail unfilled — never enter the dot product. This is a
   row/vector-tail truncation, not a rounding-precision loss, and it is invisible to any
   total-size check.

For this model: `dim = 64` (divisible by every power of two down to 1) but
`hidden_dim = 172 = 2² x 43` (43 is prime), so the largest power-of-two group size dividing
*both* is **4**. GS=64/32/16/8 all silently corrupt the w2 matmul and the hq activation
quantization despite passing every size/checksum check.

**Corrected measured results**, `quantize_model.sh` on the fp32 stories260K checkpoint:

| | Value |
|---|---|
| Output size | **521,728 bytes** |
| fp32 original | 1,056,540 bytes |
| Ratio | **0.494** (49.4% of fp32) |
| Bytes per parameter (quantized weights) | **2.0000** = 1 + 4/GS at GS=4 |
| Group size | **4 — BACKED OFF from requested 64** (64→32→16→8→4) |
| magic / version | `0x616b3432` / 2, verified |
| shared_classifier | 1 |
| sha256 | `c8c032d04f8a48b2c8f9b708cc571a895d45fe23521f47f542b897d64ad77c50` |

**Text quality confirms the fix**: with GS=4, `runq_host` produces "Once upon a time, there
was a little girl named Lily. She had a jolly apple that she loved to play outside. One day,
she went to the park with her mom. She saw a big tree and said..." — coherent, and closely
tracking the fp32 baseline's "...She saw a big box" (diverging only at that word). See
`specs/004-int8-matmul-accel/golden-reference-q8.txt` (T010) for the full transcript.

**Independent cross-check, still valid**: `q8_format.h`'s `q8_checkpoint_bytes()` predicted
521,728 bytes at GS=4 from the header arithmetic alone, and the quantizer produced exactly
that — the format-layout agreement between the two independently-written implementations
holds regardless of GS; only the *chosen* GS value was wrong.

**IMPORTANT — this is not 0.264/26.6% and it is not GS=64. Every storage ratio and
lane-framing figure elsewhere in this spec, DESIGN.md, and data-model.md that assumes GS=64
needs revisiting**, in particular:
- SC-003's size-ratio target should be checked against 0.494, not 0.264.
- The accelerator's per-group rescale amortizes over 4 MACs, not 64 — the weight-fetch
  prefetch-scales-then-stream-weights design (R1) still holds structurally, but the ratio of
  scale-block size to weight-block size is now `4/(4+4)=50%` of the stream instead of ~1.5%,
  which changes the "scales are tiny, prefetch them" cost/benefit calculus materially.
- Bytes-per-parameter is 2.0, not 1.0625 — capacity-per-region figures (R5) need recomputing.
- `GS` is still correctly modeled as a runtime/file parameter rather than a constant (R3), but
  R3's specific claim of "no backoff expected, GS should be 64" is superseded by this section —
  see the correction note added to R3 below.

This was reported to the team lead as a significant finding requiring downstream attention
(RTL group-size assumptions, spec size-ratio figures) beyond this task's own scope.

---

## R16. **Group size is capped at 4 by this model's dimensions** (found 2026-08-20)

**This is the most consequential finding so far and it changes the feature's economics.**

`runq.c`'s quantized matmul is `for (j = 0; j <= n - GS; j += GS)`, which silently requires
`GS` to divide `n`, the *inner* dimension. This model uses two inner dimensions:

| Matmuls | Inner dimension |
|---|---|
| wq, wk, wv, wo, w1, w3, classifier | dim = 64 |
| **w2 (FFN down-projection)** | **hidden_dim = 172** |

`gcd(64, 172) = 4`, so **GS=4 is the largest valid group size**. At GS=64 the w2 matmul covers
only 128 of 172 elements — **26% of the FFN down-projection silently skipped**. That produced
degenerate output ("there there there ... upon upon upon"), which is how this was found.

**Two failure paths, not one.** The matmul truncation above is the obvious one. The activation
quantization has the same defect: `quantize()` computes `int num_groups = n / GS` by integer
division, so for the w2 call (`quantize(&s->hq, s->hb, hidden_dim)` with n=172, GS=64) it
produces only 2 groups covering 128 elements and leaves the remaining 44 `q` entries
**uninitialised** — worse than dropped, since they carry stale data into the dot product.

**Upstream would not have caught it either**: `export.py` backs off only while
`dim % group_size != 0` and never checks `hidden_dim`, and its assertion tests
`w.numel() % group_size`, which passes (11008 = 172 x 64 is divisible by 64) even though the
inner dimension is not.

**Neither the writer nor the reader is defective.** This is worth stating because the
investigation initially mis-framed it. Dequantizing each stored tensor against its fp32
original passes at GS=64 — that checks the writer, and the writer is correct. The reader's
header parsing, `shared_classifier` aliasing and dequantized embedding table are all verbatim
upstream and were independently verified. The invalid quantity is the **group size**, which is
a runtime parameter of the format, and its validity depends on the model's inner dimensions
rather than on anything either side stores. The decisive evidence is that the *same* reader
binary produces garbage against a GS=64 file and coherent text against a GS=4 file.

### What GS=4 costs

| | GS=64 (assumed throughout the spec) | GS=4 (actually valid) |
|---|---|---|
| bytes/weight | 1.0625 | **2.0000** |
| ratio vs fp32 | 0.266 | **0.494** |
| MAC lanes | 4 | **2** |
| capacity gain | 3.8x | **2x** |
| checkpoint size | 278,608 B | 521,728 B |

**SC-003 (ratio <= 1/3) and SC-004 (capacity >= 3x) both FAIL at GS=4.** Worse, int8 at GS=4 is
storage-equivalent AND lane-equivalent to fp16 while being less accurate — the entire argument
for choosing int8 over fp16 (research R12, DESIGN.md 3.4) collapses for this model.

### Zero-padding restores it, and is mathematically free

Padding `hidden_dim` costs nothing in correctness: w1/w3 produce zeros in the padded region,
`silu(0) * 0 = 0`, and w2's dot product over the padded columns contributes exactly zero.

| hidden_dim | max GS | bytes/wt | ratio | lanes | FFN weights | q8 size |
|---|---|---|---|---|---|---|
| 172 (none) | 4 | 2.0000 | 0.494 | 2.0 | +0% | 521,728 |
| **176** | 16 | 1.2500 | 0.312 | 3.2 | +2.3% | ~328,960 |
| **192** | **64** | **1.0625** | **0.266** | **3.8** | +11.6% | ~295,936 |
| 256 | 64 | 1.0625 | 0.266 | 3.8 | +48.8% | ~361,216 |

Padding to 192 restores the full design. Padding to 176 is far cheaper in weights and still
clears SC-003, at 3.2 effective lanes.

**Cost of padding**: the converter must pad, the firmware must size its buffers to the padded
hidden_dim, and the accelerator descriptor carries n=192 rather than 172. All bounded, but it
is real work in three places and it makes the on-board model differ structurally from the
published one.

### Status

**DECIDED 2026-08-20: pad `hidden_dim` from 172 to 192, restoring GS=64.**

Rationale: R17 measured quantization quality at 0.000216 nats mean KL with 100% top-1
agreement — a 46x margin against SC-002. Quality was never the constraint, so the GS cap was
purely a storage-and-lanes penalty with no compensating benefit. Padding removes it for +11.6%
FFN weights and restores the full four-lane datapath the accelerator architecture was sized
around.

Expected after padding: 1.0625 bytes/weight, ratio 0.266 (SC-003 passes), ~296 KB checkpoint,
3.76 weights per 32-bit word.

**What padding touches** — three places, all bounded:
1. the converter, which zero-pads w1/w3 rows and w2 columns and writes hidden_dim=192;
2. the firmware, whose RunState buffers size to the padded hidden_dim;
3. the accelerator descriptor, which carries n=192 for the w2 operation rather than 172.

Padding is exact, not approximate: w1/w3 emit zeros in the padded region, `silu(0) * 0 = 0`,
and w2's dot product over the padded columns contributes exactly zero. The padded model is
mathematically identical to the original.

---

## R17. Quantization QUALITY measured — int8 passes decisively (T013, 2026-08-20)

Teacher-forced comparison of the fp32 and Q8_0 (GS=4) models over 140 matched positions:

| Metric | Value | SC-002 threshold |
|---|---|---|
| mean KL | **0.000216 nats** | < 0.01 — passes by 46x |
| median KL | 0.000133 | |
| p99 KL | 0.001113 | |
| max KL | 0.001643 | |
| top-1 agreement | **100.00%** | > 95% |

**VERDICT: PASS, decisively. Quantization quality is not a problem for this model.**

### Methodological correction, recorded because it nearly caused a wrong verdict

The first attempt let both models **generate freely** from the same seed and compared their
logits position by position. That produced **mean KL 7.77 nats and 34% top-1 agreement** — a
catastrophic-looking result that would have failed the gate and sent the feature to fp16.

It was an artefact. Once the two models sample even one different token (fp32 chose "big box",
the quantized model "big tree"), they are processing **different text**, and every later
position is incomparable. The measurement was capturing sequence divergence, not quantization
error.

The correct method is **teacher-forcing**: give both models an identical long prompt, let them
consume it, and compare only the prompt positions where both saw the same tokens. Same model
pair, same files, correct method: 0.000216 nats instead of 7.77 — a factor of 36,000.

This requirement is now documented at the top of `kl_compare.py`. **Anyone re-running the gate
must teacher-force.** A free-running comparison does not merely add noise; it produces a
confident, plausible, and completely wrong answer.

### Consequence for the decision

The quality question raised in the spec's Assumptions — "quantization error is proportionally
worse on small models, and this one is very small" — is answered: **it is not a problem here.**
The 46x margin also implies larger group sizes would still pass comfortably, so the GS cap in
R16 is a storage-and-lanes problem, not a quality one. That materially strengthens the case for
padding `hidden_dim` to recover GS: it costs a little model size and buys back both capacity
and MAC lanes, at no measured quality risk.

---

## R18. Padded model measurements (2026-08-20)

Implemented the R16/R17 decision: `quantize_model.sh` now zero-pads `hidden_dim` from 172 to
192 before quantizing (`PAD_HIDDEN_TO`, defaults to 192, overridable via the environment so 176
or 0/no-padding can be tried without touching any control flow). w1/w3 gain 20 new all-zero
rows (append, since they are `[hidden_dim][dim]`); w2 gains 20 new all-zero columns inserted at
the end of every row (per-row insert, since it is `[dim][hidden_dim]` and hidden_dim is the
*inner* stride — a flat append would have silently shifted every row after the first). `runq_host.c`
and `run_host.c` were not modified — the padding is entirely a converter-side transformation and
required no reader change, confirming it is transparent as claimed in R16.

### Padding cost

FFN weight count (w1+w2+w3, per layer) grows from `3 * 172 * 64 = 33024` to `3 * 192 * 64 =
36864`, i.e. **+11.6%** — exactly the R16 estimate.

### Quantized output

- Group size: **64, no backoff** (as required — the run printed "group size used: 64 (no
  backoff, as expected)").
- Output size: **299,008 bytes** (estimate was ~296 KB).
- sha256: `759d06bf4228772cc9cd73512801c5402753bc8d8a5de96fda1765de09e86c28`
- Bytes/parameter (quantized tensors): **1.0625** (`= 1 + 4/64`, as expected).
- fp32 original: 1,056,540 bytes. Ratio: **299008 / 1056540 = 0.2830** (28.3% of fp32 size) —
  **SC-003 (ratio ≤ 1/3) now PASSES**, versus 0.494 (fail) at GS=4.
- 279,232 total parameters (278,528 quantized + 704 fp32 rmsnorm).

### Generated text

`./runq_host model.q8.bin tokenizer.bin --seed 2026 --steps 110 -i "Once upon a time"`:

> Once upon a time, there was a little girl named Lily. She loved to play with her toys and her
> friends. One day, Lily found a new toy in her box. She went to the store and put the toys on
> her toy. She closed it in her hand, people hold a big brown rock. Lily tried to pull it

Coherent English throughout, same register and vocabulary as the fp32 reference text (a
different sample, as expected — greedy decode over int8 logits at GS=64 is not required to
reproduce the GS=4 or fp32 token stream, only to stay linguistically coherent, which it does).

### Teacher-forced KL comparison (the rigorous check)

Followed the R17 methodology exactly, teacher-forcing an identical 459-byte story prompt into
both `run_host` (fp32) and `runq_host` (padded Q8_0, GS=64) and dumping logits for both:

```
STORY=$(./run_host -s 2026 -n 210 -p "Once upon a time" | sed -n '/^Once upon/,$p' | grep -v '^achieved' | head -c 900)
./run_host  -s 2026 -n 220 -p "$STORY" --dump-logits /tmp/f3.logt
./runq_host model.q8.bin tokenizer.bin --seed 2026 --steps 220 -i "$STORY" --dump-logits /tmp/q3.logt
```

(One correction to the recipe: `run_host`'s "achieved N tok/s" line is printed to stdout, not
stderr, and the story text here is short enough that `head -c 900` did not truncate it away —
had to `grep -v '^achieved'` it out of the prompt explicitly, or it would have been fed back in
as part of "$STORY".)

Compared the first 140 positions (numpy, using `kl_compare.py`'s own `read_logt`/`softmax`/
`kl_per_position` helpers directly, sliced to `[:140]`, since the CLI has no row-limit flag):

| Metric | Value | SC-002 threshold |
|---|---|---|
| mean KL | **0.000977 nats** | < 0.01 — passes by ~10x |
| median KL | 0.000600 | |
| p99 KL | 0.004340 | |
| max KL | 0.004570 | |
| top-1 agreement | **100.00%** | > 95% |

**140 was confirmed to be exactly the right cutoff, not just "close enough":** checking every
position out to 220, the fp32 and quantized argmax tokens agree on every single position
through index 139 and the *first* disagreement is at position 140 exactly (KL 0.00977 there) —
that is where free-running divergence begins, matching R17's warning precisely. Running
`kl_compare.py` unmodified over the full 220 positions (i.e. deliberately repeating R17's
original mistake) reproduces the same class of bogus result R17 documented: mean KL 0.165,
p99 7.92, max 11.44, verdict FAIL — an artifact of comparing post-divergence free-running
positions, not a quantization problem. This is included here only to confirm the 140-row
boundary is real and the teacher-forcing requirement is not optional.

**VERDICT: PASS.** GS=64 padded quality (0.000977 nats mean KL, 100% top-1) is about 4.5x the
GS=4 figure from R17 (0.000216 nats) — slightly worse, exactly as expected since larger groups
share one scale across more weights — but still an order of magnitude inside the SC-002 gate.

### Summary vs. R16/R17

| | GS=4 (unpadded) | GS=64 (padded, this section) |
|---|---|---|
| checkpoint size | 521,728 B | 299,008 B |
| bytes/weight | 2.0000 | 1.0625 |
| ratio vs fp32 | 0.494 (fails SC-003) | 0.2830 (passes SC-003) |
| MAC lanes | 2 | 4 |
| mean KL | 0.000216 nats | 0.000977 nats |
| top-1 agreement | 100% | 100% |

Padding delivers on R16's projection: SC-003 now passes, the accelerator gets its full 4-lane
datapath back, and quality stays comfortably inside the SC-002 gate. No reader-side change was
needed, so the "padding is transparent" claim in R16 holds.

---

## R19. Burst efficiency MEASURED — estimate was wrong, BURST_LEN 64 -> 128

**FINAL** (T041, 2026-08-20). 3000 bursts per point idle, 1000 loaded — two to three orders of
magnitude more samples than the first pass. Testbench 6/6 PASS.

### The SC-006 gate: efficiency with no competing traffic

| Burst | Measured | Estimated (wrong) | SC-006 (>= 90%) |
|---|---|---|---|
| 16 | 62.7% | 72.7% | FAIL |
| 32 | 76.4% | 84.2% | FAIL |
| 64 | **85.7%** | 91.4% | **FAIL** |
| **128** | **91.3%** | 95.5% | **PASS** |
| 256 | 94.8% | 97.7% | PASS |

### Under realistic CPU load (one request per ~100 cycles)

| Burst | Loaded eff | CPU worst wait | CPU mean wait |
|---|---|---|---|
| 16 | 59.4% | 34 cyc | 16.9 |
| 32 | 72.9% | 34 cyc | 31.8 |
| 64 | 82.4% | 57 cyc | 55.4 |
| **128** | **87.5%** | **48 cyc** | 46.2 |
| 256 | 92.7% | 179 cyc | 176.1 |

### Decision: BURST_LEN = 128

DESIGN.md chose 64 on an estimated 91.4%. It delivers 85.7% and **fails SC-006**. 128 clears the
gate at 91.3% and — unexpectedly — also has a *lower* CPU worst-case wait than 64 (48 vs 57
cycles), so it is better on both axes rather than a trade. 256 buys 3.5 more points for 3.7x the
CPU latency, poor value when scalar work dominates after integration.

### Why the estimate was wrong — the part that generalises

Back-calculated per-burst overhead is ~9.5 cycles at 16 words rising to ~14 at 256, versus the
~6 assumed. The missing cost is SDRAM protocol overhead the estimate omitted: tRP recovery
between back-to-back bursts on top of ACTIVATE/CAS setup, plus a row crossing every 256 words.
The 6-cycle figure came from a burst test measuring **bare CAS setup** — one phase of the
protocol, not the full burst-to-burst turnaround.

**An estimate taken from one phase of a pipelined protocol will understate a design that pays
all of them.** The error was systematic rather than noisy: 8-13 points at every burst length,
converging as the fixed cost amortises.

### Starvation guard: unreachable under realistic load

Fired zero times at every CPU rate tested, including one request per 20 cycles. Forcing it
required an artificial driver holding the request line asserted every cycle, at which point it
did its job — accelerator throughput held at 37.1% rather than 0%. Its unreachability in
realistic traffic empirically confirms the workload analysis in DESIGN.md 6.1 rather than
leaving it an assertion.

### Burst atomicity: confirmed by reading the FSM, not assumed

Once `s_idle` enters `s_burst_act`, the only return path is through the drain and precharge
states, with CPU requests held in `wmask_sticky`/`rd_sticky` throughout. Row-crossing adds
states but stays inside the burst. The three-line-reorder simplification is therefore sound.

---


## R20. Both synthesis profiles write the same artifact filenames (found 2026-08-20)

`BOARDS/colorlight_i5.mk` and `BOARDS/colorlight_i5_llm.mk` both derive their outputs from
`$(PROJECTNAME)`, which is `femtosoc` in both cases. So `make colorlight_i5.synth` and
`make colorlight_i5_llm.synth` write the **same four files**:

| File | Written by | Consequence |
|---|---|---|
| `femtosoc.json` | both | concurrent runs corrupt each other |
| `femtosoc_out.config` | both | ditto |
| `femtosoc.bit` | both | **the flashed bitstream is whichever profile ran last** |
| `femtosoc.svf` | both | ditto |

Two distinct failure modes, and the second is the dangerous one:

1. **Concurrent** runs interleave writes to `femtosoc.json` and produce garbage. Found while
   holding back the T047/T056 display-profile regression: an LLM-profile `yosys` was already
   running, and starting the regression would have clobbered it. Same class as the `sim_build/`
   collision hit earlier in this feature — shared build state with no per-consumer namespace.

2. **Sequential** runs silently overwrite. Nothing in the filename says which profile is inside
   `femtosoc.bit`, so flashing it programs whichever synthesis ran most recently. A wrong-profile
   board looks like a hardware fault, not a build accident, and the two profiles differ in
   exactly the peripherals whose absence is hardest to read from a serial log. The stale
   `femtosoc_llm.bit` in the tree (dated 2026-08-18, from a one-off manual rename) is the
   residue of someone already tripping over this.

**Decision**: give the LLM profile its own artifact basename so the two bitstreams can coexist
and are self-identifying. Deferred until the in-flight LLM synthesis finishes rather than
editing a makefile out from under a running job.

**Bearing on this feature**: T047/T050/T056 all run synthesis, in two different profiles, and
the SC-014 regression compares one against the other. That comparison is only trustworthy if
each profile's artifacts survive the other's run.

---

## R21. The accelerator could not be synthesized at all — yosys `share` does not terminate (found 2026-08-20)

The first full synthesis of the accelerator-enabled profile was **OOM-killed**: `yosys` reached
21 GB RSS before the kernel killed it (`Out of memory: Killed process 2872877 (yosys)
total-vm:22198188kB, anon-rss:21035732kB`). No resource or timing numbers came out of it.

Two things were wrong, and the second is the one worth remembering.

### The reporting failure

The run was reported as "completed (exit code 0)". That was the exit status of the `tee`/`tail`
pipeline, not of `make`, which was `Killed`. In a shell pipeline `$?` is the **last** command's
status, so `make ... | tee log` reports success no matter how `make` died. Any synthesis
invocation whose result is trusted must either avoid the pipe (`make > log 2>&1; echo $?`) or
set `pipefail`. This feature has now been bitten three times by shared or shadowed state
reporting success — the `$<`-only link line, the shared `sim_build/`, and this.

### The real defect

Reproduced standalone in **seconds**, without a full SoC build:

```
yosys -p "read_verilog -I. acc_top.v acc_mac.v acc_regs.v acc_weight_fetch.v;
          synth_ecp5 -top acc_top"      -> std::bad_alloc under an 8 GB cap
```

Bisected by module:

| Module | `synth_ecp5` standalone |
|---|---|
| `acc_regs.v` | OK |
| `acc_weight_fetch.v` | OK |
| `acc_mac.v` | **aborts — `std::bad_alloc`** |

The abort is always in the same place: **`5.17. Executing SHARE pass (SAT-based resource
sharing)`**. `share` uses a SAT solver to prove two operators are never simultaneously live so
they can be merged. `acc_mac.v` presents it with `$mux` x779, `$eq` x92, `$logic_and` x96 and
`$mul` x6 — the signature of its three large *combinational* fp32 functions (`i2f32`,
`fp_mul32`, `fp_add32`, plus a 32-iteration `clz32`). The SAT instance is intractable, not
merely slow.

Narrowing the two 32x32 multiplies in `acc_weight_fetch.v` to their real 16-bit operand widths
was tried first and **did not help** — the multipliers were not the cause.

### What was actually wrong with the process

`acc_mac.v` passed 7/7 cocotb tests and 1000/1000 bit-identical vectors. It is *functionally*
correct and always was. **Simulation says nothing about synthesizability**, and until this run
nothing in the feature had ever put the accelerator through yosys. Constitution Principle I
("simulate before hardware") was satisfied while the design could not be built at all. A cheap
per-module `synth_ecp5` smoke check belongs alongside the cocotb run, and would have caught
this at T031 instead of T050.

### Resolution

`share` is an optimisation, not a correctness requirement. `BOARDS/colorlight_i5_llm.mk` now
runs `synth_ecp5`'s coarse stage explicitly with `share` omitted, **scoped to this profile only**
so the display profile's flow — and therefore its R14 regression baseline — is untouched.

Measured with `share` omitted (out-of-context, per module):

| | LUT4 | CCU2C | TRELLIS_FF | MULT18X18D | DP16KD |
|---|---|---|---|---|---|
| `acc_mac` alone | 1,749 | 292 | 281 | 12 | 0 |
| `acc_top` (whole accelerator) | 2,784 | — | 1,279 | 17 | 33 |

Projected against feature 003's measured minimal-profile baseline (LUT 8,391 / BRAM 16 /
MULT 8):

| Resource | Baseline | + accelerator | Of device |
|---|---|---|---|
| LUT4 | 8,391 | ~11,175 | ~46% — comfortable, SC-013 wants >=25% free |
| DP16KD | 16 | ~49 | **~88%** |
| MULT18X18D | 8 | ~25 | **~89%** |

It fits, but BRAM and DSP are both near the ceiling, and neither needs to be:

- **33 BRAMs** come from four memories totalling 409,600 bits. The result and activation BRAMs
  are `NUM_SLOTS=8 x 512` words each, sized for `MAX_N`/`MAX_D` of 4096. This model's `n` and
  `d` never exceed 512. Dropping `ACT_AWIDTH`/`RESULT_AWIDTH` from 12 to 11 halves both.
- **17 DSPs** where the datapath needs **4** — four int8 lanes. The other 13 are consumed by the
  fp32 functions' mantissa multiplies.

Both point the same way: the fp32 rescale is built as single-cycle combinational logic, but it
runs **once per group of GS=64 elements**, not once per cycle. There is a ~64-cycle budget for
work currently being done in one. Sequencing it would cut DSPs, cut LUTs, remove the `share`
pathology at its source, and relieve the timing risk this much combinational depth carries at
25 MHz. Recorded as the first candidate if resources or timing bite.

---

## R22. T050 measured — it fits and it closes timing, but the margin is thin (2026-08-20)

First successful synthesis of the accelerator-enabled profile, after R20's artifact rename and
R21's `share` removal. `make colorlight_i5_llm.synth` exit status **0** (checked directly, not
through a pipe — see R21), nextpnr "Program finished normally", `femtosoc_llm.bit` produced.

| Resource | 003 baseline | With accelerator | Device | SC-013 |
|---|---|---|---|---|
| LUT4 | 8,391 (34%) | **13,183 (54%)** | 24,288 | 46% free — **PASS** (needs >=25%) |
| DP16KD | 16 (28%) | **49 (87%)** | 56 | 7 blocks left |
| MULT18X18D | 8 (28%) | **25 (89%)** | 28 | 3 left |
| EHXPLLL | 1 (50%) | 1 (50%) | 2 | unchanged |
| TRELLIS_FF | — | 2,686 (11%) | 24,288 | — |

The out-of-context projections in R21 (~49 BRAM, ~25 DSP) matched the placed design exactly.

### Timing is the real finding

```
Max frequency for clock '$glbnet$clk': 26.21 MHz (PASS at 25.00 MHz)
```

It passes, but with **4.8% margin**, and the critical path is unambiguous:

```
Source accel_inst.u_mac.s3_rescaled_f_q   ->   Sink accel_inst.u_mac.row_result_q
Setup 35.5 ns
```

That is `acc_mac.v`'s fp32 rescale — the same combinational logic that made `share` diverge in
R21 and that consumes 13 of the 17 accelerator DSPs. Three independent symptoms, one cause.

**This margin should not be accepted as-is**, on this project's own precedent. Feature 003's
minimal profile reached 40.76 MHz; the accelerator costs 36% of that. More directly: the
256-entry SDRAM cache was **rejected** for reaching only 28.4 MHz against a 25 MHz target, and
UART flakiness was later traced to exactly that kind of thin margin rather than to a logic
fault. 26.21 MHz is tighter than the configuration this project already judged too tight.

### What to do about it

`acc_mac.v` performs the fp32 rescale as single-cycle combinational logic, but a rescale happens
**once per group of GS=64 elements**. There is a ~64-cycle budget being spent in one. Sequencing
or pipelining it over even a handful of cycles would:

- move the critical path off the fp32 normalise/round chain, recovering timing margin;
- free most of the 13 DSPs the mantissa multiplies consume, easing 89% DSP occupancy;
- remove the `share` pathology at its source, letting the profile use the stock `synth_ecp5`
  flow instead of R21's staged workaround.

Separately, the result and activation BRAMs are sized `NUM_SLOTS=8 x 512` words from `MAX_N`/
`MAX_D` of 4096, while this model's `n` and `d` never exceed 512. Dropping `ACT_AWIDTH`/
`RESULT_AWIDTH` from 12 to 11 halves both and would return roughly 16 of the 49 BRAMs.

### This bitstream must not be flashed

`femtosoc_llm.bit` from this run contains the scale-pipelining defect found at T036: the weight
and activation scale registers advance one cycle early, so every group followed by another group
is rescaled with the **next** group's scale. Confirmed arithmetically — hardware produced
`0x423f57a1` = 47.8356, matching `50166 * w_s[1] * xs[0]`, where the correct value using
`w_s[0]` is 26.4823. The build proves synthesizability and gives real resource and timing
figures; it does **not** produce correct results, and Session B must wait for the fix.

---

## R23. SC-007 / SC-008 measured under CPU contention (T044, 2026-08-20)

R19 measured burst efficiency under CPU load as part of deciding `BURST_LEN`, but never framed
the result against SC-007 ("CPU worst-case wait is bounded, documented, and no worse than the
chosen transfer size implies") or SC-008 ("accelerator throughput degrades gradually under
sustained processor traffic and never reaches zero") by name, and its own light/heavy/
pathological scenario tests (`acc_arb_tb.py`) were hardcoded to `burst_len=64` — the pre-R19
default, not the `BURST_LEN=128` the profile actually ships (R19's decision, R22's synthesized
config). This section is the explicit SC-007/SC-008 verdict against the shipped configuration,
plus a rerun of the original `burst_len=64` scenarios as a same-testbench sanity cross-check.
Testbench: `acc_arb_tb.py` (`make MODULE=acc_arb_tb SIM=icarus`), 6/6 original tests + 3 new
`_bl128` tests, all PASS.

### burst_len=128 (production) — the SC-007/SC-008 gate

| Scenario | cpu_period | accel eff | CPU n | CPU max wait | CPU mean wait | guard_fired |
|---|---|---|---|---|---|---|
| idle (R19, for reference) | none | 91.3% | 0 | — | — | 0 |
| light | 500 cyc | 90.4% | 17 | **67** | 66.8 | 0 |
| heavy | 20 cyc | 87.5% | 68 | **128** | 126.2 | 0 |
| pathological (hammer, every cycle) | 1 cyc | 53.8% | — | — | — | **42** |

**SC-007 — PASS.** CPU worst-case wait under heavy contention (every 20 cycles, the CPU as busy
as any realistic miss rate gets) is exactly **128 cycles — one burst length, no more**. That is
the tightest possible confirmation of "no worse than the chosen transfer size implies": the
worst case does not merely stay bounded, it equals the bound. Light load's 67-cycle max is
consistent with the same one-burst ceiling (partial overlap with an in-flight burst rather than
the full length).

**SC-008 — PASS.** Efficiency degrades smoothly as CPU load rises — 91.3% (idle) -> 90.4% (light)
-> 87.5% (heavy) — a shallow, monotonic decline, not a cliff. Even the deliberately pathological
hammer scenario (CPU pending literally every cycle, not a load any real firmware can produce)
holds 53.8%, more than half the unshared roofline, because the anti-starvation guard forces a
burst through periodically. Throughput never approaches zero at any tested load.

**Guard usage — as designed.** `starve_guard_fired=0` at every realistic load (idle/light/heavy)
confirms the guard is not needed in practice, matching the workload analysis in DESIGN.md 6.1.
`starve_guard_fired=42` under the hammer scenario proves the mechanism itself works: without it,
`cpu_pending` never drops for even one cycle under that driver, and CPU_PRIORITY=1 alone would
starve the accelerator completely (0 bursts, 0.0% eff) rather than the measured 53.8%.

### burst_len=64 (historical) — same scenarios, for cross-check against R19

| Scenario | cpu_period | accel eff | CPU n | CPU max wait | CPU mean wait | guard_fired |
|---|---|---|---|---|---|---|
| idle | none | 85.7% | 0 | — | — | 0 |
| light | 500 cyc | 84.8% | 18 | 30 | 28.6 | 0 |
| heavy | 20 cyc | 79.4% | 123 | **64** | 60.7 | 0 |
| pathological (hammer) | 1 cyc | 37.1% | — | — | — | **58** |

Same pattern at the old burst length: heavy-load CPU max wait (64 cycles) again equals exactly
one burst, and pathological-load efficiency (37.1%) matches R19's own "Starvation guard:
unreachable under realistic load" section number for number — same deterministic testbench, same
RTL, same result, as expected. Included for completeness now that the SC-007/SC-008 gates have a
dedicated write-up; R19 remains the source for the `BURST_LEN` decision itself.

### Test additions

Three new `@cocotb.test()` functions added to `acc_arb_tb.py` — `test_cpu_light_load_bl128`,
`test_cpu_heavy_load_bl128`, `test_starvation_guard_fires_bl128` — mirroring the existing
64-word scenarios at `burst_len=128`, with the SC-007 bound scaled accordingly (`128 + 80`
cycles instead of `64 + 80`). The original three are left unmodified as the R19 cross-check
above relies on them measuring exactly what they always measured.

---
