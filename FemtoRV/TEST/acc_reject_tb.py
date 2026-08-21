"""
Cocotb testbench for the int8 MatMul accelerator's descriptor REJECTION
paths (T038, feature 004-int8-matmul-accel).

Targets acc_regs.v DIRECTLY (TOPLEVEL=acc_regs, no wrapper -- same
"instantiate the raw module" style acc_mac_tb.py already uses for
acc_mac.v), not acc_top/acc_unit_tb.py, for two reasons the team lead
gave: acc_unit_tb.py is mac-unit's file right now, and acc_regs.v is
where the ACCEPT-TIME validation this test is about actually lives
(constitution: bottom-up testing order).

*** SCOPE BOUNDARY -- READ BEFORE ADDING A TEST HERE ***
Of the six ACC_ERR_* codes, acc_regs.v itself only COMPUTES three:
  - ACC_ERR_DIM  (reject_dim:  start_req && !gs_bad && (n % gs != 0))
  - ACC_ERR_GS   (reject_gs:   start_req && gs_bad)
  - ACC_ERR_FULL (reject_full: start_req && !gs_bad && !dim_bad && queue_full)
These three are genuinely, fully testable here: this file drives real
descriptor field values through the real combinational reject_*/push_ok
logic and observes the real consequence (STATUS.ERR/code, queue depth,
whether the descriptor entered the FIFO).

The other three -- ACC_ERR_RANGE (n/d vs MAX_N/MAX_D), ACC_ERR_SLOT (d vs
result-slot capacity, xq/xs vs activation-slot capacity), and ACC_ERR_MODE
(mode != MATMUL) -- are NOT computed by acc_regs.v at all. acc_regs.v's own
header comment says so explicitly: those three need MAX_N/MAX_D/
RESULT_AWIDTH/ACT_XQ_WORDS/ACT_XS_WORDS, which are acc_top.v/
acc_weight_fetch.v parameters this module does not have. They arrive at
acc_regs.v purely as the `op_error`/`op_error_code` INPUT pins -- acc_top's
job, tested by acc_unit_tb.py (or a future acc_top-focused suite), not this
one. What THIS file can honestly prove for those three is narrower: that
acc_regs.v correctly LATCHES and REPORTS whatever error code the upstream
FSM feeds it via op_error/op_error_code, with the right STATUS bit layout
and the right priority against a simultaneous local reject. It CANNOT prove
that a real out-of-range n/d or a real bad mode value actually produces
that op_error/op_error_code in the first place -- that is acc_top.v's
logic and is out of scope here. Every RANGE/SLOT/MODE test below is named
and commented to make this distinction impossible to miss.

Also note, per acc_regs.v's own logic: an out-of-range/oversized/bad-mode
descriptor (the RANGE/SLOT/MODE class) DOES get pushed into the FIFO by
acc_regs.v -- there is nothing in reject_gs/reject_dim/reject_full that
catches it, and push_ok does not check n/d/mode range at all. Rejection for
that class happens LATER, when acc_top pops the descriptor and evaluates
accept_range_bad/accept_slot_bad/accept_mode_bad -- by which point, from
acc_regs.v's perspective, the (eventually-invalid) descriptor already
"started" in the sense of leaving the queue. FR-009 ("a rejected descriptor
MUST NOT start... MUST NOT modify the result buffer") therefore is NOT
fully acc_regs.v's responsibility to enforce for this class -- see
test_range_slot_mode_descriptors_are_pushed_not_rejected_locally below,
which demonstrates this explicitly as a documented finding rather than
leaving it implicit.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ---------------------------------------------------------------------------
# acc_bits.vh mirrored here (same convention acc_unit_tb.py/acc_mac_tb.py
# use -- no shared python constants module in this project; if these ever
# drift from FemtoRV/RTL/ACCEL/acc_bits.vh, tests should fail loudly rather
# than silently mis-address).
# ---------------------------------------------------------------------------

ACC_REG_W_Q_BASE = 0
ACC_REG_W_S_BASE = 1
ACC_REG_X_SLOT = 2
ACC_REG_OUT_SLOT = 3
ACC_REG_N = 4
ACC_REG_D = 5
ACC_REG_GS = 6
ACC_REG_MODE = 7
ACC_REG_CTRL = 8
ACC_REG_STATUS = 9
ACC_REG_PERF_CYC = 10
ACC_REG_PERF_STALL = 11

ACC_CTRL_START = 1 << 0
ACC_CTRL_ABORT = 1 << 1

ACC_STATUS_BUSY = 1 << 0
ACC_STATUS_DONE = 1 << 1
ACC_STATUS_ERR = 1 << 2

ACC_ERR_NONE = 0
ACC_ERR_DIM = 1
ACC_ERR_GS = 2
ACC_ERR_RANGE = 3
ACC_ERR_SLOT = 4
ACC_ERR_FULL = 5
ACC_ERR_MODE = 6

ACC_MODE_MATMUL = 0
ACC_MODE_ATT_SCORE = 1
ACC_MODE_ATT_SUM = 2

ACC_GS_MIN = 8   # acc_bits.vh raised this from 4 (research R26 addendum): gs=4
                 # (== LANES) leaves acc_top.v's per-group scale registers no
                 # settle cycle, a genuine correctness hazard, not just an
                 # unused allowance. Keep in sync with the `define.
ACC_GS_MAX = 1024

# acc_regs.v defaults (module parameters -- not overridden by this
# testbench's instantiation, since no wrapper is used).
QUEUE_DEPTH = 16
ERR_WIDTH = 4


def to_bits(v, width):
    """Two's-complement-safe unsigned bit pattern for a cocotb .value write."""
    return v & ((1 << width) - 1)


