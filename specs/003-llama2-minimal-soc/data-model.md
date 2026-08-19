# Phase 1 Data Model: Minimal RISC-V SoC for llama2.c

**Branch**: `003-llama2-minimal-soc` | **Date**: 2026-08-18

Entities are drawn from the feature spec's Key Entities section. For this feature "data
model" means build-time configuration, on-card file layout, in-memory region layout, and the
report structures — there is no database.

---

## 1. Build Configuration

A synthesis-time selection of which hardware capabilities exist in a device image.

| Field | Value for this profile | Source |
|---|---|---|
| Board define | `COLORLIGHT_I5_LLM` (plus `COLORLIGHT_I5`) | new board makefile |
| Processor | petitbateau (RV32IMFC) | `NRV_FEMTORV32_PETITBATEAU` |
| Boot ROM size | 32768 bytes | `NRV_RAM` |
| Clock | 25 MHz | `NRV_FREQ` |
| Peripherals present | LEDs, UART, timer, SD card, SDRAM, hardware config | `NRV_IO_*` |
| Peripherals absent | GPU, synth, PS2, 7-segment, interrupt controller | omitted `NRV_IO_*` |

**Rules**
- Both `COLORLIGHT_I5` and `COLORLIGHT_I5_LLM` must be defined, or the PLL fails to resolve
  (research R1).
- The `COLORLIGHT_I5_LLM` dispatch branch must precede the `COLORLIGHT_I5` branch, and the
  latter must be guarded by `` `ifndef NRV_CONFIGURED ``.
- The existing `colorlight_i5` profile must remain byte-identical (FR-002).

**Relationships**: determines which ports exist at the top level, and therefore which pin
file is valid. One configuration ↔ one pin file.

---

## 2. Memory Layout

Non-overlapping regions in the 8 MB external RAM, satisfying FR-007.

| Region | Base | Size | Written by | Lifetime |
|---|---|---|---|---|
| Program image | `0x800000` | 1 MB | serial upload | per rebuild |
| Model weights | `0x900000` | 1 MB | card load | per power cycle |
| Vocabulary | `0xA00000` | 64 KB | card load | per power cycle |
| Activations + KV cache | `0xA10000` | ~960 KB | program, at runtime | per run |
| Free | `0xB00000` | 4 MB | — | — |
| Stack | `0xF00000`-`0xFFFFF0` | 1 MB | processor | always |

**Rules**
- A load that would exceed its region must be refused and reported (FR-008), not truncated
  and not allowed to run into the neighbouring region.
- Weights are read-only after loading. Any write to `0x900000`-`0x9FFFFF` during generation
  is a defect.
- The KV cache size is `2 × n_layers × seq_len × kv_dim × 4` bytes and is the dominant
  runtime allocation; it scales with `seq_len`, which is the first thing to reduce if the
  region proves tight.

**Relationships**: the program's linker script must agree with this table. A change here
requires a matching change there.

---

## 3. Model Artifact

The trained weights, opaque to the board except for its header.

| Field | Type | Notes |
|---|---|---|
| `dim` | int32 | embedding width |
| `hidden_dim` | int32 | feed-forward width |
| `n_layers` | int32 | |
| `n_heads` | int32 | |
| `n_kv_heads` | int32 | may be smaller than `n_heads` |
| `vocab_size` | int32 | **negative signals an unshared classifier** |
| `seq_len` | int32 | maximum context |
| weights | fp32[] | fixed order following the header |

**Validation rules** (FR-015)
- All seven header fields must be positive after taking the absolute value of `vocab_size`.
- Each field must fall within a sane bound; a header of zeros or garbage must be rejected
  rather than used to compute a size.
- The file's actual length must equal the length implied by the header. A short file is the
  expected symptom of a truncated card write and must be caught here (FR-012).
- The implied weight size must fit the region from entity 2 (FR-008).

**Byte order**: little-endian on both host and target; no conversion is performed. Verified
in research R5.

**Relationships**: paired with exactly one Vocabulary Artifact. The pairing is a correctness
requirement, not a convenience — see entity 4.

---

## 4. Vocabulary Artifact

The token-to-text mapping.

| Field | Type |
|---|---|
| `max_token_length` | int32 |
| per token: `score` | float32 |
| per token: `length` | int32 |
| per token: `bytes` | byte[length] |

**Validation rules**
- The number of token records read must equal `abs(vocab_size)` from the model header
  (FR-018a). A mismatch must be reported and must stop the run.
- This is the highest-value validation in the feature. A mismatched pair does not crash — it
  produces fluent-looking but wrong text, a failure that is easily misattributed to a
  numerical or memory fault and can consume a great deal of debugging time.

**Relationships**: one-to-one with Model Artifact; the two form a matched set.

---

## 5. Program Image

The compiled inference program.

| Property | Value |
|---|---|
| Link base | `0x800000` |
| Entry | jumped to by the monitor's `G` command |
| Transport | XMODEM over serial, monitor `L` command |
| Size | tens of KB; uploads in seconds |
| Change rate | every edit |

**Relationships**: reads the Model and Vocabulary artifacts from their fixed addresses;
writes the Performance Report to the console.

---

## 6. Storage Card

Removable storage, written by a desktop computer, read by the board with no host involved.

| Path | Contents |
|---|---|
| `/model.bin` | Model Artifact |
| `/tokenizer.bin` | Vocabulary Artifact |

**Rules**
- Filesystem must be one the existing FAT library can read, and must be writable by an
  ordinary desktop computer without special tooling (FR-010a).
- Absent card, unreadable filesystem, and missing file are three distinct failures and must
  be reported distinguishably (FR-012) — they have different fixes.
- Loading must be repeatable on demand from the console so a reset does not require a host
  transfer (FR-010b).

---

## 7. Performance Report

Produced at the end of a run; the primary deliverable of User Story 5.

| Field | Unit | Requirement |
|---|---|---|
| tokens generated | count | |
| elapsed | cycles and seconds | |
| generation rate | tokens/second | FR-017, SC-008 ≥ 0.5 |
| per-category cycles | cycles and % of total | FR-019 |
| category coverage | % | FR-020, must be ≥ 90 |
| largest category | name | SC-010 |

**Categories**: matrix multiply, attention, normalisation, rotary position encoding,
sampling, other.

**Rules**
- Categories must be mutually exclusive so percentages sum meaningfully.
- "Other" is the unattributed remainder and is what proves the ≥90% coverage claim; it must
  be computed as a residual, not estimated.

---

## 8. Load Report

Produced when the model is loaded from the card (FR-012a).

| Field | Unit |
|---|---|
| bytes loaded | count |
| elapsed | seconds |
| throughput | KB/s |
| verification result | pass/fail |

**Rationale**: this exists specifically to replace the estimate behind SC-005 with a measured
number. It is the first hardware measurement that should be taken, because the whole loading
strategy depends on it (research R6).
