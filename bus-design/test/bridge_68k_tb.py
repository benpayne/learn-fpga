"""Cocotb testbench for the MC68000 -> Retro-Active bus bridge.

The 68000 has an asynchronous bus — the master asserts /AS plus byte
strobes, then waits for the slave to respond with /DTACK.  These tests
emulate that handshake against the `bridge_68k` module and verify
byte/word reads and writes against a fake memory target behind the bus.

Endianness note
---------------
The 68000 is big-endian on its data bus:
  - Even byte (addr & 1 == 0)  → uses /UDS, data on 68k D[15:8]
  - Odd  byte (addr & 1 == 1)  → uses /LDS, data on 68k D[ 7:0]

The bridge cross-wires these so the Retro-Active bus sees:
  - Bus DATA[7:0]  is always "byte at ADDR+0"  (came from 68k D[15:8])
  - Bus DATA[15:8] is always "byte at ADDR+1"  (came from 68k D[ 7:0])

This file models *the 68000 side*, so the data patterns you see below
are placed on 68k D[15:8] for even-byte accesses and on D[7:0] for odd.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


BUS_CLK_PERIOD_NS = 40                  # 25 MHz bus clock


async def start_bus_clock(dut):
    cocotb.start_soon(Clock(dut.bus_clk, BUS_CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    """Hold bus reset low for several bus clocks with the 68k side idle."""
    dut.cpu_as_n.value          = 1
    dut.cpu_uds_n.value         = 1
    dut.cpu_lds_n.value         = 1
    dut.cpu_rw.value            = 1
    dut.cpu_addr.value          = 0
    dut.cpu_data_drive.value    = 0
    dut.cpu_data_drive_oe.value = 0
    dut.bus_irq.value           = 0
    dut.bus_reset_n.value       = 0
    for _ in range(5):
        await RisingEdge(dut.bus_clk)
    dut.bus_reset_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.bus_clk)


async def wait_dtack(dut, timeout_ns: int = 4000) -> None:
    """Poll /DTACK until it goes low (active).  Fails on timeout."""
    elapsed = 0
    step = 10
    while int(dut.cpu_dtack_n.value) == 1:
        await Timer(step, units="ns")
        elapsed += step
        if elapsed > timeout_ns:
            raise TimeoutError(f"/DTACK did not assert within {timeout_ns} ns")


async def wait_dtack_released(dut, timeout_ns: int = 2000) -> None:
    """Wait for /DTACK to go high again once we release /AS."""
    elapsed = 0
    step = 10
    while int(dut.cpu_dtack_n.value) == 0:
        await Timer(step, units="ns")
        elapsed += step
        if elapsed > timeout_ns:
            raise TimeoutError("/DTACK stayed low after /AS released")


async def m68k_write_byte(dut, addr: int, data: int) -> None:
    """Single byte write, 68k async style."""
    even = (addr & 1) == 0
    word_addr = addr >> 1           # drives A1..A23

    # Idle settle
    await Timer(20, units="ns")

    # Drive address + R/W + data first (like the 68000 does in S1)
    dut.cpu_addr.value = word_addr & 0x7FFFFF
    dut.cpu_rw.value   = 0

    if even:
        # Even byte: UDS active, data on D[15:8], D[7:0] don't-care
        dut.cpu_data_drive.value = (data & 0xFF) << 8
    else:
        # Odd byte: LDS active, data on D[7:0]
        dut.cpu_data_drive.value = data & 0xFF
    dut.cpu_data_drive_oe.value = 1

    # Assert strobes
    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0 if even else 1
    dut.cpu_lds_n.value = 1 if even else 0

    # Wait for /DTACK
    await wait_dtack(dut)

    # Release strobes
    dut.cpu_as_n.value          = 1
    dut.cpu_uds_n.value         = 1
    dut.cpu_lds_n.value         = 1
    dut.cpu_data_drive_oe.value = 0

    # Wait for bridge to return to IDLE
    await wait_dtack_released(dut)


async def m68k_read_byte(dut, addr: int) -> int:
    """Single byte read, 68k async style."""
    even = (addr & 1) == 0
    word_addr = addr >> 1

    await Timer(20, units="ns")

    dut.cpu_addr.value          = word_addr & 0x7FFFFF
    dut.cpu_rw.value            = 1
    dut.cpu_data_drive_oe.value = 0

    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0 if even else 1
    dut.cpu_lds_n.value = 1 if even else 0

    await wait_dtack(dut)

    # Sample just the lane the CPU cares about.  The other half of D[15:0]
    # is legitimately tri-state because the bridge only OE's the 245 whose
    # strobe is asserted — parsing the whole 16 bits as int would choke on
    # the Z bits, so we slice the binstr instead.
    bs = dut.cpu_data_observe.value.binstr.rjust(16, '0')
    slice_ = bs[0:8] if even else bs[8:16]
    assert 'z' not in slice_ and 'x' not in slice_, (
        f"cpu_data lane unresolved: full={bs} lane={slice_}"
    )
    val = int(slice_, 2)

    # Release
    dut.cpu_as_n.value  = 1
    dut.cpu_uds_n.value = 1
    dut.cpu_lds_n.value = 1
    await wait_dtack_released(dut)

    return val


async def m68k_write_word(dut, addr: int, data: int) -> None:
    """Word write (16-bit, addr must be even).  68k places data on D[15:0]
    with the high byte going to the even address."""
    assert (addr & 1) == 0, "Word accesses must be even-aligned on the 68k"
    word_addr = addr >> 1

    await Timer(20, units="ns")
    dut.cpu_addr.value          = word_addr & 0x7FFFFF
    dut.cpu_rw.value            = 0
    dut.cpu_data_drive.value    = data & 0xFFFF
    dut.cpu_data_drive_oe.value = 1

    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0
    dut.cpu_lds_n.value = 0

    await wait_dtack(dut)

    dut.cpu_as_n.value          = 1
    dut.cpu_uds_n.value         = 1
    dut.cpu_lds_n.value         = 1
    dut.cpu_data_drive_oe.value = 0
    await wait_dtack_released(dut)


async def m68k_read_word(dut, addr: int) -> int:
    """Word read (16-bit, addr must be even)."""
    assert (addr & 1) == 0, "Word accesses must be even-aligned on the 68k"
    word_addr = addr >> 1

    await Timer(20, units="ns")
    dut.cpu_addr.value          = word_addr & 0x7FFFFF
    dut.cpu_rw.value            = 1
    dut.cpu_data_drive_oe.value = 0

    dut.cpu_as_n.value  = 0
    dut.cpu_uds_n.value = 0
    dut.cpu_lds_n.value = 0

    await wait_dtack(dut)

    val = int(dut.cpu_data_observe.value) & 0xFFFF

    dut.cpu_as_n.value  = 1
    dut.cpu_uds_n.value = 1
    dut.cpu_lds_n.value = 1
    await wait_dtack_released(dut)

    return val


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_reset_clean(dut):
    """After reset: /DTACK inactive, /IPL inactive, nothing driving the bus."""
    await start_bus_clock(dut)
    await reset(dut)
    assert int(dut.cpu_dtack_n.value) == 1, "/DTACK should be deasserted"
    assert int(dut.cpu_ipl0_n.value) == 1, "/IPL lines should be inactive"
    assert int(dut.cpu_ipl1_n.value) == 1
    assert int(dut.cpu_ipl2_n.value) == 1


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_byte_write_read_even(dut):
    """Write byte to even address (uses UDS), read it back."""
    await start_bus_clock(dut)
    await reset(dut)
    await m68k_write_byte(dut, 0x1234, 0xA5)
    got = await m68k_read_byte(dut, 0x1234)
    assert got == 0xA5, f"expected 0xA5, got 0x{got:02x}"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_byte_write_read_odd(dut):
    """Write byte to odd address (uses LDS), read it back."""
    await start_bus_clock(dut)
    await reset(dut)
    await m68k_write_byte(dut, 0x1235, 0x5A)
    got = await m68k_read_byte(dut, 0x1235)
    assert got == 0x5A, f"expected 0x5A, got 0x{got:02x}"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_word_write_read(dut):
    """Word write + read through both byte strobes together."""
    await start_bus_clock(dut)
    await reset(dut)
    await m68k_write_word(dut, 0x2000, 0xDEAD)
    got = await m68k_read_word(dut, 0x2000)
    assert got == 0xDEAD, f"expected 0xDEAD, got 0x{got:04x}"


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_byte_pair_alignment(dut):
    """Byte writes to both halves of the same word; word read sees both."""
    await start_bus_clock(dut)
    await reset(dut)
    await m68k_write_byte(dut, 0x3000, 0xAB)   # even byte (UDS)
    await m68k_write_byte(dut, 0x3001, 0xCD)   # odd  byte (LDS)
    got = await m68k_read_word(dut, 0x3000)
    # Even byte is the MSB of the 68k word, odd byte is the LSB.
    expected = (0xAB << 8) | 0xCD
    assert got == expected, f"expected 0x{expected:04x}, got 0x{got:04x}"


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_multiple_addresses(dut):
    """Scatter pattern across the 16-bit address space."""
    await start_bus_clock(dut)
    await reset(dut)

    pattern = {
        0x0000: 0x00,
        0x0001: 0xFF,
        0x00FE: 0x5A,
        0x0100: 0xA5,
        0x7000: 0xDE,
        0xBEEE: 0xAD,
        0xFFFE: 0x42,
    }

    for addr, val in pattern.items():
        await m68k_write_byte(dut, addr, val)

    for addr, expected in pattern.items():
        got = await m68k_read_byte(dut, addr)
        assert got == expected, (
            f"addr 0x{addr:04x}: expected 0x{expected:02x}, got 0x{got:02x}"
        )


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_irq_passthrough(dut):
    """Bus IRQ high → /IPL lines low (CPU sees an interrupt)."""
    await start_bus_clock(dut)
    await reset(dut)

    dut.bus_irq.value = 0
    await Timer(100, units="ns")
    assert int(dut.cpu_ipl0_n.value) == 1

    dut.bus_irq.value = 1
    await Timer(100, units="ns")
    assert int(dut.cpu_ipl0_n.value) == 0
    assert int(dut.cpu_ipl1_n.value) == 0
    assert int(dut.cpu_ipl2_n.value) == 0

    dut.bus_irq.value = 0
    await Timer(100, units="ns")
    assert int(dut.cpu_ipl0_n.value) == 1