def status_fields(status):
    """(busy, done, err, err_code, queue_depth) from a raw STATUS word,
    per acc_regs.v's status_word assign / acc_bits.vh layout (also the
    layout specs/004-int8-matmul-accel/contracts/accelerator-interface.md
    documents as of commit eeb1cba): 0 BUSY, 1 DONE, 2 ERR, 3 reserved,
    7:4 error code, 15:8 queue depth."""
    busy = status & ACC_STATUS_BUSY
    done = bool(status & ACC_STATUS_DONE)
    err = bool(status & ACC_STATUS_ERR)
    err_code = (status >> 4) & 0xF
    queue_depth = (status >> 8) & 0xFF
    return busy, done, err, err_code, queue_depth


# ---------------------------------------------------------------------------
# DUT drive helpers -- acc_regs.v's OWN port names (no io_ prefix; that
# prefix only exists on acc_top.v's ports, which pass through to these).
# ---------------------------------------------------------------------------

async def start_clock(dut):
    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz, matches every other tb here
    cocotb.start_soon(clock.start())


async def reset_dut(dut):
    dut.resetn.value = 0
    dut.wdata.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel_idx.value = 0
    dut.sel_dat.value = 0
    dut.desc_ack.value = 0
    dut.op_busy.value = 0
    dut.op_done.value = 0
    dut.op_error.value = 0
    dut.op_error_code.value = 0
    dut.op_perf_cycles.value = 0
    dut.op_perf_stall.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 5)


async def reg_write(dut, idx, val):
    dut.sel_idx.value = 1
    dut.sel_dat.value = 0
    dut.wstrb.value = 1
    dut.wdata.value = idx
    await RisingEdge(dut.clk)
    dut.sel_idx.value = 0
    dut.sel_dat.value = 1
    dut.wdata.value = to_bits(val, 32)
    await RisingEdge(dut.clk)
    dut.sel_dat.value = 0
    dut.wstrb.value = 0
    # One settle cycle of margin: queue_count/err_latched are registers
    # updated on the SAME edge as the write above, but this project has
    # been bitten by off-by-one latency assumptions on registered signals
    # before (see acc_unit_tb.py's result_read_row() comment) -- cheap
    # insurance against this being one of those cases.
    await RisingEdge(dut.clk)


async def reg_set_index(dut, idx):
    dut.sel_idx.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = idx
    await RisingEdge(dut.clk)
    dut.sel_idx.value = 0
    dut.wstrb.value = 0


async def reg_read_selected(dut):
    dut.sel_dat.value = 1
    dut.rstrb.value = 1
    await RisingEdge(dut.clk)
    val = int(dut.rdata.value)
    dut.sel_dat.value = 0
    dut.rstrb.value = 0
    return val


async def read_status(dut):
    await reg_set_index(dut, ACC_REG_STATUS)
    return await reg_read_selected(dut)


