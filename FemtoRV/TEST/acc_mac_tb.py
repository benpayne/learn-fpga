"""
Cocotb testbench for acc_mac.v (FemtoRV/RTL/ACCEL/acc_mac.v).

Written BEFORE the implementation (T029, constitution Principle II/IV): this
file defines correct behaviour independently of how acc_mac.v happens to be
built. The reference model below is intentionally a literal transcription
of runq.c's group loop (research R2, DESIGN.md sec 3.4/3.5):

    ival = sum over the group of (int32)w_q[k] * (int32)x_q[k]   # exact integer
    result = (float)ival * w_scale * x_scale                     # chained float32 multiply

Comparisons:
  - group_acc (the raw int32 dot product) is compared BIT-FOR-BIT. Integer
    accumulation has no rounding ambiguity, so there is no excuse for a
    tolerance check here -- that is the whole reason int8 was chosen over
    fp16 (DESIGN.md sec 3.4).
  - row_result (the rescaled, row-accumulated fp32 value) is also compared
    BIT-FOR-BIT, against a numpy float32 reference that performs the same
    round-to-nearest-even chained multiply-then-accumulate runq.c performs
    in C `float` arithmetic. acc_mac.v implements its own IEEE754 binary32
    multiply/add for this path (constitution: "Floating-point datapaths
    MUST specify rounding and accumulation order deliberately if
    bit-exactness is claimed" -- here it is: round-to-nearest-even,
    accumulated in the same left-to-right group order runq.c uses).

Pipeline timing this testbench assumes (see acc_mac.v header comment):
  - group_done/group_acc: registered, 1 cycle after the in_valid chunk that
    supplies the group's last element.
  - row_valid/row_result: registered, 4 more cycles after group_done (a
    4-stage int->float / mul / mul / accumulate pipeline), pulsing once per
    GROUP (not once per row) with the row's running accumulator; the
    pulse coinciding with a row's last group is its committed result.
"""

import random
import struct

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

LANES = 4          # must match acc_mac's LANES default
ELEM_WIDTH = 8
ACC_WIDTH = 32

GROUP_TO_ROW_LATENCY = 4   # cycles from group_done to row_valid (acc_mac.v Stage 1-4)


# ---------------------------------------------------------------------------
# Bit-level helpers
# ---------------------------------------------------------------------------

def to_bits(v, width):
    return v & ((1 << width) - 1)


def to_signed(v, width):
    v &= (1 << width) - 1
    if v & (1 << (width - 1)):
        v -= (1 << width)
    return v


def pack_lanes(vals, elem_width=ELEM_WIDTH):
    packed = 0
    for i, v in enumerate(vals):
        packed |= to_bits(v, elem_width) << (i * elem_width)
    return packed


def f32_to_bits(x):
    return int(np.float32(x).view(np.uint32))


def bits_to_f32(bits):
    return np.uint32(bits & 0xFFFFFFFF).view(np.float32)


# ---------------------------------------------------------------------------
# Golden reference model (runq.c semantics, research R2)
# ---------------------------------------------------------------------------

def ref_group_ival(w, x):
    """Exact int32 dot product. Python ints are unbounded, matching C int32
    for the magnitudes this application ever produces (research R9)."""
    return sum(int(a) * int(b) for a, b in zip(w, x))


def ref_rescale(ival, w_scale, x_scale):
    """(float)ival * w_scale * x_scale, evaluated left-to-right in float32,
    matching runq.c's `((float) ival) * w->s[g] * x->s[g]`."""
    f = np.float32(ival)
    f = np.float32(f) * np.float32(w_scale)
    f = np.float32(f) * np.float32(x_scale)
    return np.float32(f)


def ref_row_add(row_acc_f32, rescaled_f32):
    return np.float32(np.float32(row_acc_f32) + np.float32(rescaled_f32))


def rand_int8(rng):
    return rng.randint(-128, 127)


def rand_vec(n, rng):
    return [rand_int8(rng) for _ in range(n)]


def rand_scale(rng):
    """A plausible Q8_0 scale: positive, roughly the range abs-max/127 would
    produce for weights/activations of order 0.01-10."""
    return np.float32(rng.uniform(1e-4, 4.0))


# ---------------------------------------------------------------------------
# DUT drivers
# ---------------------------------------------------------------------------

async def start_clock(dut):
    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz, matches project convention
    cocotb.start_soon(clock.start())


async def reset_dut(dut):
    dut.resetn.value = 0
    dut.in_valid.value = 0
    dut.w_data.value = 0
    dut.x_data.value = 0
    dut.gs.value = 64
    dut.group_start.value = 0
    dut.row_start.value = 0
    dut.w_scale.value = 0
    dut.x_scale.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 2)


