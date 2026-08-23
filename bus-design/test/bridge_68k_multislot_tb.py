"""Multi-card test for the 68k bridge.

Two fake_bus_target_16 cards live behind a backplane decoder at slots 3
and 7 respectively.  The bus-address encoding (per the Architecture
page) places those at 0x430000 and 0x470000.  These tests verify slot
isolation: writes to one slot must not be visible from the other, and a
read from an unaddressed slot must return that slot's own data, not
whatever was last written elsewhere.

Reuses the byte/word helpers from `bridge_68k_tb` (the 68000 driver
contract is identical — only the address routing changes).
"""
import cocotb
from cocotb.triggers import Timer

from bridge_68k_tb import (
    BUS_CLK_PERIOD_NS,  # noqa: F401  (re-exported for reference)
    start_bus_clock,
    reset,
    m68k_write_byte,
    m68k_read_byte,
    m68k_write_word,
    m68k_read_word,
)

# Slot bases per the spec (ADDR[23:20]=0x4, ADDR[19:16]=slot)
SLOT_3_BASE = 0x430000
SLOT_7_BASE = 0x470000


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_isolation_byte(dut):
    """Byte writes to slot 3 must not show up at slot 7, and vice versa."""
    await start_bus_clock(dut)
    await reset(dut)

    # Fan out distinct bytes into both slots' register windows.
    await m68k_write_byte(dut, SLOT_3_BASE + 0x10, 0xA5)
    await m68k_write_byte(dut, SLOT_7_BASE + 0x10, 0x5A)

    a = await m68k_read_byte(dut, SLOT_3_BASE + 0x10)
    b = await m68k_read_byte(dut, SLOT_7_BASE + 0x10)

    assert a == 0xA5, f"slot 3 read returned 0x{a:02x}, expected 0xA5"
    assert b == 0x5A, f"slot 7 read returned 0x{b:02x}, expected 0x5A"


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_isolation_word(dut):
    """Word writes are similarly isolated; both byte lanes per slot."""
    await start_bus_clock(dut)
    await reset(dut)

    await m68k_write_word(dut, SLOT_3_BASE + 0x100, 0xDEAD)
    await m68k_write_word(dut, SLOT_7_BASE + 0x100, 0xBEEF)

    a = await m68k_read_word(dut, SLOT_3_BASE + 0x100)
    b = await m68k_read_word(dut, SLOT_7_BASE + 0x100)

    assert a == 0xDEAD, f"slot 3 word: got 0x{a:04x}, expected 0xDEAD"
    assert b == 0xBEEF, f"slot 7 word: got 0x{b:04x}, expected 0xBEEF"


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_same_offset_different_slots(dut):
    """The same per-slot offset writes to two different cards do not collide."""
    await start_bus_clock(dut)
    await reset(dut)

    # Both at offset 0x200 inside their respective windows
    await m68k_write_byte(dut, SLOT_3_BASE + 0x200, 0x11)
    await m68k_write_byte(dut, SLOT_7_BASE + 0x200, 0x77)

    # Read back, twice, alternating, to make sure neither card was clobbered
    a1 = await m68k_read_byte(dut, SLOT_3_BASE + 0x200)
    b1 = await m68k_read_byte(dut, SLOT_7_BASE + 0x200)
    a2 = await m68k_read_byte(dut, SLOT_3_BASE + 0x200)
    b2 = await m68k_read_byte(dut, SLOT_7_BASE + 0x200)

    assert a1 == 0x11 and a2 == 0x11, f"slot 3 read drift: {a1:#04x}, {a2:#04x}"
    assert b1 == 0x77 and b2 == 0x77, f"slot 7 read drift: {b1:#04x}, {b2:#04x}"


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_unpopulated_slot_does_not_dtack(dut):
    """A cycle to a slot with no card must time out — /DTACK never asserts.

    Slot 0 is unpopulated in this testbench (only slots 3 and 7 have cards),
    so a write to 0x400000 should hang waiting for /DTACK.  We verify that
    /DTACK stays high for ~3 microseconds, then abort the cycle by hand.
    """
    await start_bus_clock(dut)
    await reset(dut)

    # Drive an address cycle aimed at slot 0 — no card listens there.
    dut.cpu_addr.value          = 0x400000 >> 1
    dut.cpu_rw.value            = 0
    dut.cpu_data_drive.value    = 0xCAFE
    dut.cpu_data_drive_oe.value = 1
    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0
    dut.cpu_lds_n.value = 0

    # Sample /DTACK over ~3 us; it must stay deasserted (high) the whole time.
    elapsed = 0
    step = 100
    while elapsed < 3000:
        await Timer(step, units="ns")
        elapsed += step
        assert int(dut.cpu_dtack_n.value) == 1, (
            f"/DTACK asserted at t+{elapsed} ns into an unpopulated slot — "
            "backplane decode is wrong, or some card is driving READY"
        )

    # Abort cleanly.
    dut.cpu_as_n.value          = 1
    dut.cpu_uds_n.value         = 1
    dut.cpu_lds_n.value         = 1
    dut.cpu_data_drive_oe.value = 0
    await Timer(200, units="ns")


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_address_outside_io_region_does_not_dtack(dut):
    """A cycle to an address outside the IO region (ADDR[23:20]!=0x4) is
    also unselected by the backplane.  /DTACK never asserts."""
    await start_bus_clock(dut)
    await reset(dut)

    # 0x100000 is in the bus address space but ADDR[23:20]=1, not 4 —
    # the backplane decoder's IO-tag check rejects it.
    dut.cpu_addr.value          = 0x100000 >> 1
    dut.cpu_rw.value            = 1
    dut.cpu_data_drive_oe.value = 0
    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0
    dut.cpu_lds_n.value = 0

    elapsed = 0
    while elapsed < 2000:
        await Timer(100, units="ns")
        elapsed += 100
        assert int(dut.cpu_dtack_n.value) == 1, (
            f"/DTACK asserted at t+{elapsed} ns into a non-IO address"
        )

    dut.cpu_as_n.value  = 1
    dut.cpu_uds_n.value = 1
    dut.cpu_lds_n.value = 1
    await Timer(200, units="ns")
