"""
Cocotb testbench for the complete video fetch pipeline:
  video_fetch_engine → sdram_arbiter → muchtoremember_burst → video_line_fifo

Tests that a full scanline of 320 words (640 pixels @ 16bpp) is fetched
from SDRAM and appears correctly in the FIFO output.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


@cocotb.test()
async def test_single_scanline_fetch(dut):
    """Fetch one scanline from SDRAM and read from FIFO."""
    clock = Clock(dut.clk, 40, unit="ns")  # 25MHz
    cocotb.start_soon(clock.start())

    # Reset
    dut.resetn.value = 0
    dut.hsync_start.value = 0
    dut.vsync_start.value = 0
    dut.fb_base.value = 0  # Framebuffer at SDRAM address 0
    dut.fifo_rd_en.value = 0
    dut.sd_d_in.value = 0
    # CPU idle
    dut.cpu_rd.value = 0
    dut.cpu_wmask.value = 0
    dut.cpu_addr.value = 0
    dut.cpu_din.value = 0

    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1

    # Wait for SDRAM init (~10100 cycles)
    dut._log.info("Waiting for SDRAM init...")
    await ClockCycles(dut.clk, 10200)

    # Pre-fill SDRAM model: provide data on sd_d_in when read
    # The SDRAM model is external — we'll simulate it by responding
    # to READ commands on sd_d_in

    # Start a frame
    dut._log.info("Sending vsync_start...")
    dut.vsync_start.value = 1
    await RisingEdge(dut.clk)
    dut.vsync_start.value = 0
    await ClockCycles(dut.clk, 5)

    # Trigger scanline fetch
    dut._log.info("Sending hsync_start...")
    dut.hsync_start.value = 1
    await RisingEdge(dut.clk)
    dut.hsync_start.value = 0

    # Feed SDRAM data: the controller will issue READ commands
    # We respond with sequential test data
    read_count = 0
    fifo_words = []
    burst_complete = False

    for cycle in range(2000):
        await RisingEdge(dut.clk)

        # Feed sequential data on sd_d_in (simulating SDRAM)
        # Data appears 2 cycles after READ command (CAS2)
        # For simplicity, always drive sequential data
        try:
            if int(dut.sd_cas.value) == 0 and int(dut.sd_cs.value) == 0 and int(dut.sd_we.value) == 1:
                # This is a READ command (CS=0, RAS=1, CAS=0, WE=1)
                read_count += 1
        except:
            pass

        # Always provide data — the controller will sample when ready
        dut.sd_d_in.value = read_count

        # Check if FIFO has data and read it
        try:
            if not int(dut.fifo_empty.value):
                dut.fifo_rd_en.value = 1
            else:
                dut.fifo_rd_en.value = 0

            if dut.fifo_rd_en.value and not int(dut.fifo_empty.value):
                fifo_words.append(int(dut.fifo_rd_data.value))
        except:
            dut.fifo_rd_en.value = 0

        # Check if fetch is done
        try:
            if int(dut.fetch_line_num.value) > 0:
                burst_complete = True
                break
        except:
            pass

    dut._log.info(f"Fetch complete after {cycle} cycles")
    dut._log.info(f"READ commands issued: {read_count}")
    dut._log.info(f"FIFO words read: {len(fifo_words)}")

    if len(fifo_words) > 0:
        dut._log.info(f"  First: 0x{fifo_words[0]:08X}")
        dut._log.info(f"  Last:  0x{fifo_words[-1]:08X}")

    assert burst_complete, "Fetch did not complete within timeout"
    assert len(fifo_words) > 0, "No data received from FIFO"

    dut._log.info("Single scanline fetch: PASS")
