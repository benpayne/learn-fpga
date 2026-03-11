# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Edge
from cocotb.clock import Clock, Timer

async def send_bit(ps2_clk, ps2_data, bit):
    ps2_data.value = bit
    ps2_clk.value = 1
    await Timer(50, units="us")
    ps2_clk.value = 0
    await Timer(50, units="us")


async def send_bits(ps2_clk, ps2_data, value, bit_count=8, parity_valid=True, stop_valid=True):
    await send_bit(ps2_clk, ps2_data, 0)  # start bit
    parity = 0
    for i in range(bit_count):
        bit = (value >> (i)) & 1
        parity ^= bit
        await send_bit(ps2_clk, ps2_data, bit)
    if parity_valid:
        await send_bit(ps2_clk, ps2_data, not parity)
    else:
        await send_bit(ps2_clk, ps2_data, parity)
    if stop_valid:
        await send_bit(ps2_clk, ps2_data, 1)  # stop bit
    ps2_clk.value = 1
    await Timer(100, units="us")


async def read_bus(dut):
    dut.sel.value = 1
    dut.rstrb.value = 1

    await Timer(10, units="ns")

    res = dut.rdata.value.integer

    await Timer(10, units="ns")

    dut.sel.value = 0
    dut.rstrb.value = 0

    return res


async def send_key_up_down(dut):
    await send_bits(dut.ps2_clk, dut.ps2_data, 0xC2)
    await send_bits(dut.ps2_clk, dut.ps2_data, 0xF0)
    await send_bits(dut.ps2_clk, dut.ps2_data, 0xC2)


@cocotb.test()
async def ps2_test(dut):
    """Test the PS2 Decoder."""

    #cocotb.start_saving_waves()
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())

    dut.reset.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0

    await Timer(60, units="ns")

    dut.reset.value = 1

    await Timer(60, units="ns")

    await send_key_up_down(dut)

    assert dut.data_ready.value == 1, "data_ready not set after sending keys"

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xC2, f"Value of key not equal to 0xC2 {value & 0xFF}"
    assert dut.data_ready.value == 1, "data_ready not set after reading key"

    await Timer(60, units="ns")

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xF0, f"Value of key not equal to 0xF0 {value & 0xFF}"
    assert dut.data_ready.value == 1, "data_ready not set after reading key"

    await Timer(60, units="ns")

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xC2, f"Value of key not equal to 0xC2 {value & 0xFF}"
    assert dut.data_ready.value == 0, "data_ready set after reading last key"

    await Timer(60, units="ns")

@cocotb.test()
async def ps2_test_int(dut):
    """Test the PS2 Decoder with interrupts."""

    #cocotb.start_saving_waves()
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())

    dut.reset.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0

    await Timer(60, units="ns")

    dut.reset.value = 1

    await Timer(60, units="ns")

    cocotb.start_soon(send_key_up_down(dut))

    await RisingEdge(dut.interrupt)
    await Timer(60, units="ns")

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xC2, f"Value of key not equal to 0xC2 {value & 0xFF}"
    assert dut.data_ready.value == 0, "data_ready not set after reading key"

    await RisingEdge(dut.interrupt)
    await Timer(60, units="ns")

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xF0, f"Value of key not equal to 0xF0 {value & 0xFF}"
    assert dut.data_ready.value == 0, "data_ready not set after reading key"

    await RisingEdge(dut.interrupt)
    await Timer(60, units="ns")

    value = await read_bus(dut)
    assert (value & 0xFF) == 0xC2, f"Value of key not equal to 0xC2 {value & 0xFF}"
    assert dut.data_ready.value == 0, "data_ready set after reading last key"