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

### CORRECTION (2026-08-20, same day): 28.15 MHz is post-routing; 26.21 was the estimate

This entry originally recorded **26.21 MHz**. That is nextpnr's **post-placement estimate**,
printed right after `SA placement time`. The real figure is the **post-routing** one, printed
after `Routing complete`, and it is **28.15 MHz**. Every number in this entry has been corrected.

The mistake propagated: it made the margin look like 4.8% when it is **12.6%**, and it supported
a claim that the accelerator was "tighter than the 256-entry cache this project already
rejected at 28.4 MHz". At 28.15 versus 28.4 the two are effectively the same margin, not
dramatically worse. The concern about operating this close to the target is still legitimate —
that cache *was* rejected at essentially this figure — but it was argued from a number that was
not the design's actual frequency.

**Rule for anyone reading a nextpnr log here: take the fmax printed after `Routing complete`,
not the one after `SA placement time`.** Both appear, both name the same clock, and only the
second is real. The same misread would have made R29's failing build look worse than it is
(20.97 estimated versus 23.55 actual).

### Timing is the real finding

```
Max frequency for clock '$glbnet$clk': 28.15 MHz (PASS at 25.00 MHz)
```

It passes, but with **12.6% margin**, and the critical path is unambiguous:

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
fault. 28.15 MHz is tighter than the configuration this project already judged too tight.

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

## R24. `FIRMWARE/config.mk` is shared mutable state between profiles (found 2026-08-20)

`make <profile>.firmware_config` **overwrites** `FemtoRV/FIRMWARE/config.mk`, which is a tracked
file both profiles share. Running the display-profile regression (T047/T056) flipped it from
`BOARD=colorlight_i5_llm` to `BOARD=colorlight_i5` mid-session, while the accelerator work was
the active task.

**This is a latent hazard today, not an active bug** — checked rather than assumed. The two
profiles' generated configs differ in exactly one line: `OPTIMIZE`, `ABI`, `RAM_SIZE` and
`DEVICES` are identical, and `BOARD` is read in only two places in `FIRMWARE/makefile.inc` — an
`ifeq` against `icesugar_nano`, and a `spiflash_$(BOARD).ld` path used by a link rule that
neither `llama2.bin`, `runq.bin` nor `acc_test.bin` goes through. So firmware built while the
file is flipped is byte-identical either way, for now.

It stops being benign the moment the profiles' configs diverge — a different `RAM_SIZE`, a
different `DEVICES` line, an added define. At that point building firmware after a regression
run would silently produce a binary configured for the other board, and nothing in the build
output would say so.

This is the **fourth** instance of one pattern in this feature:

| | Shared state | Failure |
|---|---|---|
| R20 | `femtosoc.*` artifact names | wrong bitstream flashed, filename says nothing |
| R21 | (process) `make \| tee` exit status | OOM-killed run reported as success |
| — | `TEST/sim_build/` | testbench silently runs another module's DUT |
| R24 | `FIRMWARE/config.mk` | firmware silently built for the other profile |

Each is a shared, mutable, unnamespaced resource whose collision is **silent**. Three of the
four have been given per-consumer namespaces (`LLM_ARTIFACT`, `SIM_BUILD/$(MODULE)`, and the
no-pipe rule for exit status). `config.mk` is left as-is deliberately: it is upstream
`learn-fpga` structure shared by every board in the repository, and per-profile config files
would be a wider change than this feature should make. **Recorded so the next profile that
needs a genuinely different firmware config knows to fix it first**, and restored to
`colorlight_i5_llm` after the regression run.

---

## R25. KV-cache stride waste (T072, 2026-08-20) — measured before any attention RTL exists