async def feed_group(dut, w_full, x_full, gs, row_start, w_scale, x_scale):
    """Stream one full group of `gs` int8 elements, LANES per cycle. Leaves
    the bus idle (in_valid=0) after the last chunk -- the caller is
    responsible for waiting out the pipeline latency before checking
    group_done/group_acc/row_valid/row_result."""
    assert len(w_full) == gs and len(x_full) == gs
    assert gs % LANES == 0
    dut.gs.value = gs
    dut.w_scale.value = f32_to_bits(w_scale)
    dut.x_scale.value = f32_to_bits(x_scale)
    nchunks = gs // LANES
    for i in range(nchunks):
        cw = w_full[i * LANES:(i + 1) * LANES]
        cx = x_full[i * LANES:(i + 1) * LANES]
        dut.w_data.value = pack_lanes(cw)
        dut.x_data.value = pack_lanes(cx)
        dut.in_valid.value = 1
        dut.group_start.value = 1 if i == 0 else 0
        dut.row_start.value = 1 if (i == 0 and row_start) else 0
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.group_start.value = 0
    dut.row_start.value = 0


async def feed_partial_group(dut, w_partial, x_partial, gs, row_start, w_scale, x_scale):
    """Stream FEWER than gs elements (a ragged remainder) and then go idle.
    Used by the ragged-group test: acc_mac must never assert group_done for
    this, since it never reaches gs."""
    assert len(w_partial) == len(x_partial)
    assert len(w_partial) % LANES == 0
    assert len(w_partial) < gs
    dut.gs.value = gs
    dut.w_scale.value = f32_to_bits(w_scale)
    dut.x_scale.value = f32_to_bits(x_scale)
    nchunks = len(w_partial) // LANES
    for i in range(nchunks):
        cw = w_partial[i * LANES:(i + 1) * LANES]
        cx = x_partial[i * LANES:(i + 1) * LANES]
        dut.w_data.value = pack_lanes(cw)
        dut.x_data.value = pack_lanes(cx)
        dut.in_valid.value = 1
        dut.group_start.value = 1 if i == 0 else 0
        dut.row_start.value = 1 if (i == 0 and row_start) else 0
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.group_start.value = 0
    dut.row_start.value = 0


async def wait_group_result(dut):
    """Cocotb deposits a `.value =` write for application at the next clock
    edge, so feed_group()'s last RisingEdge is the edge that *samples* the
    group's final chunk; group_done_q/group_acc_q register in response to
    that sampling and become readable after ONE further RisingEdge. Call
    this immediately after feed_group() returns. Returns
    (group_done, group_acc_signed)."""
    await RisingEdge(dut.clk)
    gd = int(dut.group_done.value)
    ga = to_signed(int(dut.group_acc.value), ACC_WIDTH)
    return gd, ga


async def wait_row_result(dut, extra_cycles=GROUP_TO_ROW_LATENCY):
    """Call immediately after wait_group_result() to advance the remaining
    GROUP_TO_ROW_LATENCY register stages (int->float, mul, mul, accumulate)
    to the matching row_valid/row_result cycle."""
    rv = 0
    rr = 0.0
    for _ in range(extra_cycles):
        await RisingEdge(dut.clk)
        rv = int(dut.row_valid.value)
        rr = bits_to_f32(int(dut.row_result.value))
    return rv, rr


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_single_group_random(dut):
    """Single-group rows (n==gs), random int8 vectors, gs=64. Checks
    group_acc bit-exact and row_result bit-exact against the numpy float32
    reference."""
    await start_clock(dut)
    await reset_dut(dut)
    rng = random.Random(1)

    for trial in range(20):
        gs = 64
        w = rand_vec(gs, rng)
        x = rand_vec(gs, rng)
        w_scale = rand_scale(rng)
        x_scale = rand_scale(rng)

        await feed_group(dut, w, x, gs, row_start=True, w_scale=w_scale, x_scale=x_scale)
        gd, ga = await wait_group_result(dut)
        assert gd == 1, f"trial {trial}: group_done did not fire"

        exp_ival = ref_group_ival(w, x)
        assert ga == exp_ival, f"trial {trial}: group_acc {ga} != expected {exp_ival}"

        rv, rr = await wait_row_result(dut)
        assert rv == 1, f"trial {trial}: row_valid did not fire"
        exp_row = ref_rescale(exp_ival, w_scale, x_scale)
        assert f32_to_bits(rr) == f32_to_bits(exp_row), (
            f"trial {trial}: row_result 0x{f32_to_bits(rr):08x} ({float(rr)}) != "
            f"expected 0x{f32_to_bits(exp_row):08x} ({float(exp_row)})"
        )


