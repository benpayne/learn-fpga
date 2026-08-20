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
    uint32_t status;
    do {
        status = acc_get(ACC_STATUS);
    } while ((status & ACC_BUSY) || !(status & (ACC_DONE | ACC_ERR)));
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

**A `!BUSY` read alone is NOT sufficient to conclude the operation is finished — this is a real
race, not a theoretical one; T035/T036's integration testbench hit it on the very first
operation it ever ran.** `BUSY` (`acc_regs.v`'s status word, bit 0) is an unlatched passthrough
of `acc_top.v`'s `op_busy_r` register: it reads 0 the same cycle the control FSM leaves
`S_RUNNING`. `DONE` (bit 1) is `acc_top.v`'s one-cycle `op_done` pulse, and `acc_regs.v` only
captures that pulse into its own `done_latched` register on `acc_regs`' *own* next clock edge —
one cycle after `BUSY` has already dropped. A driver that spins on `while (status & ACC_BUSY)`
alone, as an earlier revision of this example did, can sample `STATUS` in exactly that one-cycle
window and see `BUSY==0` with neither `DONE` nor `ERR` set yet, and incorrectly treat the
operation as abandoned or the result buffer as unwritten. The fixed idiom above closes the
window by also requiring `DONE` or `ERR`, both of which are genuinely latched (they hold until
read/overwritten, so there is no equivalent race waiting the other way around). Any driver that
checks `DONE` explicitly instead of using the blocking form above MUST apply the same rule.

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
| `mode` not implemented | `ERR_MODE` | unrecognised or not-yet-built mode |

A rejected descriptor MUST NOT start and MUST NOT modify the result buffer.

`ERR_MODE` was added during T034. `acc_top.v` decoded only `ACC_MODE_MATMUL` and let every
other mode value fall through, so an attention-mode descriptor issued before US6 exists would
have run as a matmul and returned confident, wrong numbers. An unimplemented mode must be
rejected loudly rather than silently reinterpreted.

---

## Register indices

The numeric indices live in **`FemtoRV/RTL/ACCEL/acc_bits.vh`**, which is the single definition
the RTL compiles against. The firmware header MUST mirror it exactly:

| Index | Name | Access |
|---|---|---|
| 0 | `ACC_REG_W_Q_BASE` | W — SDRAM address of the int8 weight block |
| 1 | `ACC_REG_W_S_BASE` | W — SDRAM address of the fp32 scale block |
| 2 | `ACC_REG_X_SLOT` | W — BRAM slot holding the quantized activation |
| 3 | `ACC_REG_OUT_SLOT` | W — result BRAM slot |
| 4 | `ACC_REG_N` | W — inner dimension |
| 5 | `ACC_REG_D` | W — outer dimension |
| 6 | `ACC_REG_GS` | W — group size (a file parameter, not a constant) |
| 7 | `ACC_REG_MODE` | W — `0` matmul, `1` att-score, `2` att-sum |
| 8 | `ACC_REG_CTRL` | W — bit 0 START, bit 1 ABORT |
| 9 | `ACC_REG_STATUS` | R — see the bit layout below |
| 10 | `ACC_REG_PERF_CYC` | R — cycles active |
| 11 | `ACC_REG_PERF_STALL` | R — of which, waiting on memory |

`ACC_REG_STATUS` bit layout, as `acc_regs.v` actually builds it:

| Bits | Field |
|---|---|
| 0 | `BUSY` |
| 1 | `DONE` |
| 2 | `ERR` |
| 3 | reserved |
| 7:4 | error code (`ACC_ERR_*`), valid when `ERR` is set |
| 15:8 | descriptor queue depth |
| 31:16 | reserved |

Access is index-then-data through the two IO addresses `IO_ACC_IDX` and `IO_ACC_DAT`
(`HardwareConfig_bits.v` bits 10 and 11), the same packed-register shape the GPU uses, because
the 20-bit IO space had no room for twelve individually decoded addresses (research R7).

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
