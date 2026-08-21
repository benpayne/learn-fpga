"""
Cocotb harness that replays a VALIDATED serial capture of acc_test.c's
dump_test_vector() output (see acc_dump_replay.py) through the real
acc_top/acc_mac RTL, so a hardware transcript can be reproduced in
simulation from GROUND TRUTH -- the board's actual resident
g_xq/g_xs/g_wq/g_ws bytes -- rather than a host reconstruction that can
silently diverge (research R40/R41: a reconstruction that "looked right
and wasn't" is exactly what cost this feature four transcripts' worth of
comparison time).

This module owns the RECEIVING half of that fix. fw-quant owns the
PRODUCING half (acc_test.c's gen_test_vector()/dump_test_vector(),
integer-deterministic per R41's finding that float-computed test data in
the same translation unit as the checker is not safely comparable across
builds). Coordinate any wire-format change with them -- acc_dump_replay.py's
FORMAT_VERSION is the single source of truth this file and acc_test.c must
agree on.

Which dump gets replayed is controlled by the ACC_DUMP_PATH environment
variable; it defaults to the synthetic fixture
(acc_dump_fixtures/synthetic_v1.txt) so this test is runnable (and useful
as a parser/harness regression check) before any real board capture
exists -- see that fixture's own header for why a pass against it is NOT
hardware verification. Point ACC_DUMP_PATH at a real captured transcript
to actually close the R35/R39/R40/R41 loop.

Unlike acc_r27_gs16_data.py (R40's reconstruction, now understood per R41
to have been replaying similar-but-not-identical input), every byte this
module feeds to the DUT comes from acc_dump_replay.parse_dump()'s
CHECKSUM-VALIDATED output -- there is no regeneration step here at all.
"""

import os
import struct

import cocotb

from acc_dump_replay import load_dump, AccDumpError
from acc_unit_tb import (
    start_clock, reset_dut, act_write, issue_matmul, wait_done, result_read_row,
    ref_matmul_row, addr_to_bank_row_col, SDRAMModel, sdram_responder,
    bits_to_f32, f32_to_bits, ACC_STATUS_ERR, ACC_STATUS_DONE,
)

DUMP_PATH_ENV = "ACC_DUMP_PATH"
DEFAULT_DUMP_PATH = os.path.join(
    os.path.dirname(__file__), "acc_dump_fixtures", "synthetic_v1.txt"
)


@cocotb.test()
async def test_replay_from_dump(dut):
    """Loads and validates a dump (ACC_DUMP_PATH, default: the synthetic
    fixture), replays its EXACT captured bytes through the real acc_top/
    acc_mac via the same synthetic-SDRAM-injection pattern
    acc_unit_tb.py's _row_interleave_case/test_r27_gs16_replay already
    established, and checks the result bit-exact against the strict
    reference computed from those SAME captured bytes -- no regenerated
    data anywhere in this test. A parse/validation failure (bad checksum,
    truncated section, wrong format version) raises AccDumpError and this
    test fails loudly, on purpose: an unchecksummed or corrupted capture
    must never be silently treated as ground truth."""
    dump_path = os.environ.get(DUMP_PATH_ENV, DEFAULT_DUMP_PATH)
    dut._log.info(f"loading dump: {dump_path}")
    try:
        dump = load_dump(dump_path)
    except (AccDumpError, OSError) as e:
        raise AssertionError(
            f"refusing to replay {dump_path}: {e}"
        ) from e

    dut._log.info(
        f"dump validated: seed=0x{dump.seed:08x} n={dump.n} d={dump.d} gs={dump.gs} "
        f"(checksum 0x{dump.checksum:08x} confirmed over {len(dump.raw_bytes())} raw bytes)"
    )

    xs = [bits_to_f32(b) for b in dump.xs_bits]
    ws = [bits_to_f32(b) for b in dump.ws_bits]

    await start_clock(dut)
    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))
    await reset_dut(dut)

    # Synthetic SDRAM placement -- same pattern as _row_interleave_case /
    # test_r27_gs16_replay in acc_unit_tb.py. The weight tensor is the
    # captured dump.wq/ws; there is no file/model backing it, matching
    # acc_test.c's own standalone (no SD card) weight tensor.
    w_q_base = 0x400000
    w_s_base = 0x500000
    q_bytes = struct.pack(f"<{len(dump.wq)}b", *dump.wq)
    s_bytes = struct.pack(f"<{len(ws)}f", *ws)
    for i in range(len(q_bytes) // 4):
        word = struct.unpack_from("<I", q_bytes, i * 4)[0]
        bank, row, col = addr_to_bank_row_col(w_q_base + i * 4)
        model.memory[(bank, row, col)] = word
    for i in range(len(s_bytes) // 4):
        word = struct.unpack_from("<I", s_bytes, i * 4)[0]
        bank, row, col = addr_to_bank_row_col(w_s_base + i * 4)
        model.memory[(bank, row, col)] = word

    await act_write(dut, slot=0, xq=dump.xq, xs=xs)
    await issue_matmul(dut, w_q_base=w_q_base, w_s_base=w_s_base,
                        x_slot=0, out_slot=0, n=dump.n, d=dump.d, gs=dump.gs)
    status = await wait_done(dut)
    assert not (status & ACC_STATUS_ERR), f"ERR bit set, status=0x{status:08x}"
    assert status & ACC_STATUS_DONE, f"DONE bit not set, status=0x{status:08x}"

    mismatches = 0
    for i in range(dump.d):
        got = await result_read_row(dut, slot=0, i=i)
        got_bits = f32_to_bits(got)
        exp = ref_matmul_row(dump.wq, ws, dump.n, dump.gs, dump.xq, xs, i)
        exp_bits = f32_to_bits(exp)
        status_str = "MATCH" if got_bits == exp_bits else "MISMATCH"
        if got_bits != exp_bits:
            mismatches += 1
            dut._log.error(f"row {i}: RTL 0x{got_bits:08x} != strict reference 0x{exp_bits:08x}")
        dut._log.info(f"row {i}: RTL=0x{got_bits:08x} strict_ref=0x{exp_bits:08x} {status_str}")

    dut._log.info(
        f"test_replay_from_dump: {dump.d - mismatches}/{dump.d} rows bit-exact against "
        f"the strict reference, replaying captured (not regenerated) input from {dump_path}"
    )
    assert mismatches == 0, (
        f"{mismatches}/{dump.d} rows disagree with the strict reference against CAPTURED "
        f"input -- unlike acc_r27_gs16_data.py's reconstruction (R40/R41), there is no "
        f"regeneration step to blame here; this would be a real RTL defect."
    )
