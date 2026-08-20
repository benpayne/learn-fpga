# Phase 1 Data Model: int8 MatMul Accelerator

**Branch**: `004-int8-matmul-accel` | **Date**: 2026-08-20

Entities from the spec's Key Entities section. For this feature "data model" means file
formats, memory regions, register and descriptor layouts, and report structures.

---

## 1. Quantized Model Artifact

The Q8_0 checkpoint. Format verified against upstream `runq.c` (research R1, R4).

| Field | Type | Notes |
|---|---|---|
| magic | uint32 | `0x616b3432` ("ak42") — distinguishes this from the legacy format |
| version | int32 | 2 |
| Config | 7 x int32 | dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len |
| shared_classifier | uint8 | classifier reuses the embedding table |
| group_size | int32 | **GS — a file parameter, not a constant** |
| (padding) | — | header is exactly **256 bytes** total |
| per tensor: q | int8[size] | all quantized values, contiguous |
| per tensor: s | float32[size/GS] | all scales, contiguous, **after** the q block |

**Rules**
- Magic and version MUST be checked; a legacy-format file loaded as Q8_0 (or vice versa) is a
  silent-wrong-output failure, which is the class this project most needs to prevent.
- `GS` MUST be read from the header and carried into every operation descriptor.
- Quantized size is `params * (1 + 4/GS)` bytes — **1.0625 at the default GS=64**, versus 4.0
  for fp32, i.e. 26.6%.

**Relationships**: paired with the same vocabulary artifact as feature 003 (unchanged, still
fp32 scores). The model/vocabulary matching rule from feature 003 (FR-018a there) still applies.

---

## 2. Quantized Tensor (in memory)

How a weight matrix appears to the accelerator once loaded.

| Part | Type | Size | Streamed? |
|---|---|---|---|
| `q` | int8[d*n] | d*n bytes | **yes — dense, 4 per 32-bit word** |
| `s` | float32[d*n/GS] | 4*d*n/GS bytes | no — **prefetched into BRAM** |

**Rules**
- The `q` block is the dense burst stream; it is what sets throughput.
- The `s` block is ~1.5% of the data at GS=64 and is fetched once at operation start (research
  R1). For a 64x64 matrix that is 64 scales = 256 bytes.
- The accelerator MUST NOT interleave the two streams; the prefetch keeps the inner loop single-
  source and running at full lane rate.

---

## 3. Quantized Activation Vector

**New relative to the design** — research R2. The input vector is quantized too.

| Field | Type | Size |
|---|---|---|
| `xq` | int8[n] | n bytes |
| `xs` | float32[n/GS] | 4n/GS bytes |

**Rules**
- Produced by the CPU before each operation, matching `runq.c`'s `quantize()` exactly so results
  compare bit-for-bit.
- Small enough to live entirely in accelerator BRAM (n <= 172 for this model).
- The per-group scale applied to an accumulated result is the **product** `w->s[g] * x->s[g]`.
- **This is new scalar work the feature adds.** Measure its cost in User Story 1; it lands in the
  scalar remainder that already dominates.

---

## 4. Operation Descriptor

One unit of accelerator work.

| Field | Width | Meaning |
|---|---|---|
| `w_q_base` | 26 | quantized weight block address |
| `w_s_base` | 26 | scale block address |
| `x_slot` | 8 | which BRAM slot holds the quantized activation |
| `out_slot` | 8 | result BRAM slot |
| `n` | 16 | inner dimension |
| `d` | 16 | number of output rows |
| `gs` | 16 | group size from the model header |
| `mode` | 2 | 0 = weight matmul, 1 = attention scores, 2 = attention weighted sum |

**Validation rules** (FR-009)
- `n` MUST be a multiple of `gs`; reject otherwise rather than computing a partial group.
- `gs` MUST be a supported power of two; reject others explicitly.
- `n`, `d` MUST be within the accelerator's configured maxima.
- `d * 4` MUST fit the result BRAM slot.
- A rejected descriptor MUST set the error status and MUST NOT start.

**State transitions**: `IDLE -> RUNNING -> DONE -> IDLE` (cleared on read or on next start).
`ABORT` from `RUNNING` returns to `IDLE` with results undefined and the FIFO flushed.

---

## 5. Register Interface

Two one-hot IO bits, reusing the slots the GPU and synth occupied in the full profile
(research R7). Mutually exclusive with those devices, exactly as `IO_GPU_bit` already is with
`IO_FGA_CNTL_bit`.

| Bit | Name | Access | Meaning |
|---|---|---|---|
| 10 | `IO_ACC_IDX` | W | selects which accelerator register the next data access targets |
| 11 | `IO_ACC_DAT` | RW | reads or writes the selected register |

Registers reachable through that pair: the descriptor fields above, plus:

| Register | Access | Meaning |
|---|---|---|
| `CTRL` | W | bit0 START (enqueue descriptor), bit1 ABORT |
| `STATUS` | R | bit0 BUSY, bit1 DONE, bit2 ERR, bits 7:4 error code, bits 15:8 queue depth |
| `PERF_CYCLES` | R | cycles the current/last operation was active |
| `PERF_STALL` | R | cycles spent waiting on memory within that |

**Rules**
- `PERF_*` are not optional (FR-008). Without them a throughput shortfall cannot be attributed
  to bandwidth versus control logic, and the whole feature depends on knowing which.
- Reading `STATUS` MUST NOT have side effects other than the documented `DONE` clear.

---

## 6. Result Buffer

| Property | Value |
|---|---|
| Location | BRAM, mapped at `0x100000` (free in this profile — research R8) |
| Size | at least `max_d * 4` bytes; 2 KB covers the `d`=512 classifier |
| Access | ordinary CPU loads, not IO reads |
| Written by | accelerator only |

**Rules**
- Reading while `BUSY` MUST either be prevented or clearly flagged as not-ready (FR-014); it
  MUST NOT return half-written values.
- Results never enter SDRAM, so no cache-coherency question arises (research R8).

---

## 7. Memory Sharing Policy

| Parameter | Value | Basis |
|---|---|---|
| Priority | refresh > CPU single-word > accelerator burst | research R10 |
| Burst atomicity | non-preemptible once started | already true in the controller |
| Burst length | 64 words (parameterised) | 91.4% efficiency vs 70-cycle CPU worst case |
| Anti-starvation | accelerator forced after N denied rounds | FR-017 |
| Cache | accelerator bypasses it entirely | FR-019 |

**Rules**
- Burst length MUST be a parameter and MUST be chosen from measurement, not the table (FR-020).
- The starvation counter MUST be observable, so the assumption that it never fires is checked
  rather than trusted.
- The full profile MUST retain the old priority (FR-021).

---

## 8. Performance Report

Extends feature 003's per-category timing with accelerator-specific counters.

| Field | Unit | Requirement |
|---|---|---|
| per-category cycles | cycles and % | unchanged from feature 003 |
| accelerator active | cycles | |
| accelerator stalled on memory | cycles | FR-008, SC-015 |
| achieved rate | words/cycle | SC-006 |
| starvation events | count | FR-017 |

**Rules**
- `stalled / active` is the number that distinguishes a bandwidth limit from a control-logic
  limit. It is the primary diagnostic for the whole feature.
