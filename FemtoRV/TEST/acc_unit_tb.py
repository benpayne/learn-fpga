"""
Cocotb integration testbench for the complete int8 MatMul accelerator
(T035/T036): acc_top (acc_regs + acc_weight_fetch + acc_mac + weight FIFO +
scale/activation/result BRAMs) driven against a simulated SDRAM, exactly
the way the real board wires it.

Unlike acc_mac_tb.py (unit-level, drives acc_mac directly with no memory),
this exercises the whole path a real matmul takes: CPU register writes ->
descriptor queue -> SDRAM burst reads of REAL weight bytes from the
project's actual Q8_0 checkpoint -> weight FIFO -> MAC -> result BRAM ->
CPU reads. What can go wrong at THIS level and not at the unit level is
address generation, group/row sequencing under real burst timing, and FIFO
feed-rate -- not MAC arithmetic, which T029-31 already proved bit-exact.

Real matrix shapes, from tools/model.q8.bin (dim=64, hidden_dim=192 --
padded so GS=64 divides every inner dimension, n_layers=5, n_heads=8,
n_kv_heads=4, vocab_size=512, group_size=64, shared_classifier=1):
    wq   (layer 0): n=64,  d=64   ("64x64")
    w1   (layer 0): n=64,  d=192  ("64x192")
    w2   (layer 0): n=192, d=64   ("192x64" -- the R16 incident shape:
                                    hidden_dim is the INNER dimension here)
    wcls (shared with q_tokens): n=64, d=512 (the classifier)

Weight bytes (q and s) are read directly from the real checkpoint file and
loaded into the simulated SDRAM at the SAME byte offsets they occupy in the
file (i.e. SDRAM byte address == file byte offset), computed by
`q8_offsets()` below from a straight transcription of q8_format.h's
documented layout / memory_map_weights() order. This is verified against
the file's actual size (see the module-level self-check).

Activation vectors are SYNTHETIC (random int8 xq, random positive float32
xs) rather than lifted from a real forward pass: reproducing an actual
runq_host forward pass's activation vector bit-for-bit would mean
replicating rmsnorm+embedding lookup here as well, which tests nothing this
suite doesn't already cover, and T029-31 already proved the MAC arithmetic
is input-agnostic-correct (bit-exact for ANY int8 vectors). What matters
here is that the weight bytes streamed through real SDRAM bursts are real
and shape-correct; the activation vector just needs to be a valid Q8_0
vector, which random int8 + a positive float32 scale per group already is.

Reference model: identical to acc_mac_tb.py's (ival = exact int32 dot
product; result = chained round-to-nearest-even float32 multiply; row
values accumulate across groups in ascending address order) -- extended
here to a whole n x d matrix instead of a single group/row.
"""

import os
import random
import struct

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ---------------------------------------------------------------------------
# acc_bits.vh / acc_top.v constants (mirrored here; if these ever drift from
# the RTL, tests should fail loudly rather than silently mis-address).
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

ACC_MODE_MATMUL = 0
ACC_MODE_ATT_SCORE = 1
ACC_MODE_ATT_SUM = 2

# STATUS[7:4] error codes (acc_bits.vh). ERR_DIM/ERR_GS/ERR_FULL are
# acc_regs.v's own job (proven by fw-quant's acc_reject_tb.py, 14/14);
# ERR_RANGE/ERR_SLOT/ERR_MODE are acc_top.v's -- see the
# test_reject_range_*/test_reject_slot_*/test_reject_mode_* tests below,
# which are what this file adds to cover that half of FR-009.
ACC_ERR_NONE = 0
ACC_ERR_DIM = 1
ACC_ERR_GS = 2
ACC_ERR_RANGE = 3
ACC_ERR_SLOT = 4
ACC_ERR_FULL = 5
ACC_ERR_MODE = 6

LANES = 4
NUM_SLOTS = 8
ACT_AWIDTH = 12
RESULT_AWIDTH = 12
ACT_XS_WORDS = 32
ACT_SLOT_WORDS = (1 << ACT_AWIDTH) // NUM_SLOTS      # 512
RESULT_SLOT_WORDS = (1 << RESULT_AWIDTH) // NUM_SLOTS  # 512
ACT_XQ_WORDS = ACT_SLOT_WORDS - ACT_XS_WORDS           # 480
MAX_N = 4096   # acc_top.v parameter default
MAX_D = 4096   # acc_top.v parameter default

