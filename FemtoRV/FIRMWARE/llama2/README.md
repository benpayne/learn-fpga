# llama2.c on FemtoRV

A port of Andrej Karpathy's [llama2.c](https://github.com/karpathy/llama2.c)
inference engine to the FemtoRV `petitbateau` core (RV32IMFC, `ilp32f` ABI)
running on the Colorlight i5 (ECP5) with 8MB external SDRAM.

Model weights and the tokenizer are too large to bake into the FPGA
bitstream or upload with the program, so they are loaded separately from an
SD card at runtime; only the inference program itself is uploaded over
serial via the BIOS monitor's XMODEM loader.

See `specs/003-llama2-minimal-soc/` for the full spec, plan, and data model.
This directory currently contains a build skeleton (task T006) — `llama2.c`
is a placeholder banner program that proves the Makefile and linker script
work. The real inference port lands in a later task.

## Memory layout

The program, model weights, vocabulary, and runtime activations/KV cache
each get a fixed, non-overlapping region of the 8MB SDRAM
(`specs/003-llama2-minimal-soc/data-model.md`, entity 2):

| Region | Base | Size | Written by |
|---|---|---|---|
| Program image (this directory) | `0x800000` | 1MB | serial upload (XMODEM) |
| Model weights | `0x900000` | 1MB | SD card load |
| Vocabulary | `0xA00000` | 64KB | SD card load |
| Activations + KV cache | `0xA10000` | ~960KB | program, at runtime |
| Free | `0xB00000` | 4MB | — |
| Stack | `0xF00000`-`0xFFFFF0` | 1MB | processor (grows down) |

`llama2.ld` links the program at `0x800000` with `LENGTH = 0x100000` (1MB),
so a build that grows past that boundary fails to link rather than
silently corrupting the model region at `0x900000`. If the memory layout
above ever changes, update `llama2.ld` to match.

## Building

```bash
cd FemtoRV/FIRMWARE/llama2
make llama2.bin
```

This links against `-lfemtorv32 -lfemtoc -lm` (libm is required for
`expf`/`logf`/`powf`/`sqrtf` used by softmax/RMSNorm/RoPE in the real
inference port) using `llama2.ld`, then converts the ELF to a raw binary
(`llama2.bin`) suitable for XMODEM upload.

The build reads `FIRMWARE/config.mk`, which is generated per board profile.
If it's missing or set up for a different board, regenerate it first:

```bash
cd FemtoRV
BOARD=colorlight_i5 TOOLS/make_config.sh -DCOLORLIGHT_I5
```

## Uploading and running

Upload over serial (BIOS monitor XMODEM, 'L' command), then run with 'G':

```bash
make upload            # wraps: python3 ../../TOOLS/xmodem_upload.py llama2.bin /dev/ttyACM0 800000
```

At the monitor prompt: `L` to receive the upload, then `G 800000` to jump
to it.

## Cleaning

```bash
make clean
```
