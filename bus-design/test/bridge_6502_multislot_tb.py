"""Multi-card test for the 6502 bridge.

The 6502 has only 16 bits of address, so its bridge maps the whole 64 KB
to one slot (slot 0 here, via BUS_ADDR_BANK=0x40).  A second card lives
at slot 5; the 6502 has no way to reach it, and the test verifies that
nothing the 6502 does affects the slot-5 card.

We can't write to slot 5 from the 6502 (the bridge always emits
ADDR[23:16]=0x40), so we instead write a "marker" pattern via the
backplane to slot 5 ahead of time, then run the 6502 through a workout,
then check that the slot-5 marker is intact.

We do that by reaching directly into the slot-5 card's `mem` from the
testbench, rather than building a second bridge.  This is the kind of
back-door inspection cocotb is good at.

The byte/cycle helpers come from `bridge_6502_tb`.
"""
import cocotb
from cocotb.triggers import Timer

from bridge_6502_tb import (
    start_bus_clock,
    reset,
    cpu_read,
    cpu_write,
)


def slot5_byte(dut, offset):
    """Read a byte directly out of the slot-5 card's memory."""
    return int(dut.u_card_b.mem[offset].value)


def write_slot5_byte(dut, offset, val):
    """Write directly into the slot-5 card's memory (back door)."""
    dut.u_card_b.mem[offset].value = val & 0xFF


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_6502_writes_dont_reach_slot5(dut):
    """The 6502 cannot reach slot 5; writes from it must leave slot 5 alone."""
    await start_bus_clock(dut)
    await reset(dut)

    # Seed slot 5 with a marker.
    write_slot5_byte(dut, 0x10, 0xC3)
    write_slot5_byte(dut, 0x20, 0x3C)
    await Timer(40, units="ns")

    # Hammer the 6502 through 32 byte writes across its 64 KB window.
    for i in range(32):
        addr = (i * 0x800) & 0xFFFF
        await cpu_write(dut, addr, (i * 13) & 0xFF)

    # Slot 5 markers must survive untouched.
    a = slot5_byte(dut, 0x10)
    b = slot5_byte(dut, 0x20)
    assert a == 0xC3, f"slot 5 mem[0x10] was clobbered: 0x{a:02x}"
    assert b == 0x3C, f"slot 5 mem[0x20] was clobbered: 0x{b:02x}"


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_6502_writes_land_in_slot0(dut):
    """6502 writes go to slot 0's card (verified via back-door read)."""
    await start_bus_clock(dut)
    await reset(dut)

    pattern = {0x0010: 0xAB, 0x1234: 0x5C, 0xABCD: 0x42, 0xFFFF: 0x99}
    for addr, val in pattern.items():
        await cpu_write(dut, addr, val)

    await Timer(40, units="ns")

    # Slot 0's card stores at the 6502 address (ADDR[15:0]) directly.
    for addr, expected in pattern.items():
        got = int(dut.u_card_a.mem[addr].value)
        assert got == expected, (
            f"slot 0 mem[0x{addr:04x}] = 0x{got:02x}, expected 0x{expected:02x}"
        )


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_6502_round_trip_slot0(dut):
    """Full round trip via the bus: write through 6502, read through 6502."""
    await start_bus_clock(dut)
    await reset(dut)

    await cpu_write(dut, 0x4321, 0x77)
    got = await cpu_read(dut, 0x4321)
    assert got == 0x77, f"round trip failed: got 0x{got:02x}"
    # Leak detection is covered by test_6502_writes_dont_reach_slot5.
