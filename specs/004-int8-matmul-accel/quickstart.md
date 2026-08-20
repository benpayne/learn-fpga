# Quickstart: int8 MatMul Accelerator

**Branch**: `004-int8-matmul-accel`

How to get from a clean checkout to accelerated generation. Steps marked **[HW]** need the
board; everything else runs on the host.

This feature builds on `003-llama2-minimal-soc`. If that quickstart does not work first, fix
that before starting here.

**Status as of this writing (2026-08-20, T073/T076)**: Stages A and B are measured and pass.
Stage C has synthesized once (T050) with real resource/timing numbers below, but **the
resulting bitstream computes wrong answers** (research R22 — see the warning in Stage C) and
must not be flashed expecting correct output. Stage D has not been run on hardware at all: it
is blocked on the R22 fix, and its numbers below are still the design document's *projections*,
not measurements. Say so explicitly if you re-run this and something has changed underneath
you.

---

## Stage A — quantize and validate in software (no hardware changes)

This stage exists to answer one question: **does 8-bit quantization ruin output quality on this
very small model?** Answer it before building anything. It has been answered — see step 4 — but
the steps below still reflect exactly what you get from a fresh run.

### 1. Quantize the model (host)

```bash
cd FemtoRV/FIRMWARE/llama2/tools
./quantize_model.sh
```

**MEASURED (research R18, 2026-08-20)**: produces a **299,008-byte** Q8_0 checkpoint against a
**1,056,540-byte** fp32 original — ratio **0.283**, comfortably under SC-003's 1/3 ceiling.
sha256 `759d06bf4228772cc9cd73512801c5402753bc8d8a5de96fda1765de09e86c28`. Group size: **64, no
backoff**.

This is NOT simply "every tensor happens to be a multiple of 64" — an earlier, wrong version of
this section claimed that. The real story (research R16, R18) is worth knowing before you read
a surprising number from your own run:

- Two *different* divisibility requirements exist. `export.py`'s own assertion only checks that
  each tensor's total element count is a multiple of `group_size`. That is not sufficient: the
  accelerator (and `quantize()`/`matmul()` themselves) also need `dim % GS == 0` **and**
  `hidden_dim % GS == 0`, because those are the two dimensions groups actually span across.
  Nothing in upstream `export.py` checks the second condition.
- This model's native `hidden_dim` is **172** — not a multiple of 64, 32, 16, or 8 (172 = 4 x
  43, and 43 is prime). Quantizing at GS=64 against a stories260K-shaped checkpoint with no
  further change produces a checkpoint that loads fine, matches every size/header check, and
  then **generates degenerate, repeated-token garbage** ("there there there...") — the
  silent-wrong-output failure class this whole project exists to catch. It was caught only by
  reading the generated text, not by any size or checksum check. **Trust generated text over
  header arithmetic.**
