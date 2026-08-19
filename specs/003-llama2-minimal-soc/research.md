# Phase 0 Research: Minimal RISC-V SoC for llama2.c

**Branch**: `003-llama2-minimal-soc` | **Date**: 2026-08-18

All findings below were verified against the repository at commit `87ad9c1` unless marked
otherwise. Items marked **MEASURE** are estimates that must be replaced with hardware numbers.

---

## R1. Build profile mechanism

**Decision**: Add a new board define `COLORLIGHT_I5_LLM` with its own config file, board
makefile, and pin file. Do not modify the existing `colorlight_i5` profile.

**Rationale**: `RTL/femtosoc.v:13` includes `RTL/femtosoc_config.v`, which is a dispatcher
that `ifdef`s on a board define and includes one file from `RTL/CONFIGS/`. The same define
flows to `TOOLS/make_config.sh` → `FIRMWARE/config.mk` via `RTL/get_config.v`. Adding a
define is therefore purely additive: both profiles coexist in one checkout and FR-002 is
satisfied without touching working code.

**Alternatives considered**: Editing `colorlight_i5_config.v` in place (rejected — breaks
FR-002 and destroys the ability to A/B against the working build); a runtime-switchable
configuration (rejected — peripheral presence is a synthesis-time property).

### Gotcha: the PLL will not resolve under a new board define

`RTL/PLL/femtopll.v:37` selects the board PLL with `` `elsif COLORLIGHT_I5 ``. A profile that
defines only `COLORLIGHT_I5_LLM` matches none of those branches, leaving `femtoPLL`
undefined and failing synthesis. `PASSTHROUGH_PLL` is only set for `BENCH_OR_LINT` and
`ICE_SUGAR_NANO`, so it will not rescue this.

**Decision**: Pass **both** `-DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM` from the new board
makefile, place the `COLORLIGHT_I5_LLM` branch **before** the `COLORLIGHT_I5` branch in
`femtosoc_config.v`, and guard the original include with `` `ifndef NRV_CONFIGURED ``.