MODEL_PATH = os.path.join(
    os.path.dirname(__file__), "..", "FIRMWARE", "llama2", "tools", "model.q8.bin"
)

TIMEOUT_CYCLES = 200_000


# ---------------------------------------------------------------------------
# Q8_0 file layout (q8_format.h, verbatim transcription -- see that file's
# header comment for the authoritative description this mirrors).
# ---------------------------------------------------------------------------

def q8_tensor_bytes(numel, gs):
    return numel + 4 * (numel // gs)


def q8_offsets(dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, gs,
               shared_classifier):
    """Returns a dict of byte offsets (q_offset, s_offset, n, d) for the
    tensors this testbench needs, plus the total file size it predicts (for
    the self-check against the real file)."""
    head_size = dim // n_heads
    off = 256  # header
    off += 4 * n_layers * dim  # rms_att_weight
    off += 4 * n_layers * dim  # rms_ffn_weight
    off += 4 * dim             # rms_final_weight

    tensors = {}

    def take(name, count, numel, n, d):
        nonlocal off
        stride = q8_tensor_bytes(numel, gs)
        tensors[name] = []
        for layer in range(count):
            q_off = off + layer * stride
            s_off = q_off + numel
            tensors[name].append(dict(q=q_off, s=s_off, n=n, d=d, numel=numel))
        off += count * stride

    take("q_tokens", 1, vocab_size * dim, dim, vocab_size)
    take("wq", n_layers, dim * (n_heads * head_size), dim, n_heads * head_size)
    take("wk", n_layers, dim * (n_kv_heads * head_size), dim, n_kv_heads * head_size)
    take("wv", n_layers, dim * (n_kv_heads * head_size), dim, n_kv_heads * head_size)
    take("wo", n_layers, (n_heads * head_size) * dim, n_heads * head_size, dim)
    take("w1", n_layers, dim * hidden_dim, dim, hidden_dim)
    take("w2", n_layers, hidden_dim * dim, hidden_dim, dim)
    take("w3", n_layers, dim * hidden_dim, dim, hidden_dim)
    if not shared_classifier:
        take("wcls", 1, dim * vocab_size, dim, vocab_size)

    return tensors, off


def read_q8_header(path):
    with open(path, "rb") as f:
        hdr = f.read(256)
    magic, version = struct.unpack_from("<II", hdr, 0)
    dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len = \
        struct.unpack_from("<7i", hdr, 8)
    shared_classifier = hdr[36]
    gs = struct.unpack_from("<i", hdr, 37)[0]
    assert magic == 0x616B3432, f"bad Q8_0 magic 0x{magic:08x}"
    assert version == 2, f"unexpected Q8_0 version {version}"
    return dict(dim=dim, hidden_dim=hidden_dim, n_layers=n_layers, n_heads=n_heads,
                n_kv_heads=n_kv_heads, vocab_size=vocab_size, seq_len=seq_len,
                shared_classifier=shared_classifier, gs=gs)


def load_model():
    hdr = read_q8_header(MODEL_PATH)
    tensors, predicted_size = q8_offsets(
        hdr["dim"], hdr["hidden_dim"], hdr["n_layers"], hdr["n_heads"],
        hdr["n_kv_heads"], hdr["vocab_size"], hdr["gs"], hdr["shared_classifier"],
    )
    actual_size = os.path.getsize(MODEL_PATH)
    assert predicted_size == actual_size, (
        f"q8_offsets() predicted {predicted_size} bytes but {MODEL_PATH} is "
        f"{actual_size} bytes -- the offset transcription has drifted from "
        f"q8_format.h's real layout; do not trust the addresses below"
    )
    with open(MODEL_PATH, "rb") as f:
        raw = f.read()
    return hdr, tensors, raw


def read_tensor_qs(raw, tensor_entry, gs):
    """Returns (q: list[int8, len n*d row-major], s: list[float32, len
    d*(n//gs) row-major]) read directly out of the checkpoint bytes."""
    n, d, numel = tensor_entry["n"], tensor_entry["d"], tensor_entry["numel"]
    q_off, s_off = tensor_entry["q"], tensor_entry["s"]
    q_bytes = raw[q_off:q_off + numel]
    q = list(struct.unpack(f"<{numel}b", q_bytes))
    s_count = numel // gs
    s_bytes = raw[s_off:s_off + 4 * s_count]
    s = list(struct.unpack(f"<{s_count}f", s_bytes))
    return q, s


# ---------------------------------------------------------------------------
# SDRAM behavioural model -- identical to sdram_burst_tb.py's, reused
# verbatim (same wrapper signal names: sd_addr/sd_ba/sd_dqm/.../sd_d_in).
# ---------------------------------------------------------------------------

class SDRAMModel:
    def __init__(self):
        self.memory = {}
        self.active_row = [None, None, None, None]
        self.cas_latency = 1

    def write(self, bank, row, col, data, dqm):
        key = (bank, row, col)
        old = self.memory.get(key, 0)
        new = 0
        for i in range(4):
            if dqm & (1 << i):
                new |= (old & (0xFF << (i * 8)))
            else:
                new |= (data & (0xFF << (i * 8)))
        self.memory[key] = new

    def read(self, bank, row, col):
        return self.memory.get((bank, row, col), 0xDEAD0000 | (col & 0xFF))

    def activate(self, bank, row):
        self.active_row[bank] = row

    def precharge(self, bank):
        if bank == -1:
            self.active_row = [None, None, None, None]
        else:
            self.active_row[bank] = None


def addr_to_bank_row_col(byte_addr):
    col = (byte_addr >> 2) & 0xFF
    row = (byte_addr >> 10) & 0x7FF
    bank = (byte_addr >> 21) & 0x3
    return bank, row, col


def preload_sdram(model, raw_bytes):
    """Loads an entire byte blob into the model at SDRAM byte address ==
    blob offset, so file offsets computed by q8_offsets() can be used as
    w_q_base/w_s_base directly with no translation."""
    n_words = len(raw_bytes) // 4
    words = struct.unpack(f"<{n_words}I", raw_bytes[:n_words * 4])
    for i, w in enumerate(words):
        bank, row, col = addr_to_bank_row_col(i * 4)
        model.memory[(bank, row, col)] = w


async def sdram_responder(dut, model):
    CMD_READ = 0b0101
    CMD_WRITE = 0b0100
    CMD_ACTIVE = 0b0011
    CMD_PRECHARGE = 0b0010

    read_pipe = []
    dut.sd_d_in.value = 0

    while True:
        await RisingEdge(dut.clk)
        try:
            cmd = ((int(dut.sd_cs.value) << 3) |
                   (int(dut.sd_ras.value) << 2) |
                   (int(dut.sd_cas.value) << 1) |
                   int(dut.sd_we.value))
            bank = int(dut.sd_ba.value)
            addr = int(dut.sd_addr.value)
        except (ValueError, AttributeError):
            continue

        if cmd == CMD_ACTIVE:
            model.activate(bank, addr & 0x7FF)
        elif cmd == CMD_READ:
            col = addr & 0xFF
            row = model.active_row[bank]
            if row is not None:
                read_pipe.append((model.cas_latency, model.read(bank, row, col)))
        elif cmd == CMD_WRITE:
            col = addr & 0xFF
            row = model.active_row[bank]
            try:
                dqm = int(dut.sd_dqm.value)
                data = int(dut.sd_d_out.value)
            except (ValueError, AttributeError):
                dqm, data = 0xF, 0
            if row is not None:
                model.write(bank, row, col, data, dqm)
        elif cmd == CMD_PRECHARGE:
            model.precharge(-1 if (addr & 0x400) else bank)

        new_pipe = []
        drive_data = 0
        for delay, data in read_pipe:
            if delay <= 1:
                drive_data = data
            else:
                new_pipe.append((delay - 1, data))
        read_pipe = new_pipe
        dut.sd_d_in.value = drive_data


# ---------------------------------------------------------------------------
# Bit-level / reference-model helpers (shared logic with acc_mac_tb.py)
# ---------------------------------------------------------------------------

def to_bits(v, width):
    return v & ((1 << width) - 1)


def pack_lanes(vals, elem_width=8):
    packed = 0
    for i, v in enumerate(vals):
        packed |= to_bits(v, elem_width) << (i * elem_width)
    return packed


def f32_to_bits(x):
    return int(np.float32(x).view(np.uint32))


def bits_to_f32(bits):
    return np.uint32(bits & 0xFFFFFFFF).view(np.float32)


def ref_rescale(ival, w_scale, x_scale):
    f = np.float32(ival)
    f = np.float32(f) * np.float32(w_scale)
    f = np.float32(f) * np.float32(x_scale)
    return np.float32(f)


def ref_row_add(a, b):
    return np.float32(np.float32(a) + np.float32(b))


def ref_matmul_row(w_q, w_s, n, gs, xq, xs, row):
    """Row `row`'s expected fp32 output, using w_q/w_s row-major arrays for
    the FULL matrix (n*d elements / d*(n/gs) scales) -- exactly the runq.c
    arithmetic, exactly as validated bit-exact in acc_mac_tb.py."""
    groups = n // gs
    val = np.float32(0.0)
    for g in range(groups):
        w_slice = w_q[row * n + g * gs: row * n + g * gs + gs]
        x_slice = xq[g * gs: g * gs + gs]
        ival = sum(int(a) * int(b) for a, b in zip(w_slice, x_slice))
        w_scale = w_s[row * groups + g]
        x_scale = xs[g]
        contrib = ref_rescale(ival, w_scale, x_scale)
        val = contrib if g == 0 else ref_row_add(val, contrib)
    return val


def rand_int8(rng):
    return rng.randint(-128, 127)


# ---------------------------------------------------------------------------
# DUT drivers
# ---------------------------------------------------------------------------

async def start_clock(dut):
    clock = Clock(dut.clk, 40, unit="ns")  # 25 MHz
    cocotb.start_soon(clock.start())


async def reset_dut(dut):
    dut.resetn.value = 0
    dut.io_wdata.value = 0
    dut.io_wstrb.value = 0
    dut.io_rstrb.value = 0
    dut.io_sel_idx.value = 0
    dut.io_sel_dat.value = 0
    dut.res_sel.value = 0
    dut.res_rstrb.value = 0
    dut.res_addr.value = 0
    dut.act_sel.value = 0
    dut.act_wmask.value = 0
    dut.act_addr.value = 0
    dut.act_wdata.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 12000)  # SDRAM init, same margin sdram_burst_tb.py uses


