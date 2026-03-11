# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.clock import Clock

SYS_CLK_NS = 40  # 25 MHz


@cocotb.test()
async def ic_test_basic(dut):
    """Test basic interrupt detection, status read, and clear."""

    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.rst.value = 0  # Assert active-low reset
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.wdata.value = 0
    dut.interrupts.value = 0

    await Timer(200, unit="ns")
    dut.rst.value = 1  # Release reset
    await Timer(200, unit="ns")

    # Pulse interrupt on bit 0
    dut.interrupts.value = 1
    await Timer(SYS_CLK_NS * 3, unit="ns")
    dut.interrupts.value = 0

    # interrupt_request should pulse (edge-triggered)
    await Timer(SYS_CLK_NS * 2, unit="ns")

    # Read status register - bit 0 should be latched
    dut.sel.value = 1
    dut.rstrb.value = 1
    await Timer(SYS_CLK_NS, unit="ns")
    status = dut.rdata.value.to_unsigned()
    dut.sel.value = 0
    dut.rstrb.value = 0

    assert status & 1 == 1, f"interrupt bit 0 should be latched, got 0x{status:08X}"

    # Clear bit 0 by writing 1
    dut.sel.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = 1
    await Timer(SYS_CLK_NS * 2, unit="ns")
    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.wdata.value = 0
    await Timer(SYS_CLK_NS * 2, unit="ns")

    assert dut.interrupt_status.value == 0, "interrupt bit should be cleared"


@cocotb.test()
async def ic_test_multiple_sources(dut):
    """Test multiple interrupt sources firing independently."""

    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.rst.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.wdata.value = 0
    dut.interrupts.value = 0

    await Timer(200, unit="ns")
    dut.rst.value = 1
    await Timer(200, unit="ns")

    # Fire interrupt on bit 0 (timer)
    dut.interrupts.value = 0x01
    await Timer(SYS_CLK_NS * 3, unit="ns")
    dut.interrupts.value = 0
    await Timer(SYS_CLK_NS * 3, unit="ns")

    # Fire interrupt on bit 1 (PS2)
    dut.interrupts.value = 0x02
    await Timer(SYS_CLK_NS * 3, unit="ns")
    dut.interrupts.value = 0
    await Timer(SYS_CLK_NS * 3, unit="ns")

    # Both bits should be set in status
    dut.sel.value = 1
    dut.rstrb.value = 1
    await Timer(SYS_CLK_NS, unit="ns")
    status = dut.rdata.value.to_unsigned()
    dut.sel.value = 0
    dut.rstrb.value = 0

    assert status & 0x03 == 0x03, f"both bits 0,1 should be set, got 0x{status:08X}"

    # Clear only bit 0
    dut.sel.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = 0x01
    await Timer(SYS_CLK_NS * 2, unit="ns")
    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.wdata.value = 0
    await Timer(SYS_CLK_NS * 2, unit="ns")

    # Bit 1 should still be set
    dut.sel.value = 1
    dut.rstrb.value = 1
    await Timer(SYS_CLK_NS, unit="ns")
    status = dut.rdata.value.to_unsigned()
    dut.sel.value = 0
    dut.rstrb.value = 0

    assert status & 0x03 == 0x02, f"only bit 1 should remain, got 0x{status:08X}"


@cocotb.test()
async def ic_test_interrupt_request_pulse(dut):
    """Test that interrupt_request pulses on edge detection."""

    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())

    dut.rst.value = 0
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.wdata.value = 0
    dut.interrupts.value = 0

    await Timer(200, unit="ns")
    dut.rst.value = 1
    await Timer(200, unit="ns")

    # Pulse interrupt
    dut.interrupts.value = 1
    await RisingEdge(dut.interrupt_request)
    await Timer(1, unit="ns")

    assert dut.interrupt_request.value == 1, "interrupt_request should be high"

    # Should auto-clear since int_latched is only high for one cycle
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.interrupts.value = 0

    await Timer(SYS_CLK_NS * 3, unit="ns")
    assert dut.interrupt_request.value == 0, "interrupt_request should clear"