async def stage_descriptor(dut, n, d, gs, mode=ACC_MODE_MATMUL,
                            w_q_base=0, w_s_base=0, x_slot=0, out_slot=0):
    """Writes every descriptor field EXCEPT CTRL -- mirrors acc_top's own
    reset-state defaults where unused, values are simple/arbitrary since
    this suite never lets a descriptor reach acc_weight_fetch (no SDRAM
    port on acc_regs.v to read from anyway)."""
    await reg_write(dut, ACC_REG_W_Q_BASE, w_q_base)
    await reg_write(dut, ACC_REG_W_S_BASE, w_s_base)
    await reg_write(dut, ACC_REG_X_SLOT, x_slot)
    await reg_write(dut, ACC_REG_OUT_SLOT, out_slot)
    await reg_write(dut, ACC_REG_N, n)
    await reg_write(dut, ACC_REG_D, d)
    await reg_write(dut, ACC_REG_GS, gs)
    await reg_write(dut, ACC_REG_MODE, mode)


async def issue_start(dut):
    await reg_write(dut, ACC_REG_CTRL, ACC_CTRL_START)


async def try_descriptor(dut, n, d, gs, mode=ACC_MODE_MATMUL):
    """Stage + START one descriptor, return the STATUS word read
    immediately after (settled per reg_write's own margin cycle)."""
    await stage_descriptor(dut, n, d, gs, mode=mode)
    await issue_start(dut)
    return await read_status(dut)


# ---------------------------------------------------------------------------
# ACC_ERR_DIM -- n not a whole number of groups. research R16: this is the
# code that matters most (runq.c's own silent-truncation incident).
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_err_dim_rejected_distinctly(dut):
    await start_clock(dut)
    await reset_dut(dut)

    depth_before = status_fields(await read_status(dut))[4]
    status = await try_descriptor(dut, n=65, d=8, gs=64)  # 65 % 64 != 0
    busy, done, err, code, depth_after = status_fields(status)

    assert err, "ACC_ERR_DIM: STATUS.ERR must be set for n%gs!=0"
    assert code == ACC_ERR_DIM, f"expected ACC_ERR_DIM({ACC_ERR_DIM}), got {code}"
    assert depth_after == depth_before, (
        "a rejected descriptor MUST NOT start -- queue depth must not "
        f"change (was {depth_before}, now {depth_after})"
    )
    assert not busy, "a rejected descriptor must never assert BUSY"


# ---------------------------------------------------------------------------
# ACC_ERR_GS -- unsupported group size: not a power of two, or outside
# [ACC_GS_MIN, ACC_GS_MAX]. Three independent ways to be gs_bad.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_err_gs_not_power_of_two(dut):
    await start_clock(dut)
    await reset_dut(dut)

    depth_before = status_fields(await read_status(dut))[4]
    status = await try_descriptor(dut, n=60, d=8, gs=5)  # 5 is not a power of two
    busy, done, err, code, depth_after = status_fields(status)

    assert err
    assert code == ACC_ERR_GS, f"expected ACC_ERR_GS({ACC_ERR_GS}), got {code}"
    assert depth_after == depth_before
    assert not busy


@cocotb.test()
async def test_err_gs_below_minimum(dut):
    await start_clock(dut)
    await reset_dut(dut)

    assert ACC_GS_MIN > 1, "test assumes a gs below GS_MIN exists and is a power of two"
    below_min = ACC_GS_MIN // 2  # power of two, still below GS_MIN
    depth_before = status_fields(await read_status(dut))[4]
    status = await try_descriptor(dut, n=below_min * 4, d=8, gs=below_min)
    busy, done, err, code, depth_after = status_fields(status)

    assert err
    assert code == ACC_ERR_GS, (
        f"gs={below_min} is below ACC_GS_MIN={ACC_GS_MIN}: expected "
        f"ACC_ERR_GS({ACC_ERR_GS}), got {code}"
    )
    assert depth_after == depth_before
    assert not busy


@cocotb.test()
async def test_err_gs_above_maximum(dut):
    await start_clock(dut)
    await reset_dut(dut)

    above_max = ACC_GS_MAX * 2  # still a power of two, above GS_MAX
    depth_before = status_fields(await read_status(dut))[4]
    status = await try_descriptor(dut, n=above_max, d=8, gs=above_max)
    busy, done, err, code, depth_after = status_fields(status)

    assert err
    assert code == ACC_ERR_GS, (
        f"gs={above_max} is above ACC_GS_MAX={ACC_GS_MAX}: expected "
        f"ACC_ERR_GS({ACC_ERR_GS}), got {code}"
    )
    assert depth_after == depth_before
    assert not busy