@cocotb.test()
async def test_all_zero(dut):
    """All-zero weight and activation vectors: ival must be exactly 0, and
    the rescaled result must be +0.0 regardless of the (nonzero) scales."""
    await start_clock(dut)
    await reset_dut(dut)

    gs = 64
    w = [0] * gs
    x = [0] * gs
    w_scale = np.float32(0.375)
    x_scale = np.float32(1.25)

    await feed_group(dut, w, x, gs, row_start=True, w_scale=w_scale, x_scale=x_scale)
    gd, ga = await wait_group_result(dut)
    assert gd == 1
    assert ga == 0, f"all-zero group_acc should be 0, got {ga}"

    rv, rr = await wait_row_result(dut)
    assert rv == 1
    assert f32_to_bits(rr) == 0x00000000, f"all-zero row_result should be +0.0, got 0x{f32_to_bits(rr):08x}"


@cocotb.test()
async def test_extremes(dut):
    """int8 boundary values, including -128, the asymmetric extreme that
    has no positive counterpart. Covers +127/+127, -128/-128 and the two
    cross-sign extremes, each as a uniform vector so the expected int32 sum
    is easy to hand-verify (gs * product)."""
    await start_clock(dut)
    await reset_dut(dut)
    gs = 32

    cases = [
        (127, 127),
        (-128, -128),
        (127, -128),
        (-128, 127),
    ]
    for wv, xv in cases:
        w = [wv] * gs
        x = [xv] * gs
        w_scale = np.float32(1.0)
        x_scale = np.float32(1.0)

        await feed_group(dut, w, x, gs, row_start=True, w_scale=w_scale, x_scale=x_scale)
        gd, ga = await wait_group_result(dut)
        assert gd == 1
        exp_ival = gs * wv * xv
        assert ga == exp_ival, f"w={wv} x={xv}: group_acc {ga} != expected {exp_ival}"

        rv, rr = await wait_row_result(dut)
        assert rv == 1
        exp_row = ref_rescale(exp_ival, w_scale, x_scale)
        assert f32_to_bits(rr) == f32_to_bits(exp_row), (
            f"w={wv} x={xv}: row_result mismatch: 0x{f32_to_bits(rr):08x} != 0x{f32_to_bits(exp_row):08x}"
        )


@cocotb.test()
async def test_group_sizes(dut):
    """GS is a runtime value, not a synthesis constant (data-model.md entity
    4, research R3). Exercise 32, 64 and 128 back-to-back on the same DUT
    instance with no re-elaboration."""
    await start_clock(dut)
    await reset_dut(dut)
    rng = random.Random(2)

    for gs in (32, 64, 128):
        w = rand_vec(gs, rng)
        x = rand_vec(gs, rng)
        w_scale = rand_scale(rng)
        x_scale = rand_scale(rng)

        await feed_group(dut, w, x, gs, row_start=True, w_scale=w_scale, x_scale=x_scale)
        gd, ga = await wait_group_result(dut)
        assert gd == 1, f"gs={gs}: group_done did not fire"
        exp_ival = ref_group_ival(w, x)
        assert ga == exp_ival, f"gs={gs}: group_acc {ga} != expected {exp_ival}"

        rv, rr = await wait_row_result(dut)
        assert rv == 1
        exp_row = ref_rescale(exp_ival, w_scale, x_scale)
        assert f32_to_bits(rr) == f32_to_bits(exp_row), f"gs={gs}: row_result mismatch"


@cocotb.test()
async def test_multi_group_row(dut):
    """A row spanning several groups (n=192, gs=64 -> 3 groups). Checks that
    row_result accumulates across groups in the same left-to-right order
    runq.c's `val +=` loop uses, and that each group's row_valid pulse
    (not just the last) carries the correct running total -- acc_top is
    what decides which pulse is the row's committed result, but every
    pulse must independently be correct."""
    await start_clock(dut)
    await reset_dut(dut)
    rng = random.Random(3)

    gs = 64
    n_groups = 3
    w_groups = [rand_vec(gs, rng) for _ in range(n_groups)]
    x_groups = [rand_vec(gs, rng) for _ in range(n_groups)]
    w_scales = [rand_scale(rng) for _ in range(n_groups)]
    x_scales = [rand_scale(rng) for _ in range(n_groups)]

    running_row = np.float32(0.0)
    for i in range(n_groups):
        await feed_group(
            dut, w_groups[i], x_groups[i], gs,
            row_start=(i == 0), w_scale=w_scales[i], x_scale=x_scales[i],
        )
        gd, ga = await wait_group_result(dut)
        assert gd == 1, f"group {i}: group_done did not fire"
        exp_ival = ref_group_ival(w_groups[i], x_groups[i])
        assert ga == exp_ival, f"group {i}: group_acc {ga} != expected {exp_ival}"

        rv, rr = await wait_row_result(dut)
        assert rv == 1, f"group {i}: row_valid did not fire"

        rescaled = ref_rescale(exp_ival, w_scales[i], x_scales[i])
        running_row = rescaled if i == 0 else ref_row_add(running_row, rescaled)
        assert f32_to_bits(rr) == f32_to_bits(running_row), (
            f"group {i}: row_result 0x{f32_to_bits(rr):08x} != running total 0x{f32_to_bits(running_row):08x}"
        )


