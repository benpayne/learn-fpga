"""
Cocotb testbench for video_line_buffer ping-pong buffer.
Tests:
1. Write 320 words, verify wr_done and swap
2. Read back from display side, verify data
3. Write second line, verify swap gives new data
4. Multiple lines in sequence
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


@cocotb.test()
async def test_write_and_swap(dut):
    """Write 320 words, verify wr_done fires and swap works."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    dut.resetn.value = 0
    dut.wr_data.value = 0
    dut.wr_en.value = 0
    dut.rd_addr.value = 0
    dut.swap.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 5)

    # Write 320 words to line buffer (line 0 data)
    dut._log.info("Writing 320 words (line 0)...")
    for i in range(320):
        dut.wr_data.value = 0xAA000000 | i
        dut.wr_en.value = 1
        await RisingEdge(dut.clk)
    dut.wr_en.value = 0
    await RisingEdge(dut.clk)

    # Check wr_done
    wr_done = int(dut.wr_done.value)
    wr_ready = int(dut.wr_ready.value)
    dut._log.info(f"After 320 writes: wr_done={wr_done}, wr_ready={wr_ready}")
    assert wr_done == 1, "wr_done should be 1 after 320 writes"
    assert wr_ready == 0, "wr_ready should be 0 (buffer full)"

    # Swap (simulating hsync)
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    wr_done2 = int(dut.wr_done.value)
    wr_ready2 = int(dut.wr_ready.value)
    dut._log.info(f"After swap: wr_done={wr_done2}, wr_ready={wr_ready2}")
    assert wr_done2 == 0, "wr_done should be 0 after swap"
    assert wr_ready2 == 1, "wr_ready should be 1 after swap"

    dut._log.info("Write and swap: PASS")


@cocotb.test()
async def test_read_after_swap(dut):
    """Write data, swap, then read from display side."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    dut.resetn.value = 0
    dut.wr_data.value = 0
    dut.wr_en.value = 0
    dut.rd_addr.value = 0
    dut.swap.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 5)

    # Write 320 words
    for i in range(320):
        dut.wr_data.value = 0xBB000000 | i
        dut.wr_en.value = 1
        await RisingEdge(dut.clk)
    dut.wr_en.value = 0

    # Swap so display reads from the written buffer
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    # Read back first 10 words from display side
    errors = 0
    for i in range(10):
        dut.rd_addr.value = i
        await RisingEdge(dut.clk)  # Address registered
        await RisingEdge(dut.clk)  # Data available
        val = int(dut.rd_data.value)
        expected = 0xBB000000 | i
        if val != expected:
            dut._log.info(f"  rd[{i}] = 0x{val:08X}, expected 0x{expected:08X}")
            errors += 1

    # Read last word
    dut.rd_addr.value = 319
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    val = int(dut.rd_data.value)
    expected = 0xBB00013F
    if val != expected:
        dut._log.info(f"  rd[319] = 0x{val:08X}, expected 0x{expected:08X}")
        errors += 1

    dut._log.info(f"Read errors: {errors}")
    assert errors == 0, f"{errors} read errors"
    dut._log.info("Read after swap: PASS")


@cocotb.test()
async def test_two_lines(dut):
    """Write line 0, swap, write line 1, swap, verify display sees line 1."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    dut.resetn.value = 0
    dut.wr_data.value = 0
    dut.wr_en.value = 0
    dut.rd_addr.value = 0
    dut.swap.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 5)

    # Write line 0 (0xAA...)
    for i in range(320):
        dut.wr_data.value = 0xAA000000 | i
        dut.wr_en.value = 1
        await RisingEdge(dut.clk)
    dut.wr_en.value = 0

    # Swap — display now shows line 0
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    # Write line 1 (0xCC...) to the OTHER buffer
    for i in range(320):
        dut.wr_data.value = 0xCC000000 | i
        dut.wr_en.value = 1
        await RisingEdge(dut.clk)
    dut.wr_en.value = 0

    # Swap — display now shows line 1
    dut.swap.value = 1
    await RisingEdge(dut.clk)
    dut.swap.value = 0
    await RisingEdge(dut.clk)

    # Read from display — should see line 1 data (0xCC...)
    dut.rd_addr.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    val = int(dut.rd_data.value)
    dut._log.info(f"After 2 swaps, rd[0] = 0x{val:08X} (expect 0xCC000000)")
    assert val == 0xCC000000, f"Expected line 1 data, got 0x{val:08X}"

    dut.rd_addr.value = 5
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    val = int(dut.rd_data.value)
    dut._log.info(f"rd[5] = 0x{val:08X} (expect 0xCC000005)")
    assert val == 0xCC000005, f"Expected 0xCC000005, got 0x{val:08X}"

    dut._log.info("Two lines: PASS")