# ---------------------------------------------------------------------------
# Accepting a VALID descriptor: contrast case for the reject tests above,
# and the baseline the queue-depth checks below build on.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_valid_descriptor_is_accepted_and_increments_queue_depth(dut):
    await start_clock(dut)
    await reset_dut(dut)

    depth_before = status_fields(await read_status(dut))[4]
    assert depth_before == 0, "queue must start empty after reset"

    status = await try_descriptor(dut, n=64, d=8, gs=64)
    busy, done, err, code, depth_after = status_fields(status)

    assert not err, f"a valid descriptor (n=64,d=8,gs=64) must not be rejected, got code={code}"
    assert code == ACC_ERR_NONE
    assert depth_after == depth_before + 1, (
        f"accepting a descriptor must increment queue depth: {depth_before} -> {depth_after}"
    )
    assert dut.desc_valid.value == 1, "an accepted descriptor must appear on desc_valid"
    assert int(dut.desc_n.value) == 64
    assert int(dut.desc_d.value) == 8
    assert int(dut.desc_gs.value) == 64


# ---------------------------------------------------------------------------
# ACC_ERR_FULL -- back-pressure, not a fault (acc_bits.vh's own comment).
# Fill the queue to QUEUE_DEPTH with VALID descriptors (each must be
# individually accepted -- proves this is genuine capacity exhaustion, not
# an early false reject), then show the next one is rejected specifically
# with ERR_FULL and does not disturb the queue.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_err_full_after_queue_depth_valid_pushes(dut):
    await start_clock(dut)
    await reset_dut(dut)

    for i in range(QUEUE_DEPTH):
        status = await try_descriptor(dut, n=64, d=8, gs=64)
        busy, done, err, code, depth = status_fields(status)
        assert not err, f"push #{i+1}/{QUEUE_DEPTH} unexpectedly rejected (code={code})"
        assert depth == i + 1, f"push #{i+1}: expected queue depth {i+1}, got {depth}"

    depth_full = status_fields(await read_status(dut))[4]
    assert depth_full == QUEUE_DEPTH

    status = await try_descriptor(dut, n=64, d=8, gs=64)  # still a VALID descriptor
    busy, done, err, code, depth_after = status_fields(status)

    assert err, "a valid descriptor against a full queue must still be rejected"
    assert code == ACC_ERR_FULL, f"expected ACC_ERR_FULL({ACC_ERR_FULL}), got {code}"
    assert depth_after == QUEUE_DEPTH, (
        "ERR_FULL must not modify the queue -- depth must stay at capacity, "
        f"got {depth_after}"
    )
    assert not busy


@cocotb.test()
async def test_err_full_clears_after_a_pop_then_push_succeeds(dut):
    """Confirms ERR_FULL reflects genuine, recoverable back-pressure and
    not a stuck/latched condition: pop one descriptor (desc_ack, as
    acc_top's control FSM would after dequeuing it), then show the queue
    accepts a new push again at depth QUEUE_DEPTH-1 -> QUEUE_DEPTH."""
    await start_clock(dut)
    await reset_dut(dut)

    for _ in range(QUEUE_DEPTH):
        await try_descriptor(dut, n=64, d=8, gs=64)
    depth_full = status_fields(await read_status(dut))[4]
    assert depth_full == QUEUE_DEPTH

    # Pop one, the way acc_top's FSM does: pulse desc_ack for one cycle.
    assert dut.desc_valid.value == 1
    dut.desc_ack.value = 1
    await RisingEdge(dut.clk)
    dut.desc_ack.value = 0
    await RisingEdge(dut.clk)

    depth_after_pop = status_fields(await read_status(dut))[4]
    assert depth_after_pop == QUEUE_DEPTH - 1, (
        f"one desc_ack pop must decrement depth by exactly 1, got "
        f"{depth_full} -> {depth_after_pop}"
    )

    status = await try_descriptor(dut, n=64, d=8, gs=64)
    busy, done, err, code, depth_final = status_fields(status)
    assert not err, "queue has room after the pop -- this push must succeed"
    assert depth_final == QUEUE_DEPTH, f"expected depth back at {QUEUE_DEPTH}, got {depth_final}"


