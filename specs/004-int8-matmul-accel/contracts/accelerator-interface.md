# Contract: Accelerator Interface

**Branch**: `004-int8-matmul-accel`

The interface between firmware and the accelerator. This is the contract stages 3-6 are tested
against.

---

## Issuing an operation

```c
/* Blocking form. Correct and simple; use for bring-up. */
static void acc_matmul_q8(int out_slot, const QuantizedTensor *w,
                          int x_slot, int n, int d, int gs) {
    acc_set(ACC_W_Q_BASE, (uint32_t)w->q);
    acc_set(ACC_W_S_BASE, (uint32_t)w->s);
    acc_set(ACC_X_SLOT,   x_slot);
    acc_set(ACC_OUT_SLOT, out_slot);
    acc_set(ACC_N, n);
    acc_set(ACC_D, d);
    acc_set(ACC_GS, gs);
    acc_set(ACC_MODE, ACC_MODE_MATMUL);
    acc_set(ACC_CTRL, ACC_START);
    while (acc_get(ACC_STATUS) & ACC_BUSY) { /* spin */ }
}
```

**Preconditions**
- The quantized activation vector is already in BRAM slot `x_slot`.
- `n % gs == 0`, `gs` is a supported power of two, `n` and `d` within configured maxima.

**Postconditions**
- `d` fp32 results are in result-BRAM slot `out_slot`, readable by ordinary loads.
- `ACC_STATUS` has `DONE` set and `BUSY` clear.
- `PERF_CYCLES` and `PERF_STALL` describe the operation just completed.

**Contract on the spin loop**: it MUST fit the CPU instruction cache. If it does not, waiting
generates SDRAM traffic that competes with the very transfer being waited on (FR-015). Check
this in the disassembly rather than assuming it.

---

## Results

| Property | Contract |
|---|---|
| Location | result BRAM at `0x100000 + slot * slot_size` |
| Type | fp32, `d` values |
| Validity | only when `BUSY` is clear |
| Reading while BUSY | MUST be prevented or flagged not-ready; MUST NOT return partial data |

Results never enter SDRAM. The CPU cache cannot hold a stale copy of them.

---

## Error reporting

Every rejection MUST be distinguishable — these have different fixes:

| Condition | Error code | Meaning |
|---|---|---|
| `n % gs != 0` | `ERR_DIM` | inner dimension not a whole number of groups |
| `gs` unsupported | `ERR_GS` | group size not a supported power of two |
| `n` or `d` too large | `ERR_RANGE` | exceeds configured maxima |
| `d*4` exceeds slot | `ERR_SLOT` | result would overflow its buffer |
| START while BUSY and queue full | `ERR_FULL` | back-pressure, not a fault |

A rejected descriptor MUST NOT start and MUST NOT modify the result buffer.

---

## Abort and recovery

`ACC_CTRL.ABORT` MUST return the accelerator to `IDLE` from any state within a bounded time,
flush the weight FIFO, and leave the result buffer's contents undefined but its structure
intact. After abort, a fresh descriptor MUST behave normally.

This exists so a hung operation cannot wedge the board (spec edge case). The firmware SHOULD
apply a timeout around the spin loop and abort rather than waiting forever.

---

## Performance counters

```
PERF_CYCLES : cycles the operation was active
PERF_STALL  : of which, cycles waiting on memory
```

**This ratio is the feature's primary diagnostic** (SC-015). A disappointing speed-up with high
`PERF_STALL` means bandwidth — look at arbitration and burst length. With low `PERF_STALL` it
means control logic — look at the FSM and FIFO. Without these counters that distinction cannot
be made on hardware, which is why FR-008 makes them mandatory rather than optional.

---

## Attention modes

Same descriptor, different address pattern (research: design section 7).

| Mode | Streams | Resident | Produces |
|---|---|---|---|
| `MODE_MATMUL` | weight `q` block | quantized activation | `d` values |
| `MODE_ATT_SCORE` | key cache | query vector | `pos+1` scores |
| `MODE_ATT_SUM` | value cache | softmaxed weights | `head_size` values |

Softmax between modes 1 and 2 stays on the CPU.

**Known inefficiency to measure, not to fix upfront**: the KV cache is laid out
`[layer][pos][kv_dim]`, so one head's keys are strided by `kv_dim * 4` = 128 bytes — smaller
than a 64-word (256 B) burst. Naive bursting therefore fetches data for neighbouring heads too.
Quantify the waste in stage 5 and add a strided mode only if the measurement justifies it.
