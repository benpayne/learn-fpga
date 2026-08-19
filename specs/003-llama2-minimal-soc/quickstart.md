# Quickstart: Minimal RISC-V SoC for llama2.c

**Branch**: `003-llama2-minimal-soc`

End-to-end runbook, from clean checkout to generated text. Satisfies FR-021: someone who did
not implement this should be able to follow it unaided (SC-012).

Steps marked **[HW]** need the physical board. Everything else runs on the host.

---

## One-time setup

### 1. Prepare the model artifacts (host)

```bash
cd FemtoRV/FIRMWARE/llama2/tools
./fetch_model.sh
```

Produces `model.bin` (~1 MB) and `tokenizer.bin`, and prints the size and checksum of each.
**Record those numbers** — the board's verification step compares against them.

The tokenizer must be the reduced-vocabulary one matching this model, not the default shipped
for larger models. Pairing the wrong two produces fluent-looking but wrong text with no error.

### 2. Write the card (host)

Copy both files to the root of a FAT-formatted card:

```
/model.bin
/tokenizer.bin
```

Any desktop computer can do this; no special tooling. Fit the card to the board. **[HW]**

---

## Build

### 3. Build the boot ROM and device image

```bash
cd FemtoRV
(cd FIRMWARE && make libs)
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth
```

Under 10 minutes. Note the resource report — logic and memory-block utilisation are recorded
against SC-004.

No font data file is needed. If the build asks for one, the GPU has not been fully removed.

### 4. Build the inference program

```bash
(cd FIRMWARE/llama2 && make llama2.bin)
```

Links at `0x800000`. Tens of KB.

---

## Run

### 5. Program the board **[HW]**

```bash
openFPGALoader -c cmsisdap -v --file-type bin femtosoc.bit
```

Volatile — lost on power cycle. Use this during development; flash permanently only once
things are stable.

### 6. Connect **[HW]**

```bash
screen /dev/ttyACM0 115200
```

A monitor prompt should appear within 5 seconds of reset (SC-002). Press `H` for commands.

### 7. Verify memory once **[HW]**

Run the memory test over the full range. Expect zero errors and a reported transfer rate.
Do this before trusting any generation result — a marginal RAM fault and a model bug look
identical from the console.

### 8. Load the model from the card **[HW]**

Issue the model load command. Expect roughly:

```
loading /model.bin ... 1064960 bytes in 21.4 s (48.6 KB/s)
verify: OK
model: dim=64 layers=5 heads=8 kv_heads=4 vocab=512 seq_len=512
loading /tokenizer.bin ... OK (512 tokens)
```

Compare the byte count and checksum against step 1. **Record the throughput** — this is the
number SC-005's 60-second target was estimated against, and the estimate has not yet been
confirmed on hardware.

The model now sits at `0x900000` and stays there for this power cycle. Steps 9-10 can repeat
freely without redoing this.

### 9. Upload the program **[HW]**

At the monitor prompt press `L`, then send `llama2.bin` via XMODEM. Takes seconds.

### 10. Generate **[HW]**

```
G 800000
```

Text should appear incrementally, token by token. Expect at least 0.5 tokens/second (SC-008)
and simple, sometimes repetitive prose — this is a very small model and that is the expected
quality, not a defect.

---

## The development loop

Once step 8 has run, iterating means only:

```
rebuild → L → send → G 800000
```

Under 60 seconds (SC-005a), with no model reload. That split is the whole reason the model
lives on the card rather than arriving over serial.

**Only a power cycle costs you the model.** A processor reset may or may not preserve it,
depending on whether the memory controller keeps refreshing — worth determining early, since
it decides whether reset is cheap or expensive during debugging.

---

## Measuring

Run generation in measurement mode for the per-category timing breakdown. Categories must
cover ≥90% of per-token time.

This report is the deliverable that decides what any future accelerator should target. Read
it before designing hardware: on a model this small, the transcendental functions in rotary
encoding and softmax may take a much larger share than expected, and if so the cheapest
wins are software — precomputed rotary tables and a fast exponential approximation — not RTL.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No prompt after programming | Check baud is 115200 and the correct serial device |
| Model load reports no card | Card not seated, or not FAT-formatted |
| Load reports truncated file | Card write incomplete; re-copy and re-verify checksum |
| Token count mismatch on load | Model and tokenizer are not a matched pair — refetch both |
| Fluent but wrong text | Same mismatch, if the count check was bypassed |
| Text degrades into repetition | Check the memory test first, before suspecting the model |
| Build wants `font_data.hex` | GPU not fully removed from the profile |
| Synthesis fails on `femtoPLL` | Board makefile is not passing `-DCOLORLIGHT_I5` alongside the new define |
| `#include <stdint.h>` not found when compiling one file by hand | The `riscv64-unknown-elf-gcc` on `$PATH` is a system 10.2.0 install with no newlib for `rv32imafc/ilp32f`. Use `make`, or the in-tree toolchain at `FIRMWARE/TOOLCHAIN/riscv64-unknown-elf-gcc-8.3.0-*/bin/`. This is environmental, not a code bug |
| Board behaves like an old build after programming | Both profiles write to `femtosoc.bit`, so whichever synthesised last wins. Program `femtosoc_llm.bit` for the minimal profile |
| Program links but half of it is missing at runtime | Check the llama2 `Makefile` links all three objects (`llama2.o model_load.o profile.o`), not just `$<` |
