# Contract: Console Interface

**Branch**: `003-llama2-minimal-soc`

The operator-facing interface over the serial connection, at 115200 8N1. This is the only
interface the board exposes; there is no display, keyboard, or network.

---

## Monitor commands (existing, unchanged)

Provided by the BIOS monitor in boot ROM. Verified present at `FIRMWARE/monitor` — commands
`H D E S L G C M`.

| Command | Purpose | Used by this feature for |
|---|---|---|
| `H` | help | — |
| `D <addr>` | dump memory | spot-checking that the model landed at `0x900000` |
| `E <addr>` | examine | |
| `S <addr> <val>` | store | |
| `L` | XMODEM upload | receiving the program image (FR-009) |
| `G <addr>` | jump to address | starting the program |
| `M` | memory info | |

**Contract**: this feature must not change any of these. They are the fallback path if
anything new fails.

---

## Memory test

**Invocation**: from the console, covering the full usable external RAM range.

**Output contract**
- Reports pass or fail, and on failure the address and the expected/actual values.
- Reports sustained transfer rate in a documented unit (FR-006).
- Covers 100% of the usable range (SC-003).

**Success**: zero errors across three consecutive runs (SC-003).

---

## Model load

**Invocation**: a console command, repeatable on demand without a host transfer (FR-010b).

**Output contract** — the Load Report from data-model entity 8:

```
loading /model.bin ... 1064960 bytes in 21.4 s (48.6 KB/s)
verify: OK
model: dim=64 layers=5 heads=8 kv_heads=4 vocab=512 seq_len=512
loading /tokenizer.bin ... OK (512 tokens)
```

**Failure contract** — these must be distinguishable, because they have different fixes:

| Condition | Required behaviour |
|---|---|
| No card fitted | report plainly; do not hang |
| Unreadable filesystem | report as a filesystem error, distinct from a missing file |
| File missing | name the path that was not found |
| File shorter than header implies | report as truncated (FR-012) |
| Header implies more than the region holds | refuse before loading (FR-008) |
| Token count ≠ `abs(vocab_size)` | refuse; this is the mismatched-pair trap (FR-018a) |
| Card removed mid-load | fail visibly; do not continue with partial data |

---

## Generation

**Invocation**: accepts a starting prompt, a token count, and a random seed (FR-014).

**Output contract**
- Tokens are emitted **incrementally as produced**, not buffered to the end. This is both a
  requirement (User Story 4 scenario 1) and the operator's only progress indicator on a run
  that may take minutes.
- Terminates cleanly on reaching the requested count or `seq_len` (FR-016).
- Ends with the generation rate (FR-017).

**Determinism**: identical model, prompt, and seed produce byte-identical output (SC-009).
This is what makes the timing measurements comparable across runs.

---

## Performance report

**Invocation**: a measurement mode of the generation command.

**Output contract** — the Performance Report from data-model entity 7:

```
tokens: 100 in 47.2 s (2.12 tok/s)
  matmul       58.1%
  rope         14.7%
  softmax      12.2%
  rmsnorm       6.4%
  sample        3.1%
  other         5.5%
largest: matmul
coverage: 94.5%
```

**Rules**: categories mutually exclusive; `other` computed as a residual, not estimated;
coverage ≥90% (FR-020). The illustrative percentages above are **not** predictions — the
actual split is the finding this feature exists to produce.