async def reg_write(dut, idx, val):
    dut.io_sel_idx.value = 1
    dut.io_sel_dat.value = 0
    dut.io_wstrb.value = 1
    dut.io_wdata.value = idx
    await RisingEdge(dut.clk)
    dut.io_sel_idx.value = 0
    dut.io_sel_dat.value = 1
    dut.io_wdata.value = to_bits(val, 32)
    await RisingEdge(dut.clk)
    dut.io_sel_dat.value = 0
    dut.io_wstrb.value = 0


async def reg_set_index(dut, idx):
    dut.io_sel_idx.value = 1
    dut.io_wstrb.value = 1
    dut.io_wdata.value = idx
    await RisingEdge(dut.clk)
    dut.io_sel_idx.value = 0
    dut.io_wstrb.value = 0


async def reg_read_selected(dut):
    dut.io_sel_dat.value = 1
    dut.io_rstrb.value = 1
    await RisingEdge(dut.clk)
    val = int(dut.io_rdata.value)
    dut.io_sel_dat.value = 0
    dut.io_rstrb.value = 0
    return val


async def act_write(dut, slot, xq, xs):
    n = len(xq)
    assert n % LANES == 0
    base = slot * ACT_SLOT_WORDS
    for i in range(n // LANES):
        dut.act_sel.value = 1
        dut.act_wmask.value = 0xF
        dut.act_addr.value = base + i
        dut.act_wdata.value = pack_lanes(xq[i * LANES:(i + 1) * LANES])
        await RisingEdge(dut.clk)
    for g, scale in enumerate(xs):
        dut.act_sel.value = 1
        dut.act_wmask.value = 0xF
        dut.act_addr.value = base + ACT_XQ_WORDS + g
        dut.act_wdata.value = f32_to_bits(scale)
        await RisingEdge(dut.clk)
    dut.act_sel.value = 0
    dut.act_wmask.value = 0


async def result_read_row(dut, slot, i):
    """acc_top's res_rdata is a registered (synchronous BRAM) read -- one
    clock's worth of latency from res_sel&&res_rstrb to a valid res_rdata,
    per the module's own header comment. Empirically (see T035/T036
    debugging) that latency needs to be measured from ONE EDGE AFTER
    res_sel/res_rstrb are presented here, not from the edge immediately
    following presentation -- i.e. two RisingEdges total, the same
    off-by-one this project has now hit more than once with values set via
    cocotb's `.value =` just before an `await RisingEdge`. Confirmed with a
    direct probe: res_rdata reads X after one edge and the correct
    result_mem[addr] value after two."""
    dut.res_sel.value = 0
    dut.res_rstrb.value = 0
    await RisingEdge(dut.clk)
    dut.res_sel.value = 1
    dut.res_rstrb.value = 1
    dut.res_addr.value = slot * RESULT_SLOT_WORDS + i
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    val = bits_to_f32(int(dut.res_rdata.value))
    dut.res_sel.value = 0
    dut.res_rstrb.value = 0
    return val


async def issue_matmul(dut, w_q_base, w_s_base, x_slot, out_slot, n, d, gs, mode=ACC_MODE_MATMUL):
    await reg_write(dut, ACC_REG_W_Q_BASE, w_q_base)
    await reg_write(dut, ACC_REG_W_S_BASE, w_s_base)
    await reg_write(dut, ACC_REG_X_SLOT, x_slot)
    await reg_write(dut, ACC_REG_OUT_SLOT, out_slot)
    await reg_write(dut, ACC_REG_N, n)
    await reg_write(dut, ACC_REG_D, d)
    await reg_write(dut, ACC_REG_GS, gs)
    await reg_write(dut, ACC_REG_MODE, mode)
    await reg_write(dut, ACC_REG_CTRL, ACC_CTRL_START)


async def wait_done(dut, timeout=TIMEOUT_CYCLES):
    """Poll STATUS until the operation has genuinely finished.

    BUSY (status bit 0) is an unlatched passthrough of acc_top's op_busy_r
    register -- it reads 0 the very cycle the FSM leaves S_RUNNING. DONE
    (bit 1) is acc_top's one-cycle op_done PULSE, captured into acc_regs'
    done_latched register -- that capture happens on acc_regs' OWN next
    clock edge, one cycle after op_busy_r has already dropped. A poll that
    stops on "not busy" alone can therefore land in the one-cycle window
    where BUSY already reads 0 but DONE has not latched yet, and would
    wrongly report "finished with neither DONE nor ERR set". Require DONE
    or ERR as well -- both are genuinely latched (stay set until read/
    overwritten), so there is no equivalent race the other way.
    """
    await reg_set_index(dut, ACC_REG_STATUS)
    for _ in range(timeout):
        status = await reg_read_selected(dut)
        if not (status & ACC_STATUS_BUSY) and (status & (ACC_STATUS_DONE | ACC_STATUS_ERR)):
            return status
    raise TimeoutError("accelerator never reached a settled DONE/ERR state")


async def read_perf(dut):
    await reg_set_index(dut, ACC_REG_PERF_CYC)
    cycles = await reg_read_selected(dut)
    await reg_set_index(dut, ACC_REG_PERF_STALL)
    stall = await reg_read_selected(dut)
    return cycles, stall


# ---------------------------------------------------------------------------
# One shape, end to end: real weight bytes from the checkpoint, synthetic
# activation, full SDRAM round trip, bit-exact result check.
# ---------------------------------------------------------------------------

async def run_matmul_case(dut, model, hdr, raw, tensor_entry, label, seed):
    gs = hdr["gs"]
    n, d = tensor_entry["n"], tensor_entry["d"]
    assert n % gs == 0, f"{label}: n={n} not a multiple of gs={gs}"

    w_q, w_s = read_tensor_qs(raw, tensor_entry, gs)
    assert len(w_q) == n * d
    assert len(w_s) == d * (n // gs)

    rng = random.Random(seed)
    xq = [rand_int8(rng) for _ in range(n)]
    xs = [np.float32(rng.uniform(1e-4, 4.0)) for _ in range(n // gs)]

    await act_write(dut, slot=0, xq=xq, xs=xs)
    await issue_matmul(dut, w_q_base=tensor_entry["q"], w_s_base=tensor_entry["s"],
                        x_slot=0, out_slot=0, n=n, d=d, gs=gs)
    status = await wait_done(dut)
    assert not (status & ACC_STATUS_ERR), f"{label}: ERR bit set, status=0x{status:08x}"
    assert status & ACC_STATUS_DONE, f"{label}: DONE bit not set, status=0x{status:08x}"

    cycles, stall = await read_perf(dut)
    q_words_total = (n * d) // LANES
    rate = q_words_total / cycles if cycles else 0.0
    dut._log.info(
        f"{label}: n={n} d={d} gs={gs} q_words={q_words_total} "
        f"PERF_CYCLES={cycles} PERF_STALL={stall} "
        f"stall_frac={stall/cycles:.3f} achieved={rate:.3f} words/cycle"
    )
    # Sanity, not a re-litigation of the arbitration sweep's SC-006 number:
    # a healthy single-descriptor, no-contention run should not spend most
    # of its time stalled. A high fraction here would mean the FIFO isn't
    # being kept fed, which is exactly the failure mode T036 asks to rule
    # out.
    assert stall < cycles, f"{label}: PERF_STALL ({stall}) >= PERF_CYCLES ({cycles})"
    assert (stall / cycles) < 0.5, f"{label}: stalled {stall}/{cycles} cycles -- FIFO starved"

    mismatches = 0
    for i in range(d):
        got = await result_read_row(dut, slot=0, i=i)
        exp = ref_matmul_row(w_q, w_s, n, gs, xq, xs, i)
        if f32_to_bits(got) != f32_to_bits(exp):
            mismatches += 1
            dut._log.error(
                f"{label}: row {i} mismatch: got 0x{f32_to_bits(got):08x} "
                f"({float(got)}) expected 0x{f32_to_bits(exp):08x} ({float(exp)})"
            )
    assert mismatches == 0, f"{label}: {mismatches}/{d} rows mismatched"
    dut._log.info(f"{label}: all {d} rows bit-identical to the reference model")
    return cycles, stall


@cocotb.test()
async def test_wq_64x64(dut):
    """wq, layer 0: n=64, d=64."""
    await start_clock(dut)
    hdr, tensors, raw = load_model()
    model = SDRAMModel()
    preload_sdram(model, raw)
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await run_matmul_case(dut, model, hdr, raw, tensors["wq"][0], "wq[layer0] 64x64", seed=100)


@cocotb.test()
async def test_w1_64x192(dut):
    """w1, layer 0: n=64, d=192 (hidden_dim padded so gs=64 divides it)."""
    await start_clock(dut)
    hdr, tensors, raw = load_model()
    model = SDRAMModel()
    preload_sdram(model, raw)
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await run_matmul_case(dut, model, hdr, raw, tensors["w1"][0], "w1[layer0] 64x192", seed=101)


@cocotb.test()
async def test_w2_192x64(dut):
    """w2, layer 0: n=192, d=64 -- hidden_dim is the INNER dimension here,
    the shape whose (pre-padding) n%gs!=0 caused the research R16 incident.
    Now n=192 is an exact multiple of gs=64 (3 groups/row)."""
    await start_clock(dut)
    hdr, tensors, raw = load_model()
    model = SDRAMModel()
    preload_sdram(model, raw)
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await run_matmul_case(dut, model, hdr, raw, tensors["w2"][0], "w2[layer0] 192x64", seed=102)


@cocotb.test()
async def test_classifier_64x512(dut):
    """The classifier: shared_classifier=1, so it reuses q_tokens (n=dim=64,
    d=vocab_size=512 -- exactly at RESULT_SLOT_WORDS's boundary)."""
    await start_clock(dut)
    hdr, tensors, raw = load_model()
    assert hdr["shared_classifier"] == 1, "model.q8.bin no longer shares the classifier"
    model = SDRAMModel()
    preload_sdram(model, raw)
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await run_matmul_case(dut, model, hdr, raw, tensors["q_tokens"][0], "wcls(=q_tokens) 64x512", seed=103)


@cocotb.test()
async def test_row_interleave_no_gap(dut):
    """Constructs a case that stresses the contract acc_mac.v documents but
    does not enforce in hardware: acc_top must not interleave a second
    row's groups into acc_mac before the first row's last row_valid. With
    gs == LANES == 4, every group is exactly ONE address-phase cycle wide,
    so a 2-row matrix has its row boundary crossed with zero cycles of
    slack -- the tightest case the architecture allows (gs cannot go below
    ACC_GS_MIN=4). If acc_top's continuous, uninterrupted address-phase
    streaming ever mixed one row's rescaled contribution into another's
    row accumulator, this is where it would show up as a bit-exact
    mismatch.

    Uses small synthetic (non-file) weight data placed in an unused SDRAM
    region, purely to keep this test fast and its expected values easy to
    reason about -- correctness of REAL weight streaming is already
    covered by the four shape tests above.
    """
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)

    gs = 4
    n, d = 8, 4  # 2 groups/row, 4 rows -- back-to-back row boundaries at 1-cycle gs

    rng = random.Random(999)
    w_q = [rand_int8(rng) for _ in range(n * d)]
    w_s = [np.float32(rng.uniform(1e-3, 2.0)) for _ in range(d * (n // gs))]
    xq = [rand_int8(rng) for _ in range(n)]
    xs = [np.float32(rng.uniform(1e-3, 2.0)) for _ in range(n // gs)]

    # Place weight q/s at arbitrary (but word-aligned) SDRAM addresses --
    # preload_sdram() assumes blob offset 0 == SDRAM address 0, so for a
    # non-zero base write directly into the model instead.
    w_q_base = 0x400000
    w_s_base = 0x500000
    q_bytes = struct.pack(f"<{len(w_q)}b", *w_q)
    s_bytes = struct.pack(f"<{len(w_s)}f", *w_s)
    for i in range(len(q_bytes) // 4):
        word = struct.unpack_from("<I", q_bytes, i * 4)[0]
        bank, row, col = addr_to_bank_row_col(w_q_base + i * 4)
        model.memory[(bank, row, col)] = word
    for i in range(len(s_bytes) // 4):
        word = struct.unpack_from("<I", s_bytes, i * 4)[0]
        bank, row, col = addr_to_bank_row_col(w_s_base + i * 4)
        model.memory[(bank, row, col)] = word

    await act_write(dut, slot=0, xq=xq, xs=xs)
    await issue_matmul(dut, w_q_base=w_q_base, w_s_base=w_s_base,
                        x_slot=0, out_slot=0, n=n, d=d, gs=gs)
    status = await wait_done(dut)
    assert not (status & ACC_STATUS_ERR), f"row-interleave case: ERR bit set, status=0x{status:08x}"
    assert status & ACC_STATUS_DONE

    mismatches = 0
    for i in range(d):
        got = await result_read_row(dut, slot=0, i=i)
        exp = ref_matmul_row(w_q, w_s, n, gs, xq, xs, i)
        if f32_to_bits(got) != f32_to_bits(exp):
            mismatches += 1
            dut._log.error(
                f"row-interleave case: row {i} mismatch: got 0x{f32_to_bits(got):08x} "
                f"expected 0x{f32_to_bits(exp):08x}"
            )
    assert mismatches == 0, (
        f"row-interleave case: {mismatches}/{d} rows mismatched -- acc_top interleaved "
        f"rows into acc_mac's row accumulator faster than the pipeline could drain them"
    )
    dut._log.info(f"row-interleave case (gs=LANES=4, zero-slack row boundaries): all {d} rows correct")



# ---------------------------------------------------------------------------
# acc_top.v-level descriptor rejection (T038 follow-up).
#
# fw-quant's acc_reject_tb.py proves acc_regs.v's side of FR-009: it computes
# ERR_DIM, ERR_GS and ERR_FULL at enqueue time and nothing else -- `push_ok`
# does not look at n/d against MAX_N/MAX_D, slot indices, result-slot
# capacity, or mode. Demonstrated directly there: descriptors with
# n=8192 (2x MAX_N), d=65535, or mode=3 are all pushed into the queue with
# no error raised at that layer. ERR_RANGE, ERR_SLOT and ERR_MODE are
# entirely acc_top.v's job (`accept_range_bad`/`accept_slot_bad`/
# `accept_mode_bad` in the S_IDLE branch), and until now none of the three
# had ever been exercised end to end -- FR-009's "a rejected descriptor
# MUST NOT start" is a property of the acc_regs+acc_top PAIR, not of either
# module alone, and only acc_top's half was untested.
#
# ERR_MODE matters most: acc_top decoded only ACC_MODE_MATMUL and let every
# other mode value fall through before this check existed, so a descriptor
# issued for a mode nothing implements yet would have silently run the
# matmul datapath and returned a confident, wrong answer -- the same failure
# shape as the R16 (runq.c silent truncation) and the scale-timing bug this
# same file's other tests just caught. An untested guard against a third
# instance of that failure class is not worth much, hence testing it
# explicitly against the two REAL not-yet-implemented modes (ACC_MODE_ATT_
# SCORE, ACC_MODE_ATT_SUM) rather than only an arbitrary undefined value --
# those two are what a driver could plausibly issue by mistake today, and
# they are the ones that will flip from "rejected" to "valid" once T064
# lands, which is exactly the day a regression here would need to catch.
# ---------------------------------------------------------------------------

async def assert_rejected(dut, label, expected_code, **matmul_kwargs):
    """Issue a descriptor expected to be rejected by acc_top.v's accept-time
    checks and confirm: it settles with ERR set and the RIGHT code, DONE is
    NOT set (rejection and completion are mutually exclusive), BUSY is
    clear, and -- the actual proof the operation never started, not just
    that an error bit happened to be set -- PERF_CYCLES stays at 0, since
    op_perf_cycles_r only increments once S_RUNNING is entered, which a
    rejected descriptor never reaches."""
    await issue_matmul(dut, **matmul_kwargs)
    status = await wait_done(dut)
    assert status & ACC_STATUS_ERR, f"{label}: ERR bit not set, status=0x{status:08x}"
    assert not (status & ACC_STATUS_DONE), f"{label}: DONE set on a rejected descriptor, status=0x{status:08x}"
    assert not (status & ACC_STATUS_BUSY), f"{label}: BUSY set after rejection settled, status=0x{status:08x}"
    got_code = (status >> 4) & 0xF
    assert got_code == expected_code, (
        f"{label}: error code {got_code} != expected {expected_code}, status=0x{status:08x}"
    )
    cycles, _ = await read_perf(dut)
    assert cycles == 0, (
        f"{label}: PERF_CYCLES={cycles}, expected 0 -- the operation actually entered "
        f"S_RUNNING despite being rejected"
    )
    dut._log.info(f"{label}: correctly rejected with code {got_code}, never started (PERF_CYCLES=0)")


@cocotb.test()
async def test_reject_range_n(dut):
    """n=8192 is twice MAX_N (4096) -- fw-quant's own acc_reject_tb.py
    example of a descriptor acc_regs.v pushes with no error. gs=64 keeps
    n%gs==0 so acc_regs' own ERR_DIM/ERR_GS checks pass cleanly; this must
    be caught by acc_top's accept_range_bad instead. (n this large also
    exceeds the activation buffer's xq capacity, tripping accept_slot_bad
    too -- accept_mode_bad > accept_range_bad > accept_slot_bad priority in
    acc_top.v's S_IDLE branch means ERR_RANGE is still what must come out,
    and that priority ordering under real overlap is exactly what this
    case verifies.)"""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "n=8192 (2x MAX_N)", ACC_ERR_RANGE,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=0, n=8192, d=1, gs=64,
    )


@cocotb.test()
async def test_reject_range_d(dut):
    """d=65535 (max 16-bit value, >> MAX_D=4096) -- fw-quant's other
    acc_reject_tb.py example. n=64/gs=64 keeps every acc_regs-level check
    clean, isolating this to acc_top's accept_range_bad."""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "d=65535 (>> MAX_D)", ACC_ERR_RANGE,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=0, n=64, d=65535, gs=64,
    )


@cocotb.test()
async def test_reject_slot_d_overflow(dut):
    """d=1000 is within MAX_D (4096) -- accept_range_bad does NOT fire --
    but exceeds RESULT_SLOT_WORDS (512), the actual physical capacity of
    one result-BRAM slot. This is the case accept_range_bad structurally
    cannot catch (it only knows the configured maxima, not the BRAM this
    module actually built) and is exactly why acc_top.v's own header
    distinguishes ERR_RANGE from ERR_SLOT as two different validation
    layers rather than one. Isolated from ERR_RANGE by construction:
    d=1000 <= MAX_D=4096."""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "d=1000 (> RESULT_SLOT_WORDS=512, <= MAX_D)", ACC_ERR_SLOT,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=0, n=64, d=1000, gs=64,
    )


@cocotb.test()
async def test_reject_slot_bad_index(dut):
    """out_slot=8 is one past the last valid slot (0..NUM_SLOTS-1=7) --
    the other way accept_slot_bad can fire, independent of d entirely."""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "out_slot=8 (>= NUM_SLOTS)", ACC_ERR_SLOT,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=8, n=64, d=1, gs=64,
    )


@cocotb.test()
async def test_reject_mode_att_score(dut):
    """MODE_ATT_SCORE (1): a real, named mode this hardware does not
    implement yet (T064/US6). This is the case the team lead most wants
    covered -- a plausible mistake a driver could actually make, not just
    an arbitrary invalid encoding."""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "mode=ACC_MODE_ATT_SCORE", ACC_ERR_MODE,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=0, n=64, d=1, gs=64,
        mode=ACC_MODE_ATT_SCORE,
    )


@cocotb.test()
async def test_reject_mode_att_sum(dut):
    """MODE_ATT_SUM (2): the other real not-yet-implemented mode. Tested
    separately from ATT_SCORE since both are named, plausible-to-issue
    values, not aliases of the same failure."""
    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)
    await assert_rejected(
        dut, "mode=ACC_MODE_ATT_SUM", ACC_ERR_MODE,
        w_q_base=0, w_s_base=0, x_slot=0, out_slot=0, n=64, d=1, gs=64,
        mode=ACC_MODE_ATT_SUM,
    )