- The fix, implemented in `quantize_model.sh`: zero-pad `hidden_dim` from 172 to **192** before
  quantizing (`PAD_HIDDEN_TO` env var, default 192; set it to `0` to disable padding and fall
  back to the old GS=4 behaviour, or to another multiple of 64 to try a different pad). Padding
  costs **+11.6%** more FFN weight bytes (w1+w2+w3 per layer: 33,024 -> 36,864 elements) but
  recovers GS=64 (and with it the accelerator's full 4-lane datapath — see R16), and the size
  and quality numbers above already include this padding. `runq_host.c`/`run_host.c` needed no
  change for this; it is entirely a converter-side transformation.

Record the size, checksum and group size your own run reports, and compare against the figures
above — if they differ, something upstream of quantization changed and the rest of this
document's numbers may no longer apply.

### 2. Generate the golden reference (host)

```bash
./runq_host model.q8.bin tokenizer.bin --seed 2026 --steps 110 -i "Once upon a time"
```

**The `-i "Once upon a time"` is required** (T076 finding) — an earlier version of this command
omitted it. Without it, `prompt` defaults to `NULL` (empty string), and you get a real but
*different* generation ("One day, a little boy named Timmy was playing with his toys...") that
will not match step 4's quoted text or anything Stage D compares against. Confirmed by actually
running both forms: only the `-i` version reproduces the exact golden-reference text below,
byte for byte.

Keep this output. Every later stage compares against it.

### 3. Run it on the board **[HW]**

Copy the quantized model to the SD card as **`/model.q8.bin`** (and the matching
**`/tokenizer.bin`**, unchanged from feature 003) — those are the exact paths `runq.c`'s
`main()` requests via `ml_load_model_q8()`/`ml_load_tokenizer_q8()`, and nothing here defaults
or searches for them. Then build and upload the **quantized** firmware:

```bash
(cd FemtoRV/FIRMWARE/llama2 && make upload-runq)
```

**Not `make upload`** — that target links and uploads `llama2.bin`, the fp32 build from feature
003. This directory produces three distinct firmware images and it is easy to run the wrong one
silently (see Troubleshooting):

| Target | Binary | What it runs |
|---|---|---|
| `make upload` | `llama2.bin` | fp32, software only (feature 003 baseline) |
| `make upload-runq` | `runq.bin` (77,396 B) | Q8_0, software matmul only — **this step** |
| `make upload-runq-accel` | `runq_accel.bin` (78,004 B) | Q8_0, matmul on the accelerator (Stage D) |

### 4. Make the go/no-go decision

**MEASURED and DECIDED (research R17/R18, T014): GO, the 8-bit path.** Teacher-forced KL
divergence against the fp32 model, over the padded GS=64 checkpoint above:

| Metric | Value | SC-002 threshold |
|---|---|---|
| mean KL | **0.000977 nats** | < 0.01 — passes by ~10x |
| top-1 agreement | **100.00%** | > 95% |

**The method matters more than the number.** The first attempt let both models generate freely
from the same seed and compared logits position-by-position — mean KL **7.77 nats**, 34%
top-1 agreement, a catastrophic-looking result that would have failed the gate outright. It was
an artifact: the instant the two models sample one different token they are processing
different text, and every later position is incomparable — the measurement was capturing
sequence divergence, not quantization error. The correct method is **teacher-forcing**: feed
both models an identical long prompt and compare only the positions both actually saw. Same
model pair, same files, correct method: 0.000977 nats instead of 7.77, a difference of four
orders of magnitude. `tools/kl_compare.py` documents this at its own top. **If you re-run this
gate, teacher-force it, or you will get a confident, plausible, and completely wrong answer.**

Generated sample (GS=64, padded, this checkpoint):

> Once upon a time, there was a little girl named Lily. She loved to play with her toys and her
> friends. One day, Lily found a new toy in her box. She went to the store and put the toys on
> her toy. She closed it in her hand, people hold a big brown rock. Lily tried to pull it

Compare against the fp32 reference from feature 003 (a *different* sample, as expected — greedy
decode over int8 logits is not required to reproduce the fp32 token stream, only to stay
linguistically coherent, which it does):

> Once upon a time, there was a little girl named Lily. She had a jolly apple that she loved to
> play outside. One day, she went to the park with her mom. She saw a big box

Both are coherent English in the same register. **If your own run diverges from this** (garbled
output, repeated tokens, or KL well above the table): stop and treat it as a real regression,
not noise — do not assume the original GO decision still applies to a changed checkpoint.
**If you are validating a different model and it collapses**: switch to 16-bit floating point,
per FR-004a, before any hardware exists — that fallback is far more disruptive once hardware
does exist, since it changes the arithmetic base for every later bit-exact comparison.

Record the decision and the evidence either way (FR-004b).

**Activation quantization cost (research R2)**: this is new scalar work the int8 path adds that
the fp32 path never needed — `profile.c`'s `PROF_QUANT` category exists specifically to measure
it (`runq.c`'s `do_matmul_q8()`/`forward_q8()` wrap every `quantize_activations()` call in
`prof_begin(PROF_QUANT)`/`prof_end(...)`). **Not yet measured on hardware** — that requires a
completed board run of `runq.bin`, which Stage D's blockers (see below) have not reached. Record
it once a run completes.

---

## Stage B — prove the accelerator in simulation (no hardware)

```bash
cd FemtoRV/TEST
make MODULE=acc_mac_tb    SIM=icarus     # arithmetic unit alone
make MODULE=acc_unit_tb   SIM=icarus     # full unit against a simulated memory
make MODULE=acc_arb_tb    SIM=icarus     # memory sharing under synthetic CPU load
make MODULE=acc_reject_tb SIM=icarus     # descriptor rejection paths (T038 -- partial, see below)
```

Every one of these must be **bit-identical** to the host reference. Integer arithmetic makes
that an unambiguous pass/fail — there is no rounding to argue about.

**`acc_reject_tb` is HALF the story, not the whole thing (T038 finding).** It targets `acc_regs.v`
directly and fully proves three of the six error codes end to end: `ERR_DIM` (n%gs!=0),
`ERR_GS` (unsupported group size), and `ERR_FULL` (queue back-pressure, including that it
recovers after a pop and is not a stuck condition). The other three — `ERR_RANGE` (n/d beyond
configured maxima), `ERR_SLOT` (result/activation slot overflow), and `ERR_MODE` (an
unimplemented mode, e.g. an attention mode before it exists) — are computed entirely inside
`acc_top.v`, not `acc_regs.v`; `acc_reject_tb` can only prove `acc_regs.v` correctly *latches
and reports* those codes when told to, not that `acc_top.v` actually detects the real
conditions that should produce them. That detection path is not yet exercised by any
testbench — it is `acc_unit_tb.py`'s open item, tracked separately from this quickstart.

**MEASURED burst length decision (research R19, T041)** — `acc_arb_tb` produces the real
version of the burst-length trade-off table; use it, not the design document's estimate, which
was wrong by 8-13 percentage points at every burst length (it modeled bare CAS setup, not full
burst-to-burst SDRAM protocol overhead including tRP recovery and row crossings):

| Burst | Idle efficiency | SC-006 (>=90%) | CPU worst-case wait (heavy load) |
|---|---|---|---|
| 64 | 85.7% | **FAIL** | 57 cyc |
| **128 (shipped)** | **91.3%** | **PASS** | **48 cyc** |
| 256 | 94.8% | PASS | 179 cyc |

**BURST_LEN=128** — not just the smallest burst that clears SC-006, but also the one with the
*lower* CPU worst-case wait versus 64 (48 vs 57 cycles), so it wins on both axes rather than
trading one for the other. Under sustained heavy CPU contention (one request per ~20 cycles) the
CPU's worst-case wait measures **exactly 128 cycles — one burst length, no more** (research
R23, SC-007 PASS), and accelerator efficiency degrades smoothly (91.3% idle -> 90.4% light load
-> 87.5% heavy load, SC-008 PASS) rather than collapsing. The anti-starvation guard fires zero
times at every realistic load tested and 42 times under an artificial every-cycle CPU hammer
that would otherwise starve the accelerator to 0% — confirming it works without being needed in
practice.