Every config file already ends with `` `define NRV_CONFIGURED ``, so the guard makes the
first matching branch win. This keeps all board-level plumbing (PLL selection, LED polarity
via `ACTIVE_LOW_LEDS`, `ECP5` FPGA family define) resolving exactly as it does today, while
the new define selects only the peripheral set. Three lines changed in `femtosoc_config.v`.

---

## R2. Peripheral strip list and expected capacity

**Decision**: Keep `NRV_IO_LEDS`, `NRV_IO_UART`, `NRV_IO_TIMER`, `NRV_IO_SDCARD`,
`NRV_IO_SDRAM`, `NRV_IO_HARDWARE_CONFIG`, petitbateau, `NRV_RAM 32768`.
Remove `NRV_IO_GPU`, `NRV_IO_SYNTH`, `NRV_IO_PS2`, `NRV_IO_SEGMENT`,
`NRV_IO_INT_CONTROLLER`.

**Rationale**: All peripheral ports in `femtosoc.v` are `ifdef`-guarded (lines 100-175), and
the GPU's includes — including `gpu_pll.v` — are inside an `ifdef NRV_IO_GPU` block closing
at line 68. Removing the define therefore removes both the logic and the top-level ports
cleanly.

The SD card is **kept** despite being nominally "storage": `femtosoc.v:791` documents that
the SPI protocol is bit-banged in software, so the peripheral is four GPIO bits. It costs
essentially nothing against the SC-004 headroom targets and is required by FR-010.

`NRV_RAM` stays at 32768 so the existing BIOS monitor fits; it is the console, the program
loader, and the memory-test host. Note the Pico branch shrank this to 4096 — that change is
**not** present on this branch and must not be reintroduced.

**Baseline for comparison** (full profile, from CLAUDE.md): LUT 57% (13,937/24,288), BRAM
71% (40/56), MULT 53% (15/28), PLL 100% (2/2).

**MEASURED 2026-08-18** (nextpnr-ecp5, minimal profile, build log `/tmp/synth_llm.log`):

| Resource | Full profile | Minimal profile | Free |
|---|---|---|---|
| LUT4 | 57% (13,937/24,288) | **34%** (8,391/24,288) | 66% |
| Block RAM (DP16KD) | 71% (40/56) | **28%** (16/56) | 72% |
| Multipliers (MULT18X18D) | 53% (15/28) | **28%** (8/28) | 72% |
| PLL (EHXPLLL) | 100% (2/2) | **50%** (1/2) | one freed |
| IO (TRELLIS_IO) | — | 32% (65/197) | — |
| Bitstream | 384,797 B | 259,704 B | — |

**SC-004 PASSES** with wide margin: 66% logic free and 72% memory blocks free, against a
threshold of 40% each.

**Unexpected bonus — timing improved substantially**: max frequency rose from 32.6 MHz (full
profile) to **40.76 MHz**, a 25% gain, giving 63% margin at the 25 MHz target instead of 30%.
Removing the GPU took its 125 MHz TMDS paths and one PLL out of the design. This makes a
future clock increase materially more plausible than the plan assumed, and gives the
accelerator real timing room to work with. Worth revisiting the deferred decision in R10.

---

## R3. Pin constraints

**Decision**: Fork `BOARDS/colorlight_i5.lpf` to `BOARDS/colorlight_i5_llm.lpf`, keeping
only `pclk` (with its `FREQUENCY PORT "pclk" 25 MHZ` constraint), `RESET`, `D1_pin`-`D8_pin`,
`TXD`/`RXD`, the SD card group, and the SDRAM group.

**Rationale**: Disabling a peripheral removes its top-level ports, leaving the shared pin
file constraining signals that no longer exist. Forking is a copy-and-delete and makes the
profile self-contained.

**Naming hazard**: `sd_d[31:0]`, `sd_addr[10:0]`, `sd_ba`, `sd_we`, `sd_ras`, `sd_cas`, and
`sdram_clk` are **SDRAM**. `sd_cs_n`, `sd_mosi`, `sd_miso`, `sd_clk` are the **SD card**.
Both groups are kept, but the similar prefixes make this easy to get wrong when trimming.

Delete: `gpdi_dp`/`gpdi_dn` (GPU), `ps2_clk`/`ps2_data`, `segments`/`seg_select`,
`audio_pwm`/`i2s_*`, and `spi_mosi`/`spi_miso`/`spi_cs_n`/`spi_clk` (SPI flash, unused here).

---

## R4. Memory map

**Decision**:

| Range | Size | Contents |
|---|---|---|
| `0x000000-0x007FFF` | 32 KB | BRAM, BIOS monitor |
| `0x400000+` | — | IO devices (UART, LEDs, timer, SD, hardware config) |
| `0x800000-0x8FFFFF` | 1 MB | Program image (`.text`/`.data`/`.bss`) |
| `0x900000-0x9FFFFF` | 1 MB | Model weights |
| `0xA00000-0xAFFFFF` | 1 MB | Vocabulary + activations + KV cache |
| `0xB00000-0xEFFFFF` | 4 MB | Free |
| `0xF00000-0xFFFFF0` | 1 MB | Stack, grows down |

**Rationale**: SDRAM decodes as `mem_address[23]` (`femtosoc.v:304`), i.e.
`0x800000-0xFFFFFF`. The existing `FIRMWARE/examples/upload_sdram.ld` already links programs
at `0x800000` with a 4 MB region; narrowing that to 1 MB and giving weights their own base
keeps the regions non-overlapping as FR-007 requires. `0xA00000` was the framebuffer under
the full profile and is free here because the GPU is gone.

**Sizing check** for the target model (dim=64, 5 layers, 8 heads / 4 kv-heads, hidden=172,
vocab=512, seq_len=512): weights ≈ 1.04 MB; KV cache = 2 × 5 × 512 × 32 × 4 B ≈ 640 KB;
remaining activations are a few KB. Comfortably inside the allocation.

---

## R5. Model artifact

**Decision**: Target the smallest pre-trained model published upstream — approximately
260K parameters, ~1.04 MB at fp32 — with its matching reduced-vocabulary tokenizer.

**Format**: a header of seven `int32` fields (dim, hidden_dim, n_layers, n_heads,
n_kv_heads, vocab_size, seq_len) followed by fp32 weight blocks in a fixed order. A negative
`vocab_size` signals an unshared classifier. The tokenizer file carries a max-token-length
`int32` then per-token score/length/bytes records.

**Endianness**: both host and target are little-endian, so the file is usable byte-for-byte
with no conversion. This is what makes "copy the file to a card" viable as the whole
pipeline.

**VERIFY**: the field order and count above must be confirmed against the actual downloaded
artifact before the loader is trusted. FR-015 requires rejecting a malformed file, and that
check is only as good as the header layout being right.

**Hazard**: this model uses a reduced vocabulary and needs its own tokenizer file, not the
one shipped for the larger models. A mismatched pair produces fluent-looking but wrong text
(FR-018a). Both files must be treated as a matched set.

---

## R2a. SDRAM verified on hardware (measured 2026-08-19)

**Result**: all six patterns pass with zero errors over the 6 MB range
`0x900000`-`0xEFFFFF` (the low 1 MB holds the running program and is excluded).
Patterns: walking ones, address-as-data, `0x00000000`, `0xFFFFFFFF`, `0x55555555`,
`0xAAAAAAAA`.

**Measured CPU-mediated bandwidth**: 62,914,560 bytes in 313,614,791 cycles at 25 MHz =
**4,897 KB/s (5.1 MB/s)** for combined write+read through the cache.

**Why this number matters for the accelerator.** The burst roofline measured in simulation is
~98 MB/s (0.98 words/cycle x 4 B x 25 MHz). The CPU, running the simplest possible
integer fill-and-verify loop, achieves ~5 MB/s — about **5% of what the memory can deliver**.
That is the optimistic case: no floating point, no dependent loads, perfectly sequential.
It independently corroborates the roofline analysis that motivated this whole feature, and it
sets a concrete floor: any accelerator that streams weights via burst reads has roughly a
**20x bandwidth headroom** over the CPU doing the same traffic, before considering that the
CPU also has to do arithmetic between loads.

**Consequence for SC-003**: satisfied. RAM is sound, so incoherent generated text later cannot
be attributed to memory faults.

---

## R6. Loading the model from the card

**Decision**: Reuse the existing FAT library and SD driver. `FIRMWARE/examples/sd_dir.c`
already demonstrates the full path — `sd_init`, `fl_attach_media`, `fl_fopen`, `fl_fread` —
from a standalone program with no kernel underneath.

**Rationale**: This is the single largest piece of pre-existing work this feature depends on.
`sd_dir.c`, `sd_dump.c`, and `sd_test.c` are all working examples. **However, all three write
output via `GPU_WRITE`**, which does not exist in this profile. They need their output paths
reduced to serial before they will compile — a small, mechanical, but non-zero task.

**MEASURED 2026-08-19 — risk retired, comfortably.** SC-005 targets a 60-second load for
~1 MB (roughly 17 KB/s needed). Actual, reading the real `/model.bin` (1,056,540 bytes):

| Chunk size | Time | Throughput |
|---|---|---|
| 512 B | 18.418 s | 56.0 KB/s |
| 4096 B | 18.254 s | 56.5 KB/s |
| 32768 B | 18.247 s | 56.5 KB/s |

**~18 seconds, roughly 3.3x inside the target.** The estimate below (30-80 KB/s) was correct;
the outcome landed near its top end.

**Chunk size is irrelevant** — 56.0 vs 56.5 KB/s across a 64x range of read sizes. The
bottleneck is the software-driven SPI clock itself, not per-call overhead, so there is no
tuning to be had here. Anyone tempted to optimise the read size later should not bother; the
only real lever would be a hardware SPI peripheral.

**Consequence**: the loading split decided earlier holds. The model comes off the card once
per power cycle in under 20 seconds, and the development loop pays only the program upload.
None of the R6 escalation options below are needed.

*Original estimate, retained for the record:* throughput was unknown. `spi_sd.c` drives every SPI clock edge
with a separate `IO_OUT` to `IO_SDCARD`, and IO accesses take extra wait states
(`NRV_IS_IO_ADDR` in `femtosoc_config.v`). Estimated 30-80 KB/s, giving 13-35 seconds, but
this is arithmetic, not measurement. FR-012a exists to replace it with a real number.

If throughput lands far below estimate, escalation options in order of cost: raise the
serial baud rate and fall back to serial for the model (R10); reduce `seq_len` to shrink the
KV cache rather than the weights; move the model to SPI flash (blocked on an address-decode
conflict — mapped flash decodes `[23:22]==2'b10`, i.e. `0x800000-0xBFFFFF`, which overlaps
SDRAM, so this is not a quick fix); or revive the Pico loader.