**Method**: analytical, not simulated. The waste is a pure geometry/layout fact independent of
which numeric datapath T064 eventually builds, and it is derivable exactly from facts already
established (DESIGN.md sec 7's layout/stride note) plus R19's already-measured burst-efficiency
table. A cocotb testbench would need to model the KV-cache streaming datapath to produce this
number, and that datapath does not exist yet (T064 has not started) -- building a simulation
vehicle for hardware that isn't designed would be simulating the analysis's own assumption, not
checking it. Per the task's own guidance, this is the cheaper method and it produces a fully
defensible number: the ratio below follows from division, not from anything that could differ
between implementations of the same fetch pattern. No RTL was touched, and none was added.

### The geometry, for this model

```
dim = 64, n_heads = 8, n_kv_heads = 4          (given)
head_size = dim / n_heads           = 8         elements
kv_dim    = head_size * n_kv_heads  = 32         elements
stride    = kv_dim * 4 bytes (fp32) = 128 bytes  per position   (DESIGN.md sec 7, confirmed)
BURST_LEN = 128 words = 512 bytes                (R19's decision) = 4 positions/burst
```

The KV cache is `[layer][pos][kv_dim]`: every position's 128-byte block holds all
`n_kv_heads = 4` heads' key (or value) vectors packed contiguously, 32 bytes each. A burst can
only read a contiguous byte range -- it has no way to skip the other three heads' 32 bytes out
of every 128 while it reads.

### The waste ratio -- one number, independent of burst length or position count

If the attention datapath processes **one kv_head's stream at a time** (the natural reading of
DESIGN.md sec 7's own framing, "streams the key cache" for a given head), a burst covering `P`
positions delivers `P * 128` bytes, of which only `P * 32` bytes -- that one head's slice -- is
used:

```
useful fraction = head_size * 4 / stride = 32 / 128 = 1 / n_kv_heads = 25%
wasted fraction = 75%                     ("roughly four positions' worth" fetched per head
                                            wanted was the right intuition -- it is exactly 4x)
```

This ratio is **independent of burst length and independent of how many positions are
streamed** -- it falls straight out of `head_size / kv_dim = 1 / n_kv_heads`, a property of the
tensor layout, not of the fetch mechanics. Longer bursts change SDRAM protocol efficiency (R19);
they do not change what fraction of a fetched byte is useful.

### Combined with R19: the effective delivered bandwidth

R19 measured 91.3% raw SDRAM efficiency at `BURST_LEN=128` with the CPU idle. A naive
one-kv_head-at-a-time attention fetch would multiply that by the 25% useful fraction above:

```
effective useful bandwidth = 91.3% x 25% = 22.8%
```

Attention would be spending SDRAM cycles at barely over a fifth of the roofline this whole
design is bounded by (DESIGN.md sec 2: "purely memory-bound... throughput is set by how fast
weights arrive"). Since attention's K/V-streaming phases are memory-bound the same way the
weight matmul is, this maps directly to the K-cache and V-cache streaming portions of attention
time each taking roughly **4x longer** than the bytes actually needed would require -- not a
rounding error, the dominant cost of running attention naively.

**A sharper version of the same problem, if GQA sharing is also not exploited**: `n_heads=8`
query heads share only `n_kv_heads=4` distinct key/value streams (2 query heads per kv_head). A
datapath that re-fetches per *query* head rather than per *kv_head* doubles the traffic again --
8 full-range passes instead of 4 -- for a floor of 25% useful fraction becoming an actual 12.5%
realized if that grouping is missed too. This is a separate mistake from the stride waste itself
and is called out because it is the more likely of the two to be introduced by accident if T064
is written head-by-head without checking for it.

### Recommendation: do NOT add a strided fetch mode

The 75% waste is real, but it is avoidable **without any new fetch-engine RTL and without a
strided burst mode**, because the waste is a *consumption* problem, not a *fetch* problem: all
four heads' data is already sitting in the same 128-byte block the burst delivers. If T064's
attention datapath is designed to consume **all `n_kv_heads` interleaved slices from a single
contiguous stream pass** -- running up to 4 independent dot-product accumulations (one per
kv_head, serving up to 8 query heads via GQA sharing) off the *same* fetched words, rather than
re-streaming the position range once per head -- every byte fetched becomes useful and the waste
disappears entirely. `acc_weight_fetch.v`'s burst mechanism and `muchtoremember_burst.v`'s burst
port already deliver exactly the bytes needed for this; nothing there has to change. This is
purely a requirement on T064's not-yet-written control/accumulator structure, and it should be
stated as one when that task is specified: **stream once per position range, demultiplex four
heads' worth of dot products from it, not four (or eight) separate streams.**

**What a strided fetch mode would cost, for the record, since the alternative was rejected
rather than merely not chosen**: `muchtoremember_burst.v`'s burst state machine would need a
programmable skip count (capture `head_size` words, skip `kv_dim - head_size` words, repeat) in
its column-address advance -- new state and a new register in the same FSM DESIGN.md sec 9a
already restricted to a 3-line reorder to keep changes isolated, plus the consumer side would
need to track which fetched words are "real" versus "skipped" if the FIFO write path is not also
made conditional on the same counter. That is genuinely new control logic in a controller this
project has deliberately kept minimal (research R10), for a problem the datapath-level fix above
solves at zero fetch-engine cost. Build it only if a future measurement, once T064 exists and can
actually be profiled, shows the datapath-level fix was not enough -- not before.

---

## R26. T036's scale-timing bug — root cause, fix, and a second bug it uncovered (2026-08-20)

### The bug T035/T036 exposed

`acc_top.v`'s `w_scale_q`/`x_scale_q` registers (the weight- and activation-side per-group
rescale factors fed to `acc_mac`) were re-latched from `weight_scale_mem[group_count_q]` /
`act_mem[act_xs_addr_c]` on **every** `issue_read_c` cycle, not once per group. `group_count_q`
itself already advances correctly — on a group's own last address-phase word, using the
not-yet-incremented index — but the very next address-phase cycle (the *next* group's first
word) re-reads the scale memories using the now-incremented index and overwrites the register,
one cycle before `acc_mac`'s `group_done` was ever going to consume the value that was correct.
Net effect: every group immediately followed by another group — i.e. essentially every group in
every real operation — got rescaled with the wrong (next) group's scale.

Reproduction (wq, layer 0, row 0, x_slot random int8): `mac_group_acc = 50166`, bit-exact match
to the independent Python reference, proving the integer datapath was never at fault.
`mac_row_result` came out `0x423f57a1 = 47.8356`. `50166 * w_s[1](0.004365294...) *
xs[0](0.21843788) = 47.8356` exactly — row 0 rescaled with row 1's weight scale. The correct
value, `50166 * w_s[0](0.002416676...) * xs[0] = 26.4823`, is what the fix now produces.

**Why `acc_mac.v`'s own 1000/1000 bit-exact unit tests never caught this**: they drive one group
in isolation (or, in `test_multi_group_row`, several groups fed directly by the testbench with
full control over timing). The bug only exists in the interaction between `acc_top`'s continuous,
back-to-back address-phase streaming and its own scale-register update cadence — a defect at
the integration level, invisible to any test that doesn't stream two real groups through real
`acc_weight_fetch`/SDRAM timing back to back. This is the reason Principle III (bottom-up,
unit-then-subsystem-then-integrated) exists.

**Fix**: gate the `w_scale_q`/`x_scale_q` register updates on `issue_read_c && is_group_last_c`
instead of `issue_read_c` alone, so each register only re-latches once per group, using
`group_count_q`/`act_group_idx_q` at the one cycle they are guaranteed to still hold the
completing group's own index. Verified BURST_LEN-independent: identical pass/fail behaviour
measured at BURST_LEN 64, 128 and 256 (the bug's visibility had appeared to depend on burst
length before the fix — every 8th row of `wq` matched, coinciding with the one row boundary per
burst that landed on a FIFO-empty stall — but that was burst timing coincidentally inserting the
missing settle cycle sometimes, not the actual cause; the fix works because the mechanism itself
is now correct, not because of timing).

### The second bug this fix's own verification uncovered

After the scale-timing fix, `wq` (1 group/row), `w1` (1 group/row) and the classifier (1
group/row) passed bit-exact immediately. `w2` (192x64, **3 groups/row** — the shape whose
pre-padding inner dimension caused R16) still showed 1 mismatched row out of 64, off by exactly
1 ULP: hardware produced `0xc3ec31d6 (-472.38934...)`, the reference expected `0xc3ec31d5
(-472.38931...)`.

Independent exact-arithmetic check (Python `Decimal`, computing the true infinite-precision sum
of the two real float32 operands and rounding once): the correctly-rounded IEEE754 result is
`...d5`, matching the reference — not a reference-model bug.

Traced to a real bug in `acc_mac.v`'s `fp_add32`, present since T030 and NOT triggered by
1000/1000 unit-test vectors: the subtraction path (`same_sign == 0`) aligns the smaller operand
by right-shifting and **truncating** it, tracking an `align_sticky` flag for any bits lost. For
addition this is correct — truncating the smaller addend makes the raw sum an *under*-estimate of
the true value, exactly what the guard/sticky round-to-nearest convention expects. For
subtraction it is backwards: `hi - truncate(lo)` is an *over*-estimate of the true difference,
because less was subtracted than the true value. Left as `align_sticky` OR'd into the ordinary
sticky bit, this can bias the final round-to-nearest-even decision the wrong way at exactly the
boundary this case hit (guard=1, and the old sticky computation said "round up" when the
correctly-rounded answer required rounding down). Confirmed the diagnosis by re-deriving `mag_wide`
by hand for this pair and showing the pre-rounding mantissa was already the correct answer —
only the round-up decision was wrong.

**Fix**: for the subtraction path only, when `align_sticky` indicates bits were truncated off the
subtrahend, subtract the *ceiling* of the shifted subtrahend (add 1) instead of the floor, before
computing `mag_wide`. This restores `hi - ceil(lo)` as a valid lower bound of the true difference,
which makes the existing guard/sticky rounding logic correct again for both paths. `align_sticky`
is now folded into `mag_wide`'s value for the subtraction path (not also OR'd into `sticky`,
which would double-count it) and still OR'd into `sticky` unchanged for the addition path.