@cocotb.test()
async def test_ragged_group_not_multiple_of_gs(dut):
    """n=100 is NOT a multiple of gs=32 (3*32=96, remainder 4). This project
    already lost hours once to GS-not-dividing-n being silently truncated
    in software (runq.c's matmul via export.py's backoff check, research
    R15). The hardware's contribution to closing that failure mode is
    structural: acc_mac must NEVER assert group_done for an incomplete
    group, so there is no way for a short final chunk to silently produce
    a "valid-looking" partial result. Rejecting a ragged descriptor before
    streaming starts is acc_top's job (data-model.md entity 4, FR-009);
    this test proves acc_mac itself cannot be fooled into completing one
    even if something upstream failed to reject it.
    """
    await start_clock(dut)
    await reset_dut(dut)
    rng = random.Random(4)

    gs = 32
    full_groups = 3
    remainder = 4  # 100 - 3*32

    group_done_count = 0

    for g in range(full_groups):
        w = rand_vec(gs, rng)
        x = rand_vec(gs, rng)
        w_scale = rand_scale(rng)
        x_scale = rand_scale(rng)
        await feed_group(dut, w, x, gs, row_start=(g == 0), w_scale=w_scale, x_scale=x_scale)
        gd, ga = await wait_group_result(dut)
        assert gd == 1, f"full group {g}: group_done did not fire"
        assert ga == ref_group_ival(w, x)
        group_done_count += 1
        # drain the rescale pipeline before the next group so row_valid
        # bookkeeping in this test stays simple
        await wait_row_result(dut)

    # Ragged remainder: fewer than gs elements, then go idle. group_done
    # must never fire for it, no matter how long we wait.
    w_rem = rand_vec(remainder, rng)
    x_rem = rand_vec(remainder, rng)
    await feed_partial_group(dut, w_rem, x_rem, gs, row_start=False,
                              w_scale=np.float32(1.0), x_scale=np.float32(1.0))

    for _ in range(50):
        await RisingEdge(dut.clk)
        assert int(dut.group_done.value) == 0, (
            "group_done fired for a ragged (incomplete) group -- this would let a "
            "descriptor where n is not a multiple of gs silently produce a wrong "
            "result instead of being rejected upstream (FR-009)"
        )

    assert group_done_count == full_groups


@cocotb.test()
async def test_bit_exact_1000_cases(dut):
    """SC-005: at least 1000 randomised cases, bit-for-bit identical to the
    host reference. Both group_acc (int32, exact by construction) and
    row_result (fp32, round-to-nearest-even) are checked bit-for-bit --
    no tolerance, per the team's explicit instruction that this is the
    entire point of choosing int8 over fp16."""
    await start_clock(dut)
    await reset_dut(dut)
    rng = random.Random(1234)

    NUM_CASES = 1000
    gs_choices = (32, 64, 128)
    checked = 0

    for trial in range(NUM_CASES):
        gs = rng.choice(gs_choices)
        w = rand_vec(gs, rng)
        x = rand_vec(gs, rng)
        w_scale = rand_scale(rng)
        x_scale = rand_scale(rng)

        await feed_group(dut, w, x, gs, row_start=True, w_scale=w_scale, x_scale=x_scale)
        gd, ga = await wait_group_result(dut)
        assert gd == 1, f"trial {trial} (gs={gs}): group_done did not fire"

        exp_ival = ref_group_ival(w, x)
        assert ga == exp_ival, f"trial {trial} (gs={gs}): group_acc {ga} != expected {exp_ival}"

        rv, rr = await wait_row_result(dut)
        assert rv == 1, f"trial {trial} (gs={gs}): row_valid did not fire"
        exp_row = ref_rescale(exp_ival, w_scale, x_scale)
        assert f32_to_bits(rr) == f32_to_bits(exp_row), (
            f"trial {trial} (gs={gs}): row_result 0x{f32_to_bits(rr):08x} ({float(rr)}) != "
            f"expected 0x{f32_to_bits(exp_row):08x} ({float(exp_row)})"
        )
        checked += 1

    dut._log.info(f"test_bit_exact_1000_cases: {checked} cases, all bit-identical to the host reference")
    assert checked >= 1000