---

## R7. Loading the program over serial

**Decision**: Use the existing BIOS monitor. `L` performs an XMODEM upload and `G` jumps to
an address (`monitor/*.c:750-757`, commands `H D E S L G C M`). Link programs with a variant
of `FIRMWARE/examples/upload_sdram.ld`.

**Rationale**: Already working and already the documented workflow. FR-009 needs nothing new.
At roughly 10 KB/s a program of a few tens of KB uploads in seconds, which is what makes the
split in User Story 3 worthwhile.

**Note**: `M` (meminfo) and `D` (dump) give a free way to spot-check that the model landed at
the right address after a card load, without writing any new tooling.

---

## R8. Porting the model program

**Decision**: Start from the reference implementation and remove the host-OS dependencies:
replace the memory-mapped file load with a pointer to the weights already resident at
`0x900000`; replace file reads for the tokenizer with a card read; replace the wall-clock
timer used for the RNG seed and for rate reporting with the cycle counter (R9); keep the
maths in fp32.

**Rationale**: The compiler is already configured for `rv32imafc`/`ilp32f`
(`FIRMWARE/config.mk`) and petitbateau implements hardware floating point. Verified that
`TOOLCHAIN/.../rv32imafc/ilp32f/libm.a` provides `expf`, `logf`, `powf`, and `sqrtf`, and
`FIRMWARE/examples/Makefile:9` already links `-lm`. No soft-float fallback is needed.

