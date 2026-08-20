# Quickstart: int8 MatMul Accelerator

**Branch**: `004-int8-matmul-accel`

How to get from a clean checkout to accelerated generation. Steps marked **[HW]** need the
board; everything else runs on the host.

This feature builds on `003-llama2-minimal-soc`. If that quickstart does not work first, fix
that before starting here.

---

## Stage A — quantize and validate in software (no hardware changes)

This stage exists to answer one question: **does 8-bit quantization ruin output quality on this
very small model?** Answer it before building anything.

### 1. Quantize the model (host)

```bash
cd FemtoRV/FIRMWARE/llama2/tools
./quantize_model.sh
```

Produces a Q8_0 checkpoint. Expect roughly **0.28 MB versus 1.06 MB** for fp32 — 1.0625 bytes
per parameter at the default group size of 64. Record the size, checksum and group size.

`export.py` defaults `group_size=64` and halves it if a dimension does not divide evenly. Every
quantized tensor in this model is a multiple of 64, so no backoff should occur — if the script
reports one, record it, because it changes the storage ratio and the accelerator's lane
framing.

### 2. Generate the golden reference (host)

```bash
./runq_host model.q8.bin tokenizer.bin --seed 2026 --steps 110
```

Keep this output. Every later stage compares against it.

### 3. Run it on the board **[HW]**

Copy the quantized model to the SD card, build the quantized firmware, and run it:

```bash
(cd FemtoRV/FIRMWARE/llama2 && make upload)
```

### 4. Make the go/no-go decision

Compare against the fp32 output from feature 003:

> Once upon a time, there was a little girl named Lily. She had a jolly apple that she loved to
> play outside. One day, she went to the park with her mom. She saw a big box

**If quality holds**: continue with 8-bit.
**If it collapses**: switch to 16-bit floating point now, per FR-004a — before any hardware
exists. Taking that fallback later is far more disruptive, because it changes the arithmetic
from integer to floating point and with it the whole basis of bit-exact verification.

Record the decision and the evidence either way (FR-004b).

Also **record the cost of quantizing the activation vector** (research R2). It is new scalar
work this feature adds, and the scalar remainder already dominates.

---

## Stage B — prove the accelerator in simulation (no hardware)

```bash
cd FemtoRV/TEST
make MODULE=acc_mac_tb  SIM=icarus     # arithmetic unit alone
make MODULE=acc_unit_tb SIM=icarus     # full unit against a simulated memory
make MODULE=acc_arb_tb  SIM=icarus     # memory sharing under synthetic CPU load
```

Every one of these must be **bit-identical** to the host reference. Integer arithmetic makes
that an unambiguous pass/fail — there is no rounding to argue about.

`acc_arb_tb` also produces the real version of the burst-length trade-off table. **Choose the
burst length from that output**, not from the estimate in the design document.

---

## Stage C — accelerator on hardware, in isolation **[HW]**

```bash
cd FemtoRV
make colorlight_i5_llm.firmware_config
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth
cp femtosoc.bit femtosoc_llm.bit
openFPGALoader -c cmsisdap -v --file-type bin femtosoc_llm.bit

(cd FIRMWARE/examples && make upload_acc_test)
```

The test computes one matrix multiply and compares against a CPU-computed reference. The
language model is not involved, so a failure here is unambiguously the accelerator.

Record the performance counters: achieved words/cycle and the stall ratio.

**Also check the regression** — this feature changes shared memory-controller RTL:

```bash
make colorlight_i5.synth      # the full profile must still build
```

---

## Stage D — integrated **[HW]**

```bash
(cd FIRMWARE/llama2 && make upload)
```

Expect, in order:

1. **Weight multiplies accelerated only**: output **byte-identical** to Stage A step 3, roughly
   2.5x faster. Re-profile — matmul should collapse and attention become the largest category.
2. **Attention accelerated too**: still byte-identical, approaching 8.5x, so roughly 11-12
   tokens/second against feature 003's 1.38.

Byte-identical is the criterion, not "looks similar". Every operand is an integer, so the
accelerated path must produce exactly the same tokens. Any divergence is a bug.

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

**The ceiling is known and is not a defect.** After Stage D roughly 86% of token time is
scalar work this feature does not touch. That is why SC-011 asks for 8 tokens/second rather
than something dramatic, and why more accelerator lanes are explicitly out of scope. The next
lever is clock rate and the scalar code, not more hardware here.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Quantized model rejected on load | Wrong format — check magic `0x616b3432` and the 256-byte header; the fp32 model uses a 28-byte header with no magic |
| Fluent but wrong text | Model/vocabulary mismatch, as in feature 003; or an fp32 model loaded as Q8_0 |
| Accelerator never signals done | Abort and check the descriptor was accepted — a rejected descriptor does not start |
| CPU feels sluggish while accelerating | Burst length too long; lower it and re-measure |
| Accelerator throughput collapses under CPU load | Starvation guard not working; check the starvation counter |
| Full profile stops building | The arbitration change leaked into it — it must be parameterised or gated |
| `#include <stdint.h>` not found | The system RISC-V compiler is unusable for this ABI; use `make` or the in-tree toolchain (feature 003) |
| Two serial readers | Dropped characters that look like a hardware fault (feature 003) |
