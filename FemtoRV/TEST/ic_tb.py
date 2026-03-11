# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Edge
from cocotb.clock import Clock, Timer

@cocotb.test()
async def ic_test(dut):
    """Test the interrupt controller."""

    #cocotb.start_saving_waves()
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())

    dut.rst.value = 1 
    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.wdata.value = 0
    dut.interrupts.value = 0

    await Timer(50, units="us")

    dut.rst.value = 0

    await Timer(50, units="us")

    dut.interrupts.value = 1

    await Timer(10, units="us")

    dut.interrupts.value = 0

    await Timer(10, units="us")

    assert dut.interrupt_request.value == 1, "interrupt_request should be high"

    await Timer(10, units="us")

    assert dut.interrupt_request.value == 0, "interrupt_request should clear"

    # Test reading the bit from the status reg
    await Timer(50, units="us")

    dut.sel.value = 1
    dut.rstrb.value = 1

    await Timer(10, units="us")

    assert dut.rdata.value == 1, "interrupt bit should be 1 still"

    dut.sel.value = 0
    dut.rstrb.value = 0

    # Test clearing the bit from the status reg
    await Timer(50, units="us")

    dut.sel.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = 1

    await Timer(10, units="us")

    dut.sel.value = 0
    dut.wstrb.value = 0
    dut.wdata.value = 0

    await Timer(10, units="us")

    assert dut.interrupt_status.value == 0, "interrupt bit should be 0 now"

    await Timer(10, units="us")
