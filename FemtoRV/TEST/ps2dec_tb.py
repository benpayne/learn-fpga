# SPDX-FileCopyrightText: © 2024 Ben Payne
# SPDX-License-Identifier: MIT
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.clock import Clock

# System clock period matching hardware (25 MHz)
SYS_CLK_NS = 40


async def send_bit(ps2_clk, ps2_data, bit):
    """Send one PS/2 bit: set data, pulse clock high then low."""
    ps2_data.value = bit
    ps2_clk.value = 1
    await Timer(50, unit="us")
    ps2_clk.value = 0
    await Timer(50, unit="us")


async def send_byte(ps2_clk, ps2_data, value):
    """Send one PS/2 byte frame (start + 8 data + parity + stop)."""
    await send_bit(ps2_clk, ps2_data, 0)  # start
    parity = 0
    for i in range(8):
        bit = (value >> i) & 1
        parity ^= bit
        await send_bit(ps2_clk, ps2_data, bit)
    await send_bit(ps2_clk, ps2_data, ~parity & 1)  # odd parity
    await send_bit(ps2_clk, ps2_data, 1)  # stop
    # Return clock to idle high, wait for core timeout
    # Core needs PS2_BIT_TIME = 25MHz/10kHz = 2500 cycles = 100us at 25MHz
    # Plus debounce delay (~5us). Use 150us for safety.
    ps2_clk.value = 1
    await Timer(150, unit="us")


async def read_bus(dut):
    """Read the PS2 device register via bus interface."""
    dut.sel.value = 1
    dut.rstrb.value = 1
    await Timer(SYS_CLK_NS * 2, unit="ns")
    res = dut.rdata.value.integer
    dut.sel.value = 0
    dut.rstrb.value = 0
    await Timer(SYS_CLK_NS * 2, unit="ns")
    return res


async def init_dut(dut):
    """Initialize DUT with 25MHz clock and release reset."""
    cocotb.start_soon(Clock(dut.clk, SYS_CLK_NS, unit="ns").start())
    dut.reset.value = 0
    dut.rstrb.value = 0
    dut.sel.value = 0
    dut.ps2_clk.value = 1
    dut.ps2_data.value = 1
    await Timer(200, unit="ns")
    dut.reset.value = 1
    # Wait for debounce to settle on idle-high PS2 clock
    await Timer(10, unit="us")


@cocotb.test()
async def ps2_test_single_byte(dut):
    """Test sending a single PS/2 byte and reading it back."""
    await init_dut(dut)

    await send_byte(dut.ps2_clk, dut.ps2_data, 0xAA)

    # Wait for wrapper state machine (IDLE->DELAY->READ->DELAY2)
    await Timer(500, unit="ns")

    assert dut.data_ready.value == 1, "data_ready should be set after byte received"

    value = await read_bus(dut)
    scancode = value & 0xFF
    assert scancode == 0xAA, f"Expected scancode 0xAA, got 0x{scancode:02X}"


@cocotb.test()
async def ps2_test_key_press_release(dut):
    """Test a full key press/release sequence (make + break + make)."""
    await init_dut(dut)

    # Key press: 0x1C ('A' scan code)
    await send_byte(dut.ps2_clk, dut.ps2_data, 0x1C)
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 1, "data_ready should be set after make code"
    value = await read_bus(dut)
    assert (value & 0xFF) == 0x1C, f"Expected 0x1C, got 0x{value & 0xFF:02X}"

    # Break prefix: 0xF0
    await send_byte(dut.ps2_clk, dut.ps2_data, 0xF0)
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 1, "data_ready should be set after break prefix"
    value = await read_bus(dut)
    assert (value & 0xFF) == 0xF0, f"Expected 0xF0, got 0x{value & 0xFF:02X}"

    # Key release: 0x1C again
    await send_byte(dut.ps2_clk, dut.ps2_data, 0x1C)
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 1, "data_ready should be set after release code"
    value = await read_bus(dut)
    assert (value & 0xFF) == 0x1C, f"Expected 0x1C, got 0x{value & 0xFF:02X}"

    # Should be empty now
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 0, "data_ready should be clear when FIFO empty"


@cocotb.test()
async def ps2_test_interrupt_pulse(dut):
    """Test that interrupt pulses on each received byte."""
    await init_dut(dut)

    # Send a byte in the background
    cocotb.start_soon(send_byte(dut.ps2_clk, dut.ps2_data, 0x29))

    # Wait for interrupt
    await RisingEdge(dut.interrupt)

    await Timer(SYS_CLK_NS * 3, unit="ns")

    # Interrupt should have cleared (it's a single-cycle pulse)
    assert dut.interrupt.value == 0, "interrupt should auto-clear after one cycle"

    # Read the byte
    value = await read_bus(dut)
    assert (value & 0xFF) == 0x29, f"Expected 0x29, got 0x{value & 0xFF:02X}"


@cocotb.test()
async def ps2_test_fifo_buffering(dut):
    """Test FIFO buffers bytes when CPU doesn't read immediately."""
    await init_dut(dut)

    # Send two bytes without reading between them
    await send_byte(dut.ps2_clk, dut.ps2_data, 0x1C)
    await Timer(500, unit="ns")
    await send_byte(dut.ps2_clk, dut.ps2_data, 0xF0)
    await Timer(500, unit="ns")

    # First byte should be in output register
    assert dut.data_ready.value == 1, "data_ready should be set"
    value = await read_bus(dut)
    assert (value & 0xFF) == 0x1C, f"Expected 0x1C first, got 0x{value & 0xFF:02X}"

    # Wait for wrapper to pull second byte from FIFO
    await Timer(500, unit="ns")

    # Second byte should now be available
    assert dut.data_ready.value == 1, "second byte should be ready"
    value = await read_bus(dut)
    assert (value & 0xFF) == 0xF0, f"Expected 0xF0 second, got 0x{value & 0xFF:02X}"

    # Should be empty now
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 0, "should be empty after reading all bytes"


@cocotb.test()
async def ps2_test_status_bits(dut):
    """Test that status bits in the register are correct."""
    await init_dut(dut)

    # Initially: data_ready should be low
    assert dut.data_ready.value == 0, "data_ready should be low on startup"

    # Send a byte
    await send_byte(dut.ps2_clk, dut.ps2_data, 0x55)
    await Timer(500, unit="ns")

    # data_ready should now be high
    assert dut.data_ready.value == 1, "data_ready should be set when data available"

    # Read the byte - note: reading consumes it and triggers FIFO advance
    value = await read_bus(dut)
    scancode = value & 0xFF
    assert scancode == 0x55, f"Expected 0x55, got 0x{scancode:02X}"

    # After reading the only byte, data_ready should go low
    await Timer(500, unit="ns")
    assert dut.data_ready.value == 0, "data_ready should clear after last byte consumed"