**Verification**: `acc_mac_tb.py` still 7/7, still 1000/1000 bit-identical after the fix (no
regression against the existing unit suite). `acc_unit_tb.py`: `wq`, `w1`, `w2`, `classifier` all
pass bit-exact at BURST_LEN 64/128/256. `test_row_interleave_no_gap` (gs=LANES=4, the documented,
intentionally-unenforced "acc_top must not interleave a second row's groups into acc_mac before
the first row's last row_valid" contract) still fails, as expected — confirmed by inspection that
its failure mode is gross corruption (results differing by orders of magnitude, including sign
flips), the signature of accumulator cross-contamination between rows, not a residual 1-ULP
rounding issue. This is the SAME known, documented architectural limitation from T030 (`GS_MIN=4`
with `LANES=4` genuinely violates the undocumented "gs/LANES >= pipeline depth" assumption); it is
not something either of this entry's two fixes touches, and this model never uses `gs` below 64.
Left open for a design decision (raise `GS_MIN`, or add stall logic in `acc_top`) rather than
patched under this fix's scope.

### Synthesis smoke check after the fix

Per Principle I and R21/R22's own lesson ("simulation says nothing about synthesizability"),
re-ran R21's exact standalone reproducer (`share` omitted, per `BOARDS/colorlight_i5_llm.mk`'s
`YOSYS_LLM_COARSE`) against the post-fix `acc_top.v`/`acc_mac.v`, under `ulimit -v 8000000` (R21:
the unguarded run reached 21 GB RSS before being OOM-killed):

```
yosys -p "read_verilog -I. acc_top.v acc_mac.v acc_regs.v acc_weight_fetch.v;
          synth_ecp5 -abc9 -top acc_top -run begin:coarse; <YOSYS_LLM_COARSE>;
          synth_ecp5 -abc9 -top acc_top -run map_ram:end; stat"
```