---

## Stage C — accelerator on hardware, in isolation **[HW]**

```bash
cd FemtoRV
make colorlight_i5_llm.firmware_config
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth
openFPGALoader -c cmsisdap -v --file-type bin femtosoc_llm.bit

(cd FIRMWARE/examples && make upload_acc_test)
```

**No `cp femtosoc.bit femtosoc_llm.bit` step** — an earlier version of this document had one,
left over from before research R20's fix. `colorlight_i5_llm.synth` now writes
**`femtosoc_llm.bit`** directly (its own artifact basename, distinct from the display profile's
plain `femtosoc.bit`), specifically so the two profiles' bitstreams can coexist and are
self-identifying rather than silently overwriting each other (R20: two builds writing the same
filename means "the flashed bitstream is whichever profile ran last," and a wrong-profile board
looks like a hardware fault, not a build accident).

`FIRMWARE/examples/acc_test.bin` (10,632 B) computes one matrix multiply and compares it against
a CPU-computed reference, entirely standalone (no SD card, no language model) — a failure here
is unambiguously the accelerator, not something upstream of it. Record the performance counters
it prints (`PERF_CYCLES`/`PERF_STALL`/`queue_depth`): achieved words/cycle and the stall ratio.

### *** DO NOT FLASH THE CURRENT BITSTREAM EXPECTING CORRECT OUTPUT ***

**MEASURED (research T050/R22, 2026-08-20)**: `colorlight_i5_llm.synth` succeeds and produces a
real bitstream —

| Resource | Baseline (003) | With accelerator | Device | SC-013 (needs >=25% free) |
|---|---|---|---|---|
| LUT4 | 8,391 (34%) | **13,183 (54%)** | 24,288 | 46% free — PASS |
| DP16KD (BRAM) | 16 (28%) | **49 (87%)** | 56 | 7 left |
| MULT18X18D (DSP) | 8 (28%) | **25 (89%)** | 28 | 3 left |
| Max frequency | 40.76 MHz | **26.21 MHz** | — | PASS at 25 MHz, by **4.8%** |