# ---------------------------------------------------------------------------
# RANGE / SLOT / MODE -- see the file-header SCOPE BOUNDARY note. Two
# things are tested per code: (a) the documented FINDING that acc_regs.v's
# own accept-time logic does NOT reject these locally (the descriptor is
# pushed), and (b) that acc_regs.v correctly LATCHES/REPORTS the code when
# the (here: simulated) upstream FSM supplies it via op_error/op_error_code.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_range_slot_mode_descriptors_are_pushed_not_rejected_locally(dut):
    """FINDING, not a bug: acc_regs.v's push_ok only depends on
    gs_bad/dim_bad/queue_full. A descriptor with n/d beyond MAX_N/MAX_D
    (RANGE), d too large for a result slot (SLOT), or an unimplemented
    mode (MODE) is happily enqueued here -- rejecting those is entirely
    acc_top.v's job, exercised after desc_valid/desc_ack hand the
    descriptor off. FR-009 ("a rejected descriptor MUST NOT start") for
    this class of error is therefore a claim about the acc_top+acc_regs
    PAIR, not about acc_regs.v alone."""
    await start_clock(dut)
    await reset_dut(dut)

    # huge_n MUST still be a multiple of gs=64 -- it is only "huge" relative
    # to acc_top's real MAX_N=4096 (which acc_regs.v has no knowledge of),
    # not relative to acc_regs.v's OWN n%gs==0 check, which it still must
    # pass for this to test what it claims to (a first version of this test
    # used n=65535, which is NOT a multiple of 64 and was correctly
    # rejected as ACC_ERR_DIM -- a bug in the test, not a real finding
    # about acc_regs.v checking ranges; fixed here).
    huge_n = 8192   # = 128 * gs, well past MAX_N=4096, still n%gs==0
    huge_d = 65535  # d has no gs-multiple constraint (dim_bad only checks n)
    bad_mode = 3    # not ACC_MODE_MATMUL/ATT_SCORE/ATT_SUM -- acc_top's job to reject

    status = await try_descriptor(dut, n=64, d=huge_d, gs=64)  # SLOT-shaped
    err, code, depth = status_fields(status)[2], status_fields(status)[3], status_fields(status)[4]
    assert not err, (
        "documented finding: acc_regs.v does not itself reject an "
        f"oversized d ({huge_d}) -- got err={err} code={code} instead of "
        "the expected silent accept"
    )
    assert depth == 1

    await reset_dut(dut)
    status = await try_descriptor(dut, n=huge_n, d=8, gs=64)  # RANGE-shaped
    err, depth = status_fields(status)[2], status_fields(status)[4]
    assert not err, "documented finding: acc_regs.v does not itself reject an out-of-range n"
    assert depth == 1

    await reset_dut(dut)
    status = await try_descriptor(dut, n=64, d=8, gs=64, mode=bad_mode)
    err, depth = status_fields(status)[2], status_fields(status)[4]
    assert not err, "documented finding: acc_regs.v does not itself reject an unimplemented mode"
    assert depth == 1
    assert int(dut.desc_mode.value) == bad_mode, "the (bad) mode value must pass through unchanged"


async def _check_op_error_latches(dut, err_code, name):
    await start_clock(dut)
    await reset_dut(dut)

    dut.op_error.value = 1
    dut.op_error_code.value = to_bits(err_code, ERR_WIDTH)
    await RisingEdge(dut.clk)
    dut.op_error.value = 0
    await RisingEdge(dut.clk)

    status = await read_status(dut)
    busy, done, err, code, depth = status_fields(status)
    assert err, f"{name}: op_error pulse must set STATUS.ERR"
    assert code == err_code, f"{name}: expected code {err_code}, STATUS reports {code}"
    assert not done, f"{name}: op_error alone must not set DONE"
    assert depth == 0, f"{name}: an externally-reported error must not touch the local queue"


@cocotb.test()
async def test_err_range_is_latched_when_reported_by_upstream_fsm(dut):
    """Reporting-path only -- see SCOPE BOUNDARY. Simulates acc_top telling
    acc_regs.v "this op failed with ACC_ERR_RANGE" and checks the STATUS
    latch, NOT that a real out-of-range n/d produces this in the first
    place (acc_top.v's job)."""
    await _check_op_error_latches(dut, ACC_ERR_RANGE, "ACC_ERR_RANGE")


@cocotb.test()
async def test_err_slot_is_latched_when_reported_by_upstream_fsm(dut):
    """Reporting-path only -- see SCOPE BOUNDARY (same caveat as RANGE)."""
    await _check_op_error_latches(dut, ACC_ERR_SLOT, "ACC_ERR_SLOT")


