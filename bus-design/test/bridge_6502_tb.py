"""Cocotb testbench for the 6502 -> Retro-Active bus bridge.

Drives the 6502-side signals as a real 6502 would (PHI2 clock, address
valid during PHI2 high, data latched on PHI2 falling edge for reads,
data driven during PHI2 high for writes).  Uses the fake_bus_target
memory behind the bridge to observe side-effects.
"""

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer


BUS_CLK_PERIOD_NS = 40   # 25 MHz bus clock
BUS_CLK_HALF_NS   = BUS_CLK_PERIOD_NS // 2
PHI2_HALF_NS      = 500  # 1 MHz 6502 clock (500 ns high, 500 ns low)


async def drive_bus_clock(dut):
    """Free-running 25 MHz clock driver."""
    dut.bus_clk.value = 0
    while True:
        await Timer(BUS_CLK_HALF_NS, units="ns")
        dut.bus_clk.value = 1
        await Timer(BUS_CLK_HALF_NS, units="ns")
        dut.bus_clk.value = 0


async def start_bus_clock(dut):
    cocotb.start_soon(drive_bus_clock(dut))
    # Let the clock task reach its first Timer yield before we return.
    await Timer(1, units="ns")


async def reset(dut):
    """Assert bus reset for several bus clocks, leave PHI2 low."""
    dut.cpu_phi2.value          = 0
    dut.cpu_addr.value          = 0
    dut.cpu_rw.value            = 1
    dut.cpu_data_drive.value    = 0
    dut.cpu_data_drive_oe.value = 0
    dut.bus_irq.value           = 0
    dut.bus_reset_n.value       = 0
    for _ in range(5):
        await RisingEdge(dut.bus_clk)
    dut.bus_reset_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.bus_clk)


async def cpu_read(dut, addr: int) -> int:
    """Perform a 6502 read cycle for `addr` and return the byte."""
    # Settle: ensure PHI2 is low for a full half-period.
    dut.cpu_phi2.value          = 0
    dut.cpu_data_drive_oe.value = 0
    await Timer(PHI2_HALF_NS, units="ns")

    # Drive address with R/W high (read).  In a real 6502 the address
    # becomes valid during PHI1, just before PHI2 rises.  We set it
    # immediately before the rising edge.
    dut.cpu_addr.value = addr & 0xFFFF
    dut.cpu_rw.value   = 1

    # PHI2 high: cycle active.
    dut.cpu_phi2.value = 1
    await Timer(PHI2_HALF_NS, units="ns")

    # The 6502 samples D0-D7 immediately before the PHI2 falling edge.
    # Capture whatever the bridge is presenting on cpu_data right now.
    val = int(dut.cpu_data_observe.value)

    # PHI2 low again to end the cycle cleanly.
    dut.cpu_phi2.value = 0
    await Timer(50, units="ns")  # small tail so the bridge returns to IDLE

    return val & 0xFF


async def cpu_write(dut, addr: int, data: int) -> None:
    """Perform a 6502 write cycle: addr <- data."""
    dut.cpu_phi2.value          = 0
    dut.cpu_data_drive_oe.value = 0
    await Timer(PHI2_HALF_NS, units="ns")

    # Set address + R/W low + drive data, then raise PHI2.
    dut.cpu_addr.value          = addr & 0xFFFF
    dut.cpu_rw.value            = 0
    dut.cpu_data_drive.value    = data & 0xFF
    dut.cpu_data_drive_oe.value = 1

    dut.cpu_phi2.value = 1
    await Timer(PHI2_HALF_NS, units="ns")

    # End of cycle: release data bus and drop PHI2.
    dut.cpu_phi2.value          = 0
    dut.cpu_data_drive_oe.value = 0
    await Timer(50, units="ns")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_reset_clean(dut):
    """After reset the bridge must not be driving the bus or the CPU side."""
    await start_bus_clock(dut)
    await reset(dut)
    # IRQ from the bus is deasserted -> cpu_irq_n should be high.
    assert int(dut.cpu_irq_n.value) == 1, "cpu_irq_n should be deasserted"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_single_write_then_read(dut):
    """Round-trip: write a byte, read it back, verify it matches."""
    await start_bus_clock(dut)
    await reset(dut)

    await cpu_write(dut, 0x1234, 0xA5)
    got = await cpu_read(dut, 0x1234)
    assert got == 0xA5, f"expected 0xA5, got 0x{got:02x}"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_multiple_addresses(dut):
    """Write several distinct addresses; read them all back."""
    await start_bus_clock(dut)
    await reset(dut)

    pattern = {
        0x0000: 0x00,
        0x0001: 0xFF,
        0x00FF: 0x5A,
        0x0100: 0xA5,
        0x8000: 0xDE,
        0xBEEF: 0xAD,
        0xFFFF: 0x42,
    }

    for addr, val in pattern.items():
        await cpu_write(dut, addr, val)

    for addr, expected in pattern.items():
        got = await cpu_read(dut, addr)
        assert got == expected, (
            f"addr 0x{addr:04x}: expected 0x{expected:02x}, got 0x{got:02x}"
        )


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_irq_passthrough(dut):
    """Bus IRQ high should pull cpu_irq_n low (active-low to 6502)."""
    await start_bus_clock(dut)
    await reset(dut)

    dut.bus_irq.value = 0
    await Timer(100, units="ns")
    assert int(dut.cpu_irq_n.value) == 1, "cpu_irq_n should be 1 when bus_irq=0"

    dut.bus_irq.value = 1
    await Timer(100, units="ns")
    assert int(dut.cpu_irq_n.value) == 0, "cpu_irq_n should be 0 when bus_irq=1"

    dut.bus_irq.value = 0
    await Timer(100, units="ns")
    assert int(dut.cpu_irq_n.value) == 1, "cpu_irq_n should return to 1"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_back_to_back_cycles(dut):
    """Run many fast cycles in sequence to expose any re-entry bugs."""
    await start_bus_clock(dut)
    await reset(dut)

    # Write a ramp, read it back.
    for i in range(16):
        await cpu_write(dut, 0x2000 + i, i ^ 0xAA)
    for i in range(16):
        got = await cpu_read(dut, 0x2000 + i)
        expected = i ^ 0xAA
        assert got == expected, (
            f"ramp[{i}] = 0x{got:02x}, expected 0x{expected:02x}"
        )
