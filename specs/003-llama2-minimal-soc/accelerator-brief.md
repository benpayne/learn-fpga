# Accelerator Brief — evidence from 003-llama2-minimal-soc

**Date**: 2026-08-19 | **Source**: measurements on a Colorlight i5 at 25 MHz
**Purpose**: T050. Everything a follow-on MatMul accelerator feature needs from this one.

Every number here was measured on hardware. Where something is an estimate or a simulation
result, it says so.

---

## 1. What to accelerate

Per-token breakdown, 110 tokens, stories260K:

| Category | Share |
|---|---|
| **matmul** | **61.3%** |
| **attention** | **27.4%** |
| sample | 4.0% |
| other (residual) | 6.6% |
| rmsnorm | 0.4% |
| rope | 0.2% |

**matmul + attention = 88.7%, and both are matrix-multiply shaped.**

Amdahl, assuming 50x on the accelerated portion:

| Scope | End-to-end |
|---|---|
| matmul only | **2.5x** |
| matmul + attention | **7.6x** |

**Decision: the accelerator must cover attention, not just the weight matrices.** Building for
matmul alone caps the payoff at 2.5x — a poor return for the RTL effort. Attention differs
only in what it streams (KV cache instead of weights), so one datapath with two source
configurations covers both.

The remaining 11.3% is the new Amdahl floor. Nothing in it justifies hardware.

---

## 2. The bandwidth roofline

| Path | Rate | How measured |
|---|---|---|
| SDRAM burst read | ~98 MB/s | simulation: 0.98 words/cycle x 4 B x 25 MHz |
| SDRAM via CPU + cache | **5.1 MB/s** | hardware memory test, write+read |
| CPU float matmul | ~1.9 MB/s | derived from 952 KFLOPS at 2 FLOP/weight |

**The CPU uses about 5% of available memory bandwidth on the simplest possible integer loop,
and roughly 2% doing actual float matmul.** Batch-1 inference should be memory-bound; today
it is issue-bound by roughly 20-50x. That gap is the accelerator's opportunity, and it is
confirmed on hardware rather than assumed.

**Consequence for the datapath**: at 25 MHz, one 32-bit word per cycle saturates SDRAM. That
is 1 fp32 MAC/cycle, or 4 int8 MACs/cycle. **A wide systolic array is the wrong shape** —
the engineering is in the streaming/DMA orchestrator, not the multiplier count. The board has
28 multipliers and this needs a handful.

---

## 3. Capacity and timing available

Measured for the minimal profile:

| Resource | Used | Free |
|---|---|---|
| LUT4 | 34% (8,391/24,288) | **66%** |
| Block RAM | 28% (16/56) | **72%** |
| Multipliers | 28% (8/28) | 72% |
| PLL | 1/2 | one spare |
| Max frequency | 40.76 MHz | 63% margin at 25 MHz |

**The timing headroom was not forecast.** Removing the GPU took its 125 MHz TMDS paths out of
the design and lifted max frequency from 32.6 to 40.76 MHz. That makes a clock increase
materially more attractive than the original plan assumed: SDRAM bandwidth scales linearly
with clock, so 50 MHz would roughly double the roofline in section 2 before any accelerator
work. **Consider doing the clock bump first** — it is cheap, benefits everything including the
scalar 11.3%, and changes the target the accelerator is designed against.

---

## 4. What to reuse

- `RTL/SDRAM/muchtoremember_burst.v` — burst reads, proven at 0.98 words/cycle, row-crossing
  handled internally.
- `RTL/SDRAM/video_fetch_engine.v` — **the closest thing to the orchestrator already written.**
  It issues burst reads, tracks position, and feeds a consumer. Swapping the video fetch engine
  for a weight fetch engine is the natural starting point.
- The second burst port on the SDRAM controller that the GPU used is now free.
- `FIRMWARE/llama2/profile.c` — per-category cycle accounting, so before/after comparisons use
  the same instrument.

---

## 5. Caveats before generalising

- **The 0.2% rope figure does not generalise.** It is low because this model's legacy export
  format carries precomputed `freq_cis` tables. A model exported in the newer format
  recomputes them with `powf`/`sinf`/`cosf` and would profile very differently. If the target
  model changes, re-profile before trusting section 1.
- **stories260K is small** (dim=64, 5 layers). Larger models shift the balance further toward
  matmul, so 88.7% is a floor for the accelerable fraction, not a ceiling.
- **8 MB SDRAM caps model size**: ~1.8M params at fp32, ~7M at int8. stories15M does not fit
  in either format.
- **Weights stream once per token and are never reused** at batch 1. Caching them is pointless;
  bypass the CPU cache entirely for weight traffic.

---

## 6. Suggested order

1. **Raise the clock** (25 -> 50 MHz). Cheapest win, scales everything, and the 40.76 MHz
   result says there is room. Re-measure the roofline afterwards.
2. **Build the streaming orchestrator** before the MAC array, modelled on
   `video_fetch_engine.v`. Bandwidth is the constraint; multipliers are not.
3. **Cover attention from the start**, not as a follow-on. Section 1 shows why.
4. **Consider int8** (`runq.c` Q8_0) once fp32 works: 4x the roofline and 4x the model
   capacity, for a 4-wide MAC instead of 1-wide.
