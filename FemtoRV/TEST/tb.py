# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Edge
from cocotb.clock import Clock, Timer

@cocotb.test()
async def timer_test(dut):
    """Test the timer interrupt."""

    #cocotb.start_saving_waves()
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())

    dut.wstrb.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.wdata.value = 0
    dut.rdata.value = 0

    await Timer(100, units="us")

    dut.sel.value = 1
    dut.wstrb.value = 1
    dut.wdata.value = 40

    await Timer(10, units="us")

    dut.sel.value = 0
    dut.wstrb.value = 0

    await Timer(410, units="us")

    assert dut.complete_reg.value == 1, "complete should be high"

    await Timer(10, units="us")

    assert dut.complete_reg.value == 0, "complete cleared"

    #cocotb.stop_saving_waves()