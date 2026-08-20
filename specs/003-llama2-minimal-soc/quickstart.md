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
make colorlight_i5_llm.firmware_config    # REQUIRED FIRST: generates FIRMWARE/config.mk
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth
cp femtosoc.bit femtosoc_llm.bit          # both profiles write femtosoc.bit -- keep a copy
```

Under 10 minutes. Note the resource report — logic and memory-block utilisation are recorded
against SC-004. Measured: LUT4 34%, block RAM 28%, max frequency 40.76 MHz.

`firmware_config` must run **before** building any firmware: it generates `FIRMWARE/config.mk`
(architecture, ABI, RAM size, device flags) for this profile, and it also runs `make libs`.
Skipping it leaves whichever profile was configured last in place.

`cp femtosoc.bit femtosoc_llm.bit` matters because **both profiles write to the same
filename**. Whichever synthesised most recently wins, so keeping a named copy avoids
programming the wrong image.

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
openFPGALoader -c cmsisdap -v --file-type bin femtosoc_llm.bit
```

**Note `femtosoc_llm.bit`, not `femtosoc.bit`** — see step 3. Programming the wrong image
gives a board that boots but has no SD card and no SDRAM at the expected addresses.

Volatile — lost on power cycle. Use this during development; flash permanently only once
things are stable.

### 6. Connect **[HW]**

```bash
screen /dev/ttyACM0 115200
```

A monitor prompt should appear within 5 seconds of reset (SC-002). Press `H` for commands.

### 7. Verify memory once **[HW]**

```bash
(cd FIRMWARE/examples && make upload_sdram_memtest)
```

Uploads, runs, and streams the output. Expect zero errors across six patterns over 6 MB and
about 4,897 KB/s. Do this before trusting any generation result — a marginal RAM fault and a
model bug look identical from the console.

Optionally also measure SD throughput: `(cd FIRMWARE/examples && make upload_sd_bench)` —
expect ~56.5 KB/s.

**Close any serial terminal first.** `screen`/`picocom` hold the port exclusively, and two
readers at once silently split the byte stream (see Troubleshooting).

### 8. Load the model from the card **[HW]**

The model loads automatically when the program starts. Actual measured output:

```
model: 1056512 bytes in 17941 ms (57.5 KB/s)
tokenizer: 6227 bytes in 109 ms (55.5 KB/s)
dim=64 hidden=172 layers=5 heads=8 kv_heads=4 vocab=512 seq_len=512
RunState needs 676192 bytes (limit 983040 bytes)
```

**~18 seconds, about 3.3x inside the 60-second SC-005 target.** Throughput is flat at
~56-57 KB/s regardless of read size (512 B through 32 KB), because the bottleneck is the
software-driven SPI clock rather than per-call overhead. There is no read-size tuning to be
had here.

The model now sits at `0x900000` and stays there for this power cycle. Steps 9-10 can repeat
freely without redoing this.

### 9. Upload and run the program **[HW]**

```bash
(cd FIRMWARE/llama2 && make upload)
```

One command: uploads over XMODEM, sends `G 800000`, and streams the output until the program
goes quiet. 64 KB takes about 35 seconds. Add `PORT=/dev/ttyUSB0` if the board enumerates
elsewhere.

Steps 9 and 10 are a single command; step 10 below describes what you should see.

### 10. Generate **[HW]**

```
G 800000
```

Text appears incrementally, token by token. Measured output:

```
Once upon a time, there was a little girl named Lily. She had a jolly apple
that she loved to play outside. One day, she went to the park with her mom.
She saw a big box
achieved 1.38 tok/s (59 tokens in 42.5 s)
```

**1.38 tokens/second**, against the SC-008 floor of 0.5. This is byte-for-byte identical to
the same model run on a desktop with the same prompt and seed. Expect simple, sometimes
repetitive prose — that is correct for a model this small, not a defect.

---

## The development loop

Once step 8 has run, iterating means only:

```
rebuild → make upload
```

Under 60 seconds (SC-005a), with no model reload. That split is the whole reason the model
lives on the card rather than arriving over serial.

**Only a power cycle costs you the model.** A processor reset may or may not preserve it,
depending on whether the memory controller keeps refreshing — worth determining early, since
it decides whether reset is cheap or expensive during debugging.

---

## Measuring

Set `MEASURE_MODE 1` in `llama2.c`, rebuild, and re-run. Measured over 110 tokens:

```
tokens: 110 in 90.6 s (1.21 tok/s)
  matmul       61.3%  (1389782424 cycles)
  attention    27.4%  (621744174 cycles)
  sample        4.0%
  rmsnorm       0.4%
  rope          0.2%
  other         6.6%
largest: matmul     coverage: 93.4%
```

Profiling costs about 12% (1.21 vs 1.38 tok/s), so compare profiled runs only to each other.

**This is the report that decides what an accelerator should target.** matmul and attention
together are 88.7% and both are matrix-multiply shaped. Accelerating only the weight matmuls
gives roughly 2.5x end-to-end; covering attention as well gives roughly 7.6x. They differ
only in what they stream — weights versus the KV cache — so one datapath serves both.

Rotary encoding is only 0.2% because this model's file carries precomputed `freq_cis` tables.
A model exported in the newer format recomputes them with `powf`/`sinf`/`cosf` and would
profile very differently — do not assume this result carries over to a different artifact.

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