— but the resulting `femtosoc_llm.bit` **computes wrong answers**. T036 found a
scale-pipelining defect in `acc_top.v`: the weight and activation scale registers advance one
cycle early, so every group is rescaled with the **next** group's scale instead of its own
(confirmed arithmetically: hardware produced `0x423f57a1` = 47.8356, matching
`50166 * w_s[1] * xs[0]`, where the correct value using `w_s[0]` is 26.4823). **Do not treat
`femtosoc_llm.bit` as flashable until this is fixed and re-verified** — `acc_test`'s CPU-vs-
hardware comparison (above) is exactly the check that will catch whether it still is.

**The 4.8% timing margin is also not something to wave past.** This project has direct
precedent for what that margin class costs: a 256-entry SDRAM cache was *rejected* at 28.4 MHz
against this same 25 MHz target for being too tight, and UART flakiness was later traced to
exactly that class of margin rather than to a logic fault. 26.21 MHz is tighter than the
configuration this project already judged unacceptable. The critical path is unambiguous —
`acc_mac.v`'s single-cycle combinational fp32 rescale (`accel_inst.u_mac.s3_rescaled_f_q ->
row_result_q`, 35.5 ns) — and it is the same logic responsible for the scale bug above, the 87%
BRAM/89% DSP occupancy, and a yosys `share`-pass optimization that would not terminate at all
until it was explicitly skipped for this profile (research R21: `share` reached 21 GB RSS
against `acc_mac.v`'s combinational fp32 functions before being OOM-killed; `synth_ecp5` for
this profile now runs its coarse stage with `share` omitted, scoped to this profile only). All
four findings point at the same fix: pipeline the fp32 rescale over the ~64-cycle budget one
group actually has, instead of doing it in one cycle.

**Also check the regression** — this feature changes shared memory-controller RTL, and the
full-featured profile must still build unchanged (SC-014):

```bash
make colorlight_i5.synth      # the full profile must still build
```

Baseline to compare against (research R14, captured before any accelerator RTL existed): LUT4
13,937/24,288 (57%), DP16KD 40/56 (71%), MULT18X18D 15/28 (53%), PLL 2/2 (100%). **This
regression was still in progress as of this writing** — do not treat it as already confirmed;
re-run it and compare against the R14 numbers above yourself.

---

## Stage D — integrated **[HW]**

```bash
(cd FIRMWARE/llama2 && make upload-runq-accel)
```

**Not `make upload`** — see the target table in Stage A step 3. `upload-runq-accel` is the one
that actually builds `runq_accel.bin` (78,004 B) with `-DUSE_ACC_MATMUL` and links the
accelerator driver in; `make upload` (fp32) and `make upload-runq` (Q8_0, software matmul) both
skip the accelerator entirely and would make this stage silently a no-op.

**This stage has not been run — it is blocked on Stage C's warning above.** `runq_accel.bin`
links and runs the same forward pass as `runq.bin` except that `do_matmul_q8()` routes weight
multiplies through the accelerator (falling back to software per call on any non-OK status, see
`runq.c`'s file header) — but with the currently-synthesized `femtosoc_llm.bit` computing wrong
answers (R22), a run today would either fail loudly (SC-005/SC-009 divergence, which is at
least honest) or — worse — produce plausible-looking wrong text, exactly the failure class this
whole project exists to catch. Do not attempt this stage until Stage C's `acc_test` comparison
passes on a rebuilt bitstream.

Expected, in order, once that holds:

1. **Weight multiplies accelerated only**: output byte-identical to Stage A step 3 (SC-009).
   Re-profile — matmul should collapse and attention become the largest category.
2. **Attention accelerated too**: **not achievable with today's RTL at all**, not merely
   unmeasured — `acc_top.v` currently implements only `ACC_MODE_MATMUL`; a descriptor for
   `ACC_MODE_ATT_SCORE`/`ACC_MODE_ATT_SUM` is rejected with `ERR_MODE` by design (research
   note in `acc_bits.vh`, following the T034 incident where an unrecognised mode silently ran
   the matmul datapath instead of being refused). Attention acceleration is later work (T064+),
   not something a rebuilt bitstream unlocks by itself.

The **2.5x** (matmul-only) and **~8.5x / 11-12 tokens/second** (matmul+attention) figures that
used to appear in this section are **projections from the design document's per-token profile
breakdown** (matmul 61.3%, attention 27.4% of feature 003's measured 1.38 tok/s baseline), not
measurements — they cannot be measured until R22 is fixed (step 1) and, for the second figure,
until attention acceleration exists at all (step 2, not yet built). Treat them as a sanity
expectation for the eventual measurement, not as a result already obtained.

Byte-identical is the criterion for step 1, not "looks similar". Every operand is an integer, so
the accelerated path must produce exactly the same tokens as Stage A step 3. Any divergence is
a bug — and, per Stage C's warning, the current hardware is already known to have one.

---

## Interpreting a disappointing result

The counters exist to make this a lookup rather than a guess:

| Symptom | Look at |
|---|---|
| Slow, `PERF_STALL` high | Bandwidth — arbitration priority, burst length, cache bypass |
| Slow, `PERF_STALL` low | Control logic — FSM stalls, FIFO underrun, descriptor overhead |
| Text differs from Stage A | A real bug. Integer arithmetic does not drift |
| Speed-up much less than expected | Check the profile: is the accelerated category actually shrinking? |
| Rate barely improves after attention | Expected — the scalar remainder now dominates. See below |

**The ceiling is known and is not a defect.** On the unaccelerated fp32 baseline, matmul is
61.3% of per-token time and attention 27.4% — 88.7% combined, the two categories this feature
targets. Once both are accelerated (not yet the case — see Stage D) they should collapse toward
SC-012's target of under 15% of the *new*, much shorter per-token time — which means the
untouched scalar remainder (sample/rmsnorm/rope/other, 11.3% of the *original* baseline) becomes
the *majority* of what is left, roughly 85-86% of the post-acceleration total. That is why
SC-011 asks for 8 tokens/second rather than something dramatic, and why more accelerator lanes
are explicitly out of scope. The next lever is clock rate and the scalar code, not more hardware
here.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Quantized model rejected on load | Wrong format — check magic `0x616b3432` and the 256-byte header; the fp32 model uses a 28-byte header with no magic |
| Fluent but wrong text | Model/vocabulary mismatch, as in feature 003; or an fp32 model loaded as Q8_0 |
| Wrong binary appears to run (no quantization or acceleration effect visible) | Check the upload target, not just that "make upload" succeeded — `make upload` = fp32 baseline, `make upload-runq` = Q8_0 software-only, `make upload-runq-accel` = Q8_0 + accelerator. All three build and upload silently "successfully"; only the target name says which firmware you actually got |
| Accelerated matmul result differs from the CPU reference in `acc_test` | As of this writing, expected — research R22's scale-pipelining bug. Confirm your bitstream was built after the fix, not just that it synthesized |
| Accelerator never signals done | Abort and check the descriptor was accepted — a rejected descriptor does not start |
| CPU feels sluggish while accelerating | Burst length too long; lower it and re-measure (shipped default is 128, research R19) |
| Accelerator throughput collapses under CPU load | Starvation guard not working; check the starvation counter (`starve_guard_fired` in `acc_arb_tb`) |
| Full profile stops building | The arbitration change leaked into it — it must be parameterised or gated |
| `#include <stdint.h>` not found | The system RISC-V compiler is unusable for this ABI; use `make` or the in-tree toolchain (feature 003) |
| Two serial readers | Dropped characters that look like a hardware fault (feature 003) |
| `yosys` synthesis of the accelerator profile seems to hang or consume huge memory | Check you are on a checkout that includes research R21's fix (`share` pass omitted for this profile only) — `acc_mac.v`'s combinational fp32 functions make unmodified `synth_ecp5` non-terminating |
| A synthesis run reports success via a piped log but the artifacts look wrong/missing | Check `make`'s own exit code, not a `tee`/`tail` pipeline's — `make ... \| tee log; echo $?` reports the pipeline's last command, not `make`'s (research R21); redirect instead (`make ... > log 2>&1; echo $?`) or set `pipefail` |
| Two synthesis runs (display profile and LLM profile) collide, or a `.bit` you didn't expect gets flashed | `colorlight_i5_llm.synth` writes its own `femtosoc_llm.*` artifacts (research R20) — but don't run it concurrently with `colorlight_i5.synth` regardless, and check which `.bit` you are actually pointing `openFPGALoader` at |
