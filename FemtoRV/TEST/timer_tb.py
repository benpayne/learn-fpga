# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.clock import Clock

SYS_CLK_NS = 40  # 25 MHz


async def write_timer(dut, value):
    """Write a value to the timer."""
    dut.sel.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = value
    await Timer(SYS_CLK_NS, unit="ns")
    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.wdata.value = 0
    await Timer(SYS_CLK_NS, unit="ns")


async def read_timer(dut):
    """Read the timer counter value."""
    dut.sel.value = 1
    dut.rstrb.value = 1
    await Timer(SYS_CLK_NS, unit="ns")
    val = dut.rdata.value.to_unsigned()
    dut.sel.value = 0
    dut.rstrb.value = 0
    return val


@cocotb.test()
async def timer_basic(dut):
    """Test basic timer countdown and completion."""
    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.wdata.value = 0
    await Timer(200, unit="ns")

    # Timer should not be running initially
    assert dut.running.value == 0, "timer should not be running initially"
    assert dut.complete.value == 0, "timer should not be complete initially"

    # Start timer with count of 10
    await write_timer(dut, 10)

    assert dut.running.value == 1, "timer should be running after write"

    # Wait for completion pulse (complete is a single-cycle pulse)
    await RisingEdge(dut.complete)
    # Let signals settle
    await Timer(1, unit="ns")

    # Complete should be high right now, running should be low
    assert dut.complete.value == 1, "complete should be high on rising edge"
    assert dut.running.value == 0, "timer should stop on completion"

    # After one clock, complete should auto-clear
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert dut.complete.value == 0, "complete should auto-clear after one cycle"


@cocotb.test()
async def timer_write_zero_stops(dut):
    """Test that writing 0 does NOT start the timer (bug fix)."""
    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.wdata.value = 0
    await Timer(200, unit="ns")

    # Write 0 - should NOT start timer (was a bug: instant completion)
    await write_timer(dut, 0)

    await Timer(SYS_CLK_NS * 5, unit="ns")

    assert dut.running.value == 0, "writing 0 should not start timer"
    assert dut.complete.value == 0, "writing 0 should not trigger completion"


@cocotb.test()
async def timer_read_counter(dut):
    """Test reading the counter value while running."""
    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.wdata.value = 0
    await Timer(200, unit="ns")

    # Start timer with large value
    await write_timer(dut, 1000)

    # Wait a few cycles and read counter
    await Timer(SYS_CLK_NS * 5, unit="ns")

    val = await read_timer(dut)
    assert val > 0, "counter should be incrementing"
    assert val < 1000, "counter should not have reached target yet"
    assert dut.running.value == 1, "timer should still be running"


@cocotb.test()
async def timer_restart(dut):
    """Test restarting the timer with a new value."""
    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.wdata.value = 0
    await Timer(200, unit="ns")

    # Start with 10
    await write_timer(dut, 10)
    await Timer(SYS_CLK_NS * 5, unit="ns")

    # Restart with 20 before completion
    await write_timer(dut, 20)

    # Counter should have been reset
    val = await read_timer(dut)
    assert val < 10, "counter should have reset on restart"
    assert dut.running.value == 1, "timer should be running"