**Watch items**: dynamic allocation for activations — prefer static allocation at fixed
addresses from R4, which also makes FR-008 (detecting an oversized load) trivial; and the
`seq_len` the KV cache is sized against, since that dominates working memory.

---

## R9. Measuring where the time goes

**Decision**: Use the existing `cycles()` counter (`LIBFEMTORV32/cycles_32.c`), which handles
counter wraparound via `FEMTORV32_COUNTER_BITS`. Instrument the matrix multiply, the
attention path, the normalisation, the rotary position encoding, and the sampling
separately, accumulating per-category cycle totals across a run and reporting at the end.

**Rationale**: FR-019 and FR-020 require categories summing to ≥90% of per-token time. A
cycle counter already exists and already handles wraparound, which at 25 MHz matters over a
long run.

**Expectation worth recording now**: on a model this small the transcendental functions may
be a far larger share than intuition suggests — the rotary encoding calls `powf`/`sinf`/`cosf`
per rotation pair per layer, and softmax calls `expf` once per attention score, while the
matrix multiplies are only ~260K operations per token. If the measurement confirms this, the
cheap wins are precomputed rotary tables and a fast `expf` approximation, both software
changes, before any hardware is designed. This measurement is the entire justification for
User Story 5.

---

## R9a. Host-harness validation (added 2026-08-18, post-implementation)

**Finding**: before any hardware exists, the ported forward pass was validated on the host
against the real `model.bin` and `tokenizer.bin`, and produced coherent English:

> Once upon a time, there was a little girl named Lily. She had a jolly apple that she loved
> to play outside. One day, she went to the park with her mom. She saw a big box

**Why this matters**: it removes inference *correctness* from the hardware risk list. Weight
layout, table-based RoPE, grouped-query attention, and BPE encode/decode are all confirmed
against the actual artifacts. What remains untested on hardware is the SD load path, the
memory map, and performance — not whether the maths is right. If the board produces garbage,
look at loading and memory first, not at the transformer.

**Second finding — unaligned tokenizer records**: after the first entry, the
`{score, len, bytes}` records in the tokenizer file are NOT 4-byte aligned. The port reads
them byte-wise rather than via `uint32_t`/`float` casts, because FemtoRV is not guaranteed to
tolerate misaligned loads. A cast-based reader would compile cleanly, work on the host, and
fail only on hardware — exactly the class of bug this project can least afford to debug over
a serial console.

---

## R10. Serial baud rate

**Decision**: Keep 115200 for this feature. Record raising it as a follow-on.

**Rationale**: The baud divisor derives from `NRV_FREQ` in the profile, so raising it is a
small change — but it alters the host-side workflow and every existing tool invocation, and
the model no longer travels over serial, so the benefit is limited to program uploads that
already take seconds. Not worth the churn inside this feature. It becomes the first
escalation if R6 measures badly.

---

## R11. Verification split

**Decision**: Host-verifiable work is component simulation, both profile builds, resource
reports, and host-side artifact preparation. Everything else needs the board.

**Rationale**: Directly from the spec's Testing Support section. Concretely, the following
require the operator: programming the board, boot and console behaviour, the memory test,
writing and fitting the card, model loading, generation, and all performance measurement.

**Batching**: hardware checkpoints should be grouped so each board session validates a
coherent slice. A natural grouping is: (1) boots + resource report + memory test + SD
throughput measured together, since they share a single bitstream and answer the riskiest
open question early; (2) model loads and verifies + program uploads and runs; (3) generation
and the timing breakdown. Task sequencing is deferred to `/speckit.tasks`.
