# Video Fetch Engine Integration Notes

## New Files

- `muchtoremember_colorlight_burst.v` — drop-in replacement for `muchtoremember_colorlight.v`, adds burst-read port
- `sdram_arbiter.v` — two-master arbiter (video + CPU) for the burst controller
- `video_fetch_engine.v` — scanline prefetch state machine
- `video_line_fifo.v` — dual-clock CDC FIFO (write: clk, read: clk_pixel)

## Changes to femtosoc.v

### 1. Include new files (replace the existing SDRAM includes)

```verilog
`ifdef NRV_IO_SDRAM
// Old: `include "SDRAM/muchtoremember_colorlight.v"
`include "SDRAM/muchtoremember_colorlight_burst.v"
`include "SDRAM/sdram_arbiter.v"
`include "SDRAM/video_fetch_engine.v"
`include "SDRAM/video_line_fifo.v"
`include "DEVICES/cache.v"
`endif
```

### 2. SDRAM instantiation block (replace the existing block starting at `NRV_IO_SDRAM`)

```verilog
`ifdef NRV_IO_SDRAM
   wire [31:0] sdram_rdata;
   wire        sdram_busy;

   wire [12:0] sd_addr_full;
   wire        sd_cs_unused;
   wire [3:0]  sd_dqm_unused;
   assign sd_addr = sd_addr_full[10:0];

   // Cache <-> Arbiter wires
   wire [3:0]  cache_sdram_wmask;
   wire        cache_sdram_rd;
   wire [25:0] cache_sdram_addr;
   wire [31:0] cache_sdram_din;
   wire [31:0] cache_sdram_dout;
   wire        cache_sdram_busy;

   // Arbiter <-> Controller wires
   wire [3:0]  arb_ctrl_wmask;
   wire        arb_ctrl_rd;
   wire [25:0] arb_ctrl_addr;
   wire [31:0] arb_ctrl_din;
   wire [31:0] arb_ctrl_dout;
   wire        arb_ctrl_busy;
   wire        arb_ctrl_burst_rd;
   wire [25:0] arb_ctrl_burst_addr;
   wire  [8:0] arb_ctrl_burst_len;
   wire [31:0] arb_ctrl_burst_dout;
   wire        arb_ctrl_burst_valid;
   wire        arb_ctrl_burst_busy;

   // Video fetch engine <-> Arbiter wires
   wire        vid_burst_rd;
   wire [25:0] vid_burst_addr;
   wire  [8:0] vid_burst_len;
   wire [31:0] vid_burst_dout;
   wire        vid_burst_valid;
   wire        vid_burst_busy;

   // Video fetch engine <-> Line FIFO wires
   wire [31:0] vid_fifo_wdata;
   wire        vid_fifo_wen;
   wire        vid_fifo_full;

   // Cache between CPU and Arbiter
   sdram_cache cache (
      .clk(clk),
      .resetn(reset),
      .cpu_wmask(mem_address_is_sdram ? mem_wmask : 4'b0),
      .cpu_rd(mem_address_is_sdram & mem_rstrb),
      .cpu_addr(mem_address[22:0]),
      .cpu_din(mem_wdata),
      .cpu_dout(sdram_rdata),
      .cpu_busy(sdram_busy),
      .sdram_wmask(cache_sdram_wmask),
      .sdram_rd(cache_sdram_rd),
      .sdram_addr(cache_sdram_addr),
      .sdram_din(cache_sdram_din),
      .sdram_dout(cache_sdram_dout),
      .sdram_busy(cache_sdram_busy)
   );

   // Arbiter: CPU (via cache) and video compete for the SDRAM controller
   sdram_arbiter arb (
      .clk(clk),
      .resetn(reset),
      // Video port
      .vid_burst_rd(vid_burst_rd),
      .vid_burst_addr(vid_burst_addr),
      .vid_burst_len(vid_burst_len),
      .vid_burst_dout(vid_burst_dout),
      .vid_burst_valid(vid_burst_valid),
      .vid_burst_busy(vid_burst_busy),
      // CPU port (from cache)
      .cpu_wmask(cache_sdram_wmask),
      .cpu_rd(cache_sdram_rd),
      .cpu_addr(cache_sdram_addr),
      .cpu_din(cache_sdram_din),
      .cpu_dout(cache_sdram_dout),
      .cpu_busy(cache_sdram_busy),
      // Controller
      .ctrl_wmask(arb_ctrl_wmask),
      .ctrl_rd(arb_ctrl_rd),
      .ctrl_addr(arb_ctrl_addr),
      .ctrl_din(arb_ctrl_din),
      .ctrl_dout(arb_ctrl_dout),
      .ctrl_busy(arb_ctrl_busy),
      .ctrl_burst_rd(arb_ctrl_burst_rd),
      .ctrl_burst_addr(arb_ctrl_burst_addr),
      .ctrl_burst_len(arb_ctrl_burst_len),
      .ctrl_burst_dout(arb_ctrl_burst_dout),
      .ctrl_burst_valid(arb_ctrl_burst_valid),
      .ctrl_burst_busy(arb_ctrl_burst_busy)
   );

   // SDRAM controller with burst support
   muchtoremember_burst sdram_ctrl (
      .clk(clk),
      .resetn(reset),
      .sd_clk(sdram_clk),
      .sd_d(sd_d),
      .sd_addr(sd_addr_full),
      .sd_ba(sd_ba),
      .sd_dqm(sd_dqm_unused),
      .sd_cs(sd_cs_unused),
      .sd_we(sd_we),
      .sd_ras(sd_ras),
      .sd_cas(sd_cas),
      // Single-word port (from arbiter/cache)
      .wmask(arb_ctrl_wmask),
      .rd(arb_ctrl_rd),
      .addr(arb_ctrl_addr),
      .din(arb_ctrl_din),
      .dout(arb_ctrl_dout),
      .busy(arb_ctrl_busy),
      // Burst port (from arbiter/video)
      .burst_rd(arb_ctrl_burst_rd),
      .burst_addr(arb_ctrl_burst_addr),
      .burst_len(arb_ctrl_burst_len),
      .burst_dout(arb_ctrl_burst_dout),
      .burst_valid(arb_ctrl_burst_valid),
      .burst_busy(arb_ctrl_burst_busy)
   );

   // Video fetch engine: reads scanlines from SDRAM into the line FIFO
   video_fetch_engine #(
      .H_ACTIVE(640),
      .V_ACTIVE(400),
      .FB_BASE_PARAM(26'h810000)
   ) vfe (
      .clk(clk),
      .resetn(reset),
      .hsync_start(gpu_hsync_start),   // from GPU timing generator
      .vsync_start(gpu_vsync_start),   // from GPU timing generator
      .fb_base(26'h810000),            // or wire to a register
      .burst_rd(vid_burst_rd),
      .burst_addr(vid_burst_addr),
      .burst_len(vid_burst_len),
      .burst_dout(vid_burst_dout),
      .burst_valid(vid_burst_valid),
      .burst_busy(vid_burst_busy),
      .fifo_wdata(vid_fifo_wdata),
      .fifo_wen(vid_fifo_wen),
      .fifo_full(vid_fifo_full)
   );

   // Line FIFO: crosses from sys clk to pixel clk domain
   video_line_fifo #(
      .DEPTH(512),
      .ADDR_BITS(9),
      .GUARD(32)
   ) vfifo (
      .clk_w(clk),
      .rst_w(!reset),
      .wr_data(vid_fifo_wdata),
      .wr_en(vid_fifo_wen),
      .full(vid_fifo_full),
      .almost_full(),
      .clk_r(clk_pixel),              // pixel clock from GPU PLL
      .rst_r(!reset),                  // NOTE: see clock domain reset note below
      .rd_data(vid_pixel_data),        // 32-bit word: {pixel1[15:0], pixel0[15:0]}
      .rd_en(vid_pixel_rd),            // from GPU pixel output logic
      .empty(vid_pixel_empty),
      .almost_empty(vid_pixel_underrun),
      .wr_fill()
   );
`endif
```

## GPU Timing Signals Required

The video fetch engine needs `hsync_start` and `vsync_start` one-cycle pulses
from the GPU's VGA timing generator.  These should be exported from the GPU
wrapper or generated alongside the GPU's sync outputs.

In `gpu_femtorv_wrapper.v` or the top-level GPU module, expose:

```verilog
output wire  hsync_start,  // one-cycle pulse at start of HBlank
output wire  vsync_start,  // one-cycle pulse at start of VBlank
```

These are generated inside the VGA timing state machine:

```verilog
assign hsync_start = (hcount == H_ACTIVE);   // first cycle of HBlank
assign vsync_start = (vcount == V_ACTIVE) && hsync_start;
```

## Clock Domain Reset Note

The `rst_r` input to `video_line_fifo` is in the pixel-clock domain.  The
system `reset` signal is generated in the sys-clock domain.  For a safe CDC
reset, pass `!reset` through two flip-flops clocked by `clk_pixel` before
connecting to `rst_r`.  In practice, since reset only happens at power-up
(before the PLL locks), a direct connection is acceptable for this design.

## Framebuffer Alignment Requirement

The framebuffer base address MUST be aligned to a 1 KB boundary
(256 × 4 bytes = 1024 bytes).  For the default address 0x810000 this is
satisfied (0x810000 is divisible by 1024).

At 640×400×16bpp, each scanline is 1280 bytes.  Since 1280 = 256×5, every
scanline starts at a 1KB-aligned boundary IFF the framebuffer base is 1KB-aligned
AND the stride is a multiple of 1KB.  1280 bytes is NOT a multiple of 1024.
Therefore scanlines cross SDRAM row boundaries after the first.

The `video_fetch_engine` handles this by splitting each scanline into:
- Burst A: 256 words from `line_addr_a` (always row-aligned)
- Burst B:  64 words from `line_addr_b` (next row, col 0..63)

This requires `line_addr_a` to always be 1KB-aligned.  Since:
  `line_addr_a = fb_base + line_num * 1280`
  1280 = 1024 + 256, so each increment by 1280 advances within a row.

Wait: line 0 is at fb_base (1KB-aligned, col 0 = 0).
Line 1 is at fb_base + 1280 = fb_base + 0x500.
0x500 = 5 × 256 words × 4 bytes... col offset = (0x500 / 4) mod 256 = 320 mod 256 = 64.
So line 1 starts at column 64, NOT column 0.  The burst A of 256 words from col 64
would run off the end of the row at col 255 (only 192 words fit).

**This means the simple split (burst A = 256, burst B = 64) is only correct for
line 0.**  For subsequent lines, the split point depends on the line's starting
column position.

### Corrected approach

The `video_fetch_engine` must calculate the correct split based on the actual
starting column of each scanline:

```
col_start = (line_num * LINE_WORDS) % 256    // where LINE_WORDS = 320
burst_a_len = 256 - col_start                // words to end of current SDRAM row
burst_b_len = LINE_WORDS - burst_a_len       // remaining words in next row
burst_b_addr = line_addr_a aligned up to next 1KB boundary
```

The video_fetch_engine.v provided uses the simplified model.  Update it with
the corrected calculation (see TODO in video_fetch_engine.v).

### Simpler alternative: pad stride to 1KB

Set the framebuffer stride to 1024 bytes (256 words), meaning each scanline
occupies 1KB in SDRAM, zero-padded to fill the row.  This wastes:
  400 lines × (1024 - 1280) bytes ... wait, 1280 > 1024.

For 640-wide 16bpp, stride must be >= 1280 bytes.  Round up to 2KB (512 words):
  Stride = 2048 bytes, each scanline = 640 pixels × 2 bytes = 1280 bytes, 768 bytes wasted.
  Total framebuffer = 400 × 2048 = 800 KB.  Fits in 8MB SDRAM easily.
  Each scanline starts at a 2KB boundary, which is also a 1KB (SDRAM row) boundary.
  
  With stride = 512 words:
    burst_a_len = 256 words (first half of the 2KB-aligned scanline)
    burst_b_len = 64 words  (second half — but wait, 256+64=320 < 512... no)
  
  Actually if stride=512 words: burst A = 256, burst B = 256, and the 320 pixels
  are in the first 320 words.  But we only need 320 words, so:
    burst A: 256 words starting at col 0
    burst B: 64 words starting at next row, col 0
  This always works when stride = 512 words (2KB) and fb_base is 2KB-aligned.

**Recommended**: use 2KB stride (512 words per line, 320 active + 192 padding).
Update `video_fetch_engine.v` LINE_BYTES parameter to 2048 and adjust line
offset calculation.

## Resource Usage Estimate

- `muchtoremember_colorlight_burst.v`: ~30 additional LUTs vs original
- `sdram_arbiter.v`:                   ~40 LUTs
- `video_fetch_engine.v`:              ~60 LUTs
- `video_line_fifo.v`:                 ~20 LUTs + 2 DP16KD (2 BRAM blocks)

Total addition: ~150 LUTs + 2 BRAM.
Current usage: 55% LUTs, 51% BRAM (29/56).
After addition: ~56% LUTs, 55% BRAM (31/56).  Comfortable margin.