@cocotb.test()
async def test_err_mode_is_latched_when_reported_by_upstream_fsm(dut):
    """Reporting-path only -- see SCOPE BOUNDARY. This is the code T034
    added after acc_top.v was found to silently run the matmul datapath
    for an unrecognised mode (research note in acc_bits.vh); acc_regs.v's
    half of that fix is simply: does it faithfully latch/report the code
    when told to? Confirmed here. Whether acc_top.v ACTUALLY reports it
    for a bad mode is acc_unit_tb.py's (or a future acc_top suite's) job."""
    await _check_op_error_latches(dut, ACC_ERR_MODE, "ACC_ERR_MODE")


# ---------------------------------------------------------------------------
# Priority: acc_regs.v's comment claims op_error > reject_gs > reject_dim
# > reject_full > push_ok-clears-stale-error. Confirm the first link in
# that chain (op_error beats a simultaneous local reject) actually holds --
# this is the case a caller could otherwise misdiagnose (a real hardware
# fault arriving in the same cycle as an unrelated bad local descriptor
# must not be masked by the local, less-severe reject reason).
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_op_error_takes_priority_over_a_simultaneous_local_reject(dut):
    await start_clock(dut)
    await reset_dut(dut)

    # Stage a locally-invalid (ERR_GS-shaped) descriptor, then present
    # CTRL.START and op_error in the SAME cycle.
    await stage_descriptor(dut, n=60, d=8, gs=5)  # gs=5 -> gs_bad -> would be reject_gs

    dut.sel_idx.value = 1
    dut.sel_dat.value = 0
    dut.wstrb.value = 1
    dut.wdata.value = ACC_REG_CTRL
    await RisingEdge(dut.clk)
    dut.sel_idx.value = 0
    dut.sel_dat.value = 1
    dut.wdata.value = ACC_CTRL_START
    dut.op_error.value = 1
    dut.op_error_code.value = to_bits(ACC_ERR_RANGE, ERR_WIDTH)
    await RisingEdge(dut.clk)
    dut.sel_dat.value = 0
    dut.wstrb.value = 0
    dut.op_error.value = 0
    await RisingEdge(dut.clk)

    status = await read_status(dut)
    err, code = status_fields(status)[2], status_fields(status)[3]
    assert err
    assert code == ACC_ERR_RANGE, (
        f"op_error (ACC_ERR_RANGE) must win over a simultaneous local "
        f"reject_gs (which would report ACC_ERR_GS={ACC_ERR_GS}); got {code}"
    )


# ---------------------------------------------------------------------------
# Sanity check on the non-rejection path this suite otherwise never
# exercises: DONE latches on op_done and clears on a STATUS read (data-
# model.md entity 5's "MUST NOT have side effects other than the
# documented DONE clear"), independent of ERR.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_done_latches_and_clears_on_status_read_without_touching_err(dut):
    await start_clock(dut)
    await reset_dut(dut)

    dut.op_done.value = 1
    await RisingEdge(dut.clk)
    dut.op_done.value = 0
    await RisingEdge(dut.clk)

    status1 = await read_status(dut)
    busy1, done1, err1, code1, depth1 = status_fields(status1)
    assert done1, "STATUS.DONE must latch after an op_done pulse"
    assert not err1

    status2 = await read_status(dut)
    busy2, done2, err2, code2, depth2 = status_fields(status2)
    assert not done2, "a STATUS read must clear DONE"
    assert not err2, "a STATUS read must not touch ERR"


# ---------------------------------------------------------------------------
# CTRL.ABORT -> op_abort pulse (contract: "MUST return the accelerator to
# IDLE from any state within a bounded time" -- acc_regs.v's own half of
# that is just forwarding the request as a clean one-cycle pulse; acc_top
# owns the actual FSM recovery).
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_ctrl_abort_pulses_op_abort_for_one_cycle(dut):
    await start_clock(dut)
    await reset_dut(dut)

    assert dut.op_abort.value == 0
    await reg_write(dut, ACC_REG_CTRL, ACC_CTRL_ABORT)
    # reg_write's own trailing settle edge already advanced one cycle past
    # the write; op_abort is registered (op_abort_r <= abort_req), so it
    # should read 1 exactly at that settle point and 0 one cycle later.
    assert dut.op_abort.value == 1, "op_abort must pulse the cycle after CTRL.ABORT is written"
    await RisingEdge(dut.clk)
    assert dut.op_abort.value == 0, "op_abort must be a one-cycle pulse, not level-held"