**Exit status 0** (checked directly, not through a pipe — R21's own lesson), 21.7s CPU, 226 MB
peak RSS. No hang, no OOM, `share` avoidance still works on the changed logic.

| | LUT4 | CCU2C | TRELLIS_FF | MULT18X18D | DP16KD |
|---|---|---|---|---|---|
| `acc_top`, pre-fix (R21) | 2,784 | — | 1,279 | 17 | 33 |
| `acc_top`, post-fix (this entry) | 2,914 | 682 | 1,343 | 17 | 33 |
| Delta | +130 (+4.7%) | — | +64 (+5.0%) | +0 | +0 |

Both fixes are pure combinational-logic changes (an extra subtraction/mux in `fp_add32`, a
changed clock-enable condition on two registers) — no new multiplier, no new memory, matching
the small LUT/FF growth and zero DSP/BRAM change.

**Timing was NOT re-measured, and that gap matters more than the resource table above.**
`acc_top` cannot be placed standalone (236 top-level port bits against CABGA381's 197 usable
`TRELLIS_IO` — nextpnr correctly refuses; a submodule's wide internal buses are not real pins).
A real `fmax` number requires the full `femtosoc.v`-top board build R22 already ran once. R22's
build — run on the **pre-fix** RTL — found the critical path is `acc_mac.v`'s fp32 rescale itself
(`u_mac.s3_rescaled_f_q -> u_mac.row_result_q`, 35.5 ns, 28.15 MHz achieved against a 25 MHz
target — only 12.6% margin) and explicitly warned its bitstream must not be flashed because it
contained this entry's first bug. This entry's `fp_add32` fix adds a subtraction and a mux
*directly onto that same path* (the row-accumulate call in `fp_add32`, which is exactly
`s3_rescaled_f_q`'s consumer). Given the margin was already thin before any of this change,
**a full board-level timing re-close is required before the next flash, and should not be assumed
to still pass at 25 MHz** — it may well still clear, but that is a measurement to make, not an
assumption to carry forward. Whoever runs the next `colorlight_i5_llm` build (R22's "Session B")
should treat this as the first thing to check, not a formality.

### Addendum: `acc_top.v`'s own accept-time checks, added to `acc_unit_tb.py` in the same pass

fw-quant's `acc_reject_tb.py` proved `acc_regs.v` computes only three of the six error codes at
enqueue time (`ERR_DIM`, `ERR_GS`, `ERR_FULL`) — a descriptor with `n=8192` (2x `MAX_N`),
`d=65535`, or `mode=3` is pushed into the queue with no error raised at that layer. `ERR_RANGE`,
`ERR_SLOT` and `ERR_MODE` are entirely `acc_top.v`'s job (`accept_range_bad`/`accept_slot_bad`/
`accept_mode_bad` in its `S_IDLE` branch), and until this pass none of the three had been
exercised end to end through the real queue -> accept-check path.

Six new tests in `acc_unit_tb.py`, all passing:

| Test | Descriptor | Code |
|---|---|---|
| `test_reject_range_n` | n=8192 (2x MAX_N), d=1, gs=64 | `ERR_RANGE` |
| `test_reject_range_d` | n=64, d=65535, gs=64 | `ERR_RANGE` |
| `test_reject_slot_d_overflow` | n=64, d=1000 (<=MAX_D, >RESULT_SLOT_WORDS=512), gs=64 | `ERR_SLOT` |
| `test_reject_slot_bad_index` | n=64, d=1, gs=64, out_slot=8 (>=NUM_SLOTS) | `ERR_SLOT` |
| `test_reject_mode_att_score` | n=64, d=1, gs=64, mode=ACC_MODE_ATT_SCORE | `ERR_MODE` |
| `test_reject_mode_att_sum` | n=64, d=1, gs=64, mode=ACC_MODE_ATT_SUM | `ERR_MODE` |

The n=8192 and d=65535 cases each trip a second check as a side effect (both also exceed the
activation buffer's physical capacity, tripping `accept_slot_bad`) — this is expected, not a test
bug: it is exactly what verifies `accept_mode_bad > accept_range_bad > accept_slot_bad` priority
resolves correctly under real overlap, not just in isolation. `test_reject_slot_d_overflow` and
`test_reject_slot_bad_index` are constructed to isolate `ERR_SLOT` cleanly (d within `MAX_D` but
over the physical slot size; a bad slot index with everything else trivially valid).
`ACC_MODE_ATT_SCORE`/`ACC_MODE_ATT_SUM` are tested by name rather than only an arbitrary invalid
value (3), since those two are what a driver could plausibly issue by mistake today and are the
ones that must correctly flip from rejected to valid the day T064/US6 lands — a regression there
is the one this guard exists to catch.

Each test confirms three things, not just the error code: `DONE` is not also set (rejection and
completion are mutually exclusive), and `PERF_CYCLES` reads exactly 0 — proof the descriptor
never reached `S_RUNNING` at all, not merely that an error bit happened to be set alongside a
partial run.

---

## R27. Hardware session plan — two bitstreams, and one the R20 fix destroyed (2026-08-20)

### The R20 rename overwrote the feature-003 bitstream

R20 renamed this profile's artifacts to `femtosoc_llm.*` so the two profiles would stop
colliding. That name was **already occupied**: `femtosoc_llm.bit` dated 2026-08-18 was feature
003's working minimal-SoC image, produced by the manual `cp femtosoc.bit femtosoc_llm.bit` step
the rename replaced. The first accelerator build overwrote it.

No real loss — it regenerates by building this profile with `NRV_IO_ACCEL` undefined — but worth
recording plainly: **the fix for a filename collision collided with a file.** A rename that
claims a name should check whether anything is standing there. Recorded rather than quietly
rebuilt, because "the bitstream on disk is not the one its name implies" is precisely the class
of failure R20 exists to prevent, and it happened once more on the way to preventing it.

### Two bitstreams, deliberately

| Bitstream | `NRV_IO_ACCEL` | Fmax | Used by |
|---|---|---|---|
| `femtosoc_llm_soft.bit` | undefined | 40.76 MHz (R14/003) | **Session A** — T022-T026 |
| `femtosoc_llm.bit` | defined | 28.15 MHz (R22) | **Sessions B and C** — T053+ |

Session A validates the Q8_0 **software** path, which is the golden reference every later
hardware result is compared against. Running it on the accelerator bitstream would work — the
accelerator is an idle peripheral that `runq.bin` never issues to — but it would put the
reference measurement on a build with 12.6% timing margin. If Session A then disagreed with the
host transcript, "quantization port bug" and "marginal timing" would be indistinguishable, and
the reference would be the thing in doubt. Building the no-accelerator image costs one
synthesis run and removes that ambiguity entirely.

**Session A is otherwise unblocked** and does not wait on the scale-timing fix. Its only missing
prerequisite is the physical card copy left over from T021.

### Session B must distinguish intermittent from consistent failure

At 12.6% margin this matters more than usual. A **consistent** bit-exact mismatch is a logic bug;
an **intermittent** one is timing. They call for entirely different next steps, and on a single
run they look identical. `acc_test.c` should therefore repeat its comparison many times and
report whether failures are stable, rather than reporting one pass or fail — that turns an
ambiguous session into a diagnostic one, at no extra operator cost.

---

## R28. Display-profile regression PASSES (T047/T056/T078, measured 2026-08-20)

`make colorlight_i5.synth` after every shared-RTL change in this feature. Exit status **0**
(checked directly, not through a pipe), nextpnr "Program finished normally".

| | T006 baseline | Now | Delta |
|---|---|---|---|
| LUT4 | 13,937 (57%) | **13,825 (56%)** | **-112** |
| DP16KD | 40/56 (71%) | 40/56 (71%) | 0 |
| MULT18X18D | 15/28 (53%) | 15/28 (53%) | 0 |
| EHXPLLL | 2/2 | 2/2 | 0 |
| Max frequency `clk` | 32.6 MHz | **33.33 MHz** | +0.73 |
| `clk_pixel` | — | 55.71 MHz (PASS at 25) | — |
| `clk_tmds` | — | 352.61 MHz (PASS at 125) | — |

**SC-014 satisfied**: the full-featured configuration still builds, with memory and multiplier
usage bit-identical to the baseline and timing slightly better.

The -112 LUT delta is worth naming rather than rounding away as noise. The display profile's
own RTL did not change — every accelerator addition in `femtosoc.v` sits behind
`ifdef NRV_IO_ACCEL`, which this profile does not define. What *did* change underneath it is
**`RTL/SDRAM/muchtoremember_burst.v`**, which both profiles share: this feature added the
`CPU_PRIORITY` and `STARVE_LIMIT` parameters and the `starve_guard_fired` output. With
`CPU_PRIORITY` defaulting to 0 the behaviour is the original burst-first arbitration, but the
restructuring evidently let the synthesizer fold a little logic it previously could not.

A change that makes a shared module **smaller and faster** is the benign direction, and the
behavioural equivalence is what R23's `burst_len=64` cross-check against R19's original numbers
was for. But it is a real difference in a module the working display profile depends on, and
recording it as "no change" would have been wrong. The only thing that would settle it
completely is running the display profile on hardware — not part of this feature's scope, and
flagged here so it is a known open item rather than an assumed one.

---

## R29. Post-fix timing FAILS — 23.55 MHz against a 25 MHz target (measured 2026-08-20)

Board build on the fixed RTL (R26's scale-timing and fp32-subtraction fixes). `make
colorlight_i5_llm.synth` exit 0, nextpnr "Program finished normally", and:

```
Max frequency for clock '$glbnet$clk': 23.55 MHz (FAIL at 25.00 MHz)
```

| | Pre-fix (R22) | Post-fix | |
|---|---|---|---|
| LUT4 | 13,183 (54%) | 13,448 (55%) | +265 |
| DP16KD | 49 (87%) | 49 (87%) | 0 |
| MULT18X18D | 25 (89%) | 25 (89%) | 0 |
| **Max frequency** | **28.15 MHz PASS** | **23.55 MHz FAIL** | **-2.66** |

**mac-unit was right to refuse to assume this.** It flagged that the `fp_add32` fix adds a
subtraction and a mux directly onto the path R22 had already identified as critical, declined to
call the fix complete without a board build, and asked for one. That judgement is the reason
this was caught before an operator session rather than during one.

### The path, and why it is not only logic depth

```
... -> accel_inst.u_mac.s3_row_first_q ... -> accel_inst.u_mac.row_result_q
14.5 ns logic, 28.0 ns routing   (42.5 ns total, against a 40 ns period)
```

It is the **same path as before the fix** — same source register, same sink, same `fp_add32`
accumulate. Nothing moved; the existing critical path simply got longer:

| | Pre-fix | Post-fix | Delta |
|---|---|---|---|
| Logic | 11.3 ns | 14.5 ns | +3.2 (+28%) |
| Routing | 24.2 ns | 28.0 ns | +3.8 (+16%) |
| Total | 35.5 ns | 42.5 ns | +7.0 |

**Routing is roughly two-thirds of the delay — and it was already two-thirds before the fix.**
That is worth stating carefully, because an earlier draft of this entry treated it as a new
observation that "reframes the problem". It does not: 24.2 versus 11.3 ns was the pre-fix split
too. The design has been routing-dominated all along, which is what 87% BRAM and 89% DSP
occupancy produces.

That still matters for choosing the fix, just not as a change. Inserting a pipeline register
mid-path splits **both** halves — each stage carries roughly half the logic and half the routed
span — so pipelining does address the routing term, not merely the logic one. A 42.5 ns path
split evenly across two stages lands near 21 ns, comfortably inside the 40 ns period.

So the fix is **two changes, not one**:

**1. Pipeline the fp32 rescale (`acc_mac.v`).** The rescale runs once per group of GS=64
elements — 16 cycles at LANES=4 — and is built as single-cycle combinational logic. Splitting it
across even two or three stages costs nothing in throughput. This is the third distinct symptom
of the same root cause, after R21's non-terminating `share` pass and the 13-of-17 DSP
consumption.

**2. Shrink the oversized BRAMs.** `ACT_AWIDTH` and `RESULT_AWIDTH` are both 12, sized from
`MAX_N`/`MAX_D` of 4096, while this model's `n` and `d` never exceed 512. The naive fix of
dropping them to 11 is **wrong** and worth recording so nobody tries it: with `NUM_SLOTS=8` that
gives 2048/8 = 256 words per slot, and the classifier needs d=512 fp32 values — it would
silently overflow its slot, or trip `ERR_SLOT` if the check is right. The sound version reduces
slots and width together:

| | Now | Proposed | Words/slot | Needed |
|---|---|---|---|---|
| Result | `AWIDTH 12`, 8 slots | `AWIDTH 11`, 4 slots | 512 | 512 (classifier d=512) |
| Activation | `AWIDTH 12`, 8 slots | `AWIDTH 10`, 4 slots | 256 | 136 (n=512 int8 + 8 scales) |

That returns roughly 10 of the 49 BRAMs. `NUM_SLOTS` is visible to the driver, so it is a
contract change, not just a parameter tweak.

### Consequence

**The accelerator does not currently close timing, and no hardware session can use this
bitstream.** Session A is unaffected — it runs the software path on a no-accelerator build at
40.76 MHz (R27) — but Sessions B and C are blocked until timing closes. This is no longer a
recommendation to consider; it is required work.

---

## R30. ACC_GS_MIN raised 4 -> 8, derived and empirically verified; a THIRD instance of the fp_add32 bug found in the process (2026-08-20)

### GS_MIN: what was actually true, versus two guesses

`ACC_GS_MIN=4` was a leftover from before hidden_dim padding (research R16): the unpadded
model's `hidden_dim=172` forced a tiny group size. Padding to 192 removed that constraint and the
model has used `gs=64` exclusively since — `GS_MIN=4` was doing nothing but *permitting* a
configuration `acc_top.v` cannot execute correctly (`test_row_interleave_no_gap`, added in the
T028-31 pass, demonstrated `gs=LANES=4` produces gross, orders-of-magnitude-wrong results).

Two guesses existed for the correct minimum, and both were checked empirically rather than
trusted, per the team lead's explicit instruction ("you know the exact depth; I don't want to
guess"):

- `acc_mac.v`'s own header comment guessed **gs/LANES >= 5** (the rescale pipeline's group_done
  -> row_valid depth).
- The team lead's own estimate, offered with the same caveat, was **gs=32**.

Neither is what the hardware actually requires. Traced cycle-by-cycle with a cocotb probe
(`group_row_first_q`/`s1..s3_row_first_q` at every pipeline stage, `gs=LANES=4`): the row-first
tag threads through `acc_mac`'s rescale pipeline correctly at every stage, every cycle, even at
the tightest possible cadence. That pipeline is a strict in-order shift register — two tokens
cannot collide in one stage regardless of injection rate — so the 5-cycle-depth theory was
solving a hazard that does not exist.

The REAL mechanism, found by tracing `mac_group_acc`/`mac_row_result` values (not just tags)
alongside the T036 scale-timing fix: `acc_top.v`'s `w_scale_q`/`x_scale_q` only re-latch on a
group's own last address-phase word (gated on `is_group_last_c`, using `group_count_q` one cycle
before it advances — the T036 fix). That gating buys exactly **one** settle cycle between "this
group's scale becomes correct" and "the next group's scale read could overwrite it". At
`gs == LANES` (a group is exactly one address-phase cycle wide), there is no settle cycle at all
— every cycle is simultaneously the last word of its own group and the first word of the next, so
the T036 fix's protection never engages. At `gs == 2*LANES`, the settle cycle exists and the race
provably cannot occur.

**Bound: gs/LANES >= 2, i.e. ACC_GS_MIN = 2*LANES = 8** for the current LANES=4. Recorded in
`acc_bits.vh`'s comment with the full derivation and an explicit note that raising LANES later
requires re-deriving (and re-verifying) this, not just recomputing by formula.

**Empirical verification** (`acc_unit_tb.py`'s `_row_interleave_case`, n=2*gs/d=4, sweeping
seeds): gs=4 (old minimum) fails every single trial, with mismatches in the billions when
compared as raw uint32 bit patterns — gross corruption, not rounding. gs=8 (new minimum): clean
across 25 trials once the fp_add32 fix below was also in place. gs=64 (the model's actual value):
clean across at least 32 trials (a 40-trial run was killed by the harness's own command timeout
partway through, all 32 completed trials clean) for the same reason. `test_row_interleave_no_gap`
is retired and replaced by two tests: `test_row_interleave_at_gs_min` (gs=ACC_GS_MIN, 8 trials,
proves the new boundary is safe rather than assumed) and `test_row_interleave_below_gs_min`
(gs=ACC_GS_MIN//2=4, confirms it is now rejected end-to-end with `ACC_ERR_GS`, `PERF_CYCLES=0`).
fw-quant's `acc_reject_tb.py` already had `test_err_gs_below_minimum` computing its expected value
from a mirrored `ACC_GS_MIN` Python constant — updated 4 -> 8 in that file to match, with a
comment tying it back to this entry so the two constants cannot silently drift apart again.

### A third instance of the fp_add32 bug — found by the same GS sweep, at gs=64

The GS sweep's job was timing, not arithmetic, but at `gs=64` (2 groups/row in the sweep's
n=2*gs construction) it turned up an ARITHMETIC mismatch: row result off by exactly 1 in the raw
`uint32` bit pattern — the same signature as R26's `fp_add32` subtraction bug, and the *R26 fix
committed to date did not prevent it*. Confirmed independently via exact `Decimal` arithmetic:
hardware (and a faithful Python port of the committed `fp_add32`) produced `0x48388ed8`; the
correctly-rounded IEEE754 answer is `0x48388ed9`.

**Why the committed R26 fix was insufficient**: it corrects `mag_wide`'s VALUE (subtract the
ceiling of the truncated subtrahend instead of the floor) but the amount by which that ceiling
adjustment itself is inexact — a fraction strictly between 0 and 1 ULP at the subtrahend's own
LSB — is not represented by any bit the algorithm still examines. It lives below the one bit
position the ceiling adjustment just consumed. Reading `norm_field`'s own low bits for `sticky`
after that point sees whatever they happen to be, uncorrelated with whether real precision was
lost. The committed fix happened to produce the right rounding decision for R26's original
reproduction case; this new case shows it does not do so in general.

**Corrected fix**: use the plain floor-based subtraction (no value adjustment), then — only when
`align_sticky` — decrement the whole difference by one ULP (ordinary integer subtraction, which
correctly ripple-borrows across any run of zero bits) and treat `sticky` as unconditionally 1 from
that point, regardless of the decremented value's own low bits. This is exact: `true_diff =
decremented + (some fraction in (0,1))`, so `decremented` is a valid lower bound AND there is
provably nonzero weight below it — the fact the ceiling approach could not establish. Verified
against BOTH known failing cases (R26's original row-56/w2 case and this new gs=64 case) with a
faithful Python port of the corrected Verilog: both now bit-exact. Cannot underflow past zero:
`pick_a` guarantees `true_hi >= true_lo`, so the floor-based difference is provably >= 1 whenever
`align_sticky` triggers the decrement (the degenerate case would require `true_lo <= floor(lo) <
true_lo`, a contradiction).

**Status: committed.** Flagged directly to the team lead before committing, since at the time of
discovery the team lead was believed to be mid-pipelining-analysis on R29 against the OLD
(ceiling-based) version of this exact function — turned out nothing had actually been pipelined
yet (R29 was a measurement and proposal, not work in progress), so there was no in-flight split to
invalidate. Landed together with the `ACC_GS_MIN` work below. `acc_mac_tb.py` and `acc_unit_tb.py`
both re-run clean against the corrected version (see the final counts at the end of this entry).
R29's critical-path and resource numbers describe the superseded (ceiling-based) version and will
be re-measured against this one before any pipelining decision is made.

### Three bugs in one hand-rolled fp32 datapath — what that's evidence of

Across this feature's `acc_top.v`/`acc_mac.v` work: an unimplemented-mode fallthrough (`ERR_MODE`,
found in T034/T038's descriptor-validation pass), a scale-register settle-time race (T036, this
document's R26), and two successive rounding bugs in the same 40-line `fp_add32` function (R26's
original, then this entry's). The first two are control-logic bugs — ordinary integration bugs
this project's own bottom-up-verification principle exists to catch, and it did. The fp32 bugs are
a different kind of thing: `fp_add32` was unit-tested (1000/1000 bit-exact random vectors) BEFORE
either bug was found, and passed. Both needed real, chained, multi-group matmul data to surface —
random sampling is structurally weak at finding rounding-boundary defects, because landing exactly
on a rounding boundary (guard=1) is rare among uniform random operands, and landing there WITH
`align_sticky=1` (the specific condition both bugs lived on) rarer still. Two bugs in the same
function, both invisible to 1000 random trials, both found by accident while testing something
else (T036's timing, then this entry's GS sweep) — that is worth treating as a property of the
approach, not of the two specific defects, now that they are both fixed.

**Recommendation: repair, don't restructure — but change how the datapath gets tested, not just
what it computes.** Three considerations, in order of how much they mattered to this conclusion:

1. **A full rewrite cannot avoid hand-rolled IEEE754 arithmetic entirely.** Bit-exactness against
   runq.c's `float`-typed, per-group-rounded accumulation (`val += (float)ival * w_scale *
   x_scale`, one rounding step per group, not one at the end) is the explicit design requirement
   (constitution Principle IV; DESIGN.md sec 3.5's whole argument for int8 over fp16 rests on
   exact reproducibility). A wider-precision accumulator that rounds to float32 only once at the
   row's end would be MORE accurate and LESS work to build correctly, but would stop matching the
   reference bit-for-bit — trading the one property this design exists to have for less code. The
   constraint that makes this function hard to get right also makes it impossible to route around.
2. **The corrected algorithm is now the textbook one, not an invented one**, per the team lead's
   own framing of the lesson: "matching a known-correct algorithm beats inventing one." The
   original bug was inventing an ad hoc value adjustment (subtract the ceiling); the fix is the
   standard technique (decrement-and-force-sticky) with a clean, provable correctness argument
   (`decremented` is a valid lower bound AND certainly has nonzero weight below it). That argument
   did not exist for either previous version of this code. A rewrite would be re-deriving
   something that, this time, is already derived correctly and provably.
3. **What actually failed was verification coverage, not the algorithm's shape.** `i2f32`,
   `fp_mul32` and the ADDITION half of `fp_add32` have shown no defect across 1000+1000+2 bit-exact
   trials plus every integration test in this feature. Only the SUBTRACTION path, and only at the
   `align_sticky=1` boundary, was wrong — twice, because the first fix addressed the value without
   addressing the missing sticky information, and nothing in the test suite was constructed to
   land there.

**Action taken, not just recommended**: `acc_mac_tb.py` gained two new tests targeting exactly
this gap: `test_fp_add_same_sign_ties` (five ival pairs engineered — via direct simulation of
`fp_add32`'s own guard/sticky logic in Python, not random sampling — to land on a same-sign
rounding boundary) and `test_fp_add_known_bug_reproductions` (verbatim replays of both real bug
cases as permanent regressions, asserting the exact previously-wrong hex values are what is now
produced). Both pass bit-exact. **Left for a future pass, not done here**: the equivalent
engineered search for opposite-sign (subtraction) boundary cases came up empty after 2,000,000
targeted random trials constrained to realistic magnitudes and `exp_diff` in [1,8] — confirming,
again, how rare this boundary is to hit by sampling even when deliberately aimed at it. Closing
that gap needs a DETERMINISTIC sweep (iterate `exp_diff` 0..27 exhaustively, and within each,
search mantissa bit patterns directly for guard=1/align_sticky=1 rather than hoping random
operands land there) rather than more random trials of any kind. Worth doing before extending
`fp_add32`/`fp_mul32` to any new caller, not worth blocking this fix on.

Final counts after all of R30's changes: `acc_mac_tb.py` 9/9 (7 original + the two new boundary
tests), `acc_unit_tb.py` 12/12, `acc_reject_tb.py` 14/14. No regressions anywhere.

---

## R31. Corrected fp_add32 restores timing — barely. 25.61 MHz, 2.4% margin (2026-08-20)

Board build on 1157047 (the textbook decrement-and-force-sticky subtraction). Post-routing:

| Build | Fmax | Margin | Verdict |
|---|---|---|---|
| Pre-correctness-fixes (R22) | 28.15 MHz | 12.6% | PASS |
| First `fp_add32` fix (R29) | 23.55 MHz | — | **FAIL** |
| Corrected `fp_add32` (this) | **25.61 MHz** | **2.4%** | PASS |

LUT4 13,549 (55%), DP16KD 49 (87%), MULT18X18D 25 (89%) — resources essentially unchanged.

The simpler formulation recovered 2.06 MHz and crossed back over the line, confirming that the
correct algorithm is also the cheaper one. But 2.4% is not a margin to take to hardware:

- The 256-entry SDRAM cache was **rejected** by this project at 28.4 MHz — a 13.6% margin.
  25.61 MHz is far below the figure already judged unacceptable, and this time the comparison is
  decisive rather than the near-tie R22's corrected figure produced.
- UART flakiness in this project was previously traced to exactly this class of margin, and
  presented as a peripheral fault rather than as a timing problem.

Critical path is unchanged in shape — `u_mac.s3_rescaled_f_q -> u_mac.row_result_q`, the
`fp_add32` accumulate — at **13.1 ns logic, 26.0 ns routing** (39.1 ns against a 40 ns period).

### Routing is two-thirds of it, which changes what to try first

Every build in this series has been routing-dominated: 24.2/11.3 pre-fix, 28.0/14.5 with the bad
fix, 26.0/13.1 now. Congestion, not logic depth, is the larger term — and 87% BRAM with 89% DSP
occupancy is what produces it.

That argues for attacking **congestion before depth**, reversing R29's ordering:

1. **BRAM sizing (low risk, attacks the 26.0 ns term).** `ACT_AWIDTH`/`RESULT_AWIDTH` are 12,
   sized for `MAX_N`/`MAX_D` of 4096; this model never exceeds 512. Reducing width and slot
   count together — result to `AWIDTH 11`/4 slots (512 words/slot, exactly the classifier's
   d=512), activation to `AWIDTH 10`/4 slots (256 words/slot against 136 needed) — returns about
   10 of the 49 BRAMs. This is a parameter and contract change, not a logic rewrite, and it can
   be measured in one synthesis run.
2. **Pipelining the rescale (higher risk, attacks the 13.1 ns term).** Splits both halves per
   stage and would give large margin, but it is a rewrite of a block that has just produced
   three bugs and is only now stable. Worth doing if step 1 is insufficient — and much easier to
   trust now that 35 tests, including bit-exact real-data checks, exist to validate against.

**Do the cheap, low-risk one first and measure.** If congestion relief alone restores a
double-digit margin, the pipelining rewrite is unnecessary.

---

## R32. Deterministic fp_add32 boundary sweep — 540 constructed cases, clean result (2026-08-20)

R30 flagged, as follow-up rather than done: the two real `fp_add32` bugs were found by real
matmul data, not by 1000+2,000,000 random trials, because landing on a rounding boundary (guard=1)
is rare by chance and landing there with `align_sticky=1` (the exact condition both bugs lived on)
rarer still. Requested explicitly: replace sampling with enumeration.

**Method**: `acc_mac_tb.py`'s new `test_fp_add_boundary_sweep`, built the same way as R30's
same-sign tie tests -- construct exact operand bit patterns directly, not search for them.
`i2f32(ival)` is exact and mantissa-transparent whenever `ival = sign * ((1<<23)|pattern)`
(msb_pos always exactly 23, no internal rounding), which gives full independent control of one
operand's sign and 23-bit mantissa at a fixed exponent (150). Multiplying by an exact power of
two (`w_scale = 2.0**k`, verified directly against `fp_mul32`'s own zero-mantissa special case
before trusting it) shifts that operand's exponent by `k` with zero additional rounding, giving
independent exponent control for the second operand -- i.e. independent, exact control of
`exp_diff` and both mantissas, with no randomness anywhere in the construction.

**Stated coverage** (the sweep's own header comment carries this, so it travels with the code):
`exp_diff` -- every value 0 through 28 inclusive, plus 35 as a deliberate `>27` check -- is the
ENTIRE meaningful range for this algorithm's 27-bit internal representation, not a sample of it.
Three representative mantissa patterns per operand (`0x000000` exact-power-of-two, `0x700000`
near-maximum reachable by a real GS<=1024 group, `0x000001` minimal-nonzero), crossed 3x3, chosen
because `align_sticky` is a BOOLEAN ("was anything nonzero truncated") rather than a magnitude, so
these three exhaust the boolean space the algorithm's branches actually depend on ("nothing below
the shift boundary", "everything below it", "exactly one bit below it") even though they are not
exhaustive over the full 2^23-per-operand numeric space. Both `same_sign` values, fully. NOT
covered, explicitly: full numeric mantissa exhaustion, and subnormal/inf/NaN operands (out of
scope for this whole module by design -- flush-to-zero-on-underflow is the documented behaviour,
and this application's real operands never approach those ranges). 29*2*9 + 1*2*9 = 540 cases
total, every one fed through real hardware via `decompose_ival` (the same int8-vector construction
`test_fp_add_known_bug_reproductions` uses), not injected as raw bits.

**Result: clean. 540/540 bit-exact against the numpy float32 reference, zero additional defects.**
This is the answer to the team lead's second question, not just the first: the corrected
subtraction is exact across the boundary region enumerated here, not merely at the two points that
happened to be hit by real data. `acc_mac_tb.py` is now 10/10 (7 original + 3 from R30/R32), no
regressions.

**What this sweep is, and is not, evidence of.** It is a strong result for the specific hazard it
targets (guard/sticky/align_sticky interaction across the full `exp_diff` range) and should be the
reference the next person re-derives from if `LANES`, `ACC_WIDTH`, or `fp_add32` itself changes --
re-running it costs about a minute (69s wall time for all 540 cases) and directly answers "is the
adder still exact" without needing new hardware data to get lucky again. It is not a claim of
exhaustive correctness over the full IEEE754 binary32 space; the 540 cases are a stated, bounded
subspace chosen for relevance to this algorithm's actual branch structure, and the sweep's own
docstring says so rather than leaving that judgement to be inferred from a raw pass count.

---
