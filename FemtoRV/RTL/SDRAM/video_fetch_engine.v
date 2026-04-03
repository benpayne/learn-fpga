
// video_fetch_engine.v — Scanline prefetch engine for framebuffer display
//
// Reads one scanline of pixels from SDRAM into a line FIFO ahead of pixel
// output timing.  Designed for 640x400@70Hz, 16bpp at 25 MHz system clock.
//
// -------------------------------------------------------------------------
// Framebuffer layout requirements
// -------------------------------------------------------------------------
// The EM638325 SDRAM has rows of 256 32-bit words (1KB each).  A burst_rd
// request must not cross a row boundary.
//
// This engine splits each scanline into at most two burst requests, splitting
// at the SDRAM row boundary.
//
// Recommended framebuffer layout for simplicity:
//   Stride = 512 words (2KB) — each scanline padded to a 2KB boundary.
//   fb_base must be 2KB-aligned.
//   Active pixels: 320 words (640 × 16bpp) in the first 320 words of each row.
//   With 2KB stride: two rows (512 words) hold one scanline, but only 320 are
//   read.  The first burst reads min(256, words_to_row_end) and the second
//   reads the remainder.
//
//   Line N starts at: fb_base + N * STRIDE_WORDS * 4 (byte offset).
//   With STRIDE_WORDS = 512:
//     Line 0: fb_base           (col 0 of row R)
//     Line 1: fb_base + 2048    (col 0 of row R+2, since 512 words = 2 rows)
//     Line N: fb_base + N*2048  (col 0 of row R+2N)
//   All lines start at col 0 of an SDRAM row.  Burst A = 256 words (col 0..255),
//   Burst B = 64 words (col 0..63 of the next row).
//   This works correctly with no per-line split calculation needed.
//
// Alternative (arbitrary stride):
//   Set STRIDE_WORDS to any value.  The engine computes the starting column
//   position dynamically and splits the burst at the row boundary.
//   The column position wraps modulo 256 and is tracked with a running counter.
//
// This module implements the general case for correctness.
// Use STRIDE_WORDS = 512 for the simplest physical framebuffer layout.
//
// -------------------------------------------------------------------------
// Timing
// -------------------------------------------------------------------------
// At 25 MHz, 800 pixel clocks per line = 32 µs.
// Burst A (up to 256 words): ACTIVATE(1) + tRCD(1) + 256×READ(256) + drain(2)
//   + PRECHARGE(1) + tRP(2) = 263 cycles.
// Burst B (64 words): same formula = 71 cycles.
// Total: 334 cycles.  Remaining for CPU and refresh: 466 cycles.
//
// -------------------------------------------------------------------------
// Parameters
// -------------------------------------------------------------------------
// H_ACTIVE      Active pixels per line (default 640)
// V_ACTIVE      Active lines per frame (default 400)
// STRIDE_WORDS  32-bit words per scanline in memory (default 512, must be
//               a multiple of 256 for col-0-aligned starts, OR use the
//               general dynamic split).  512 = two SDRAM rows.
// FB_BASE_PARAM Default framebuffer base byte address.

module video_fetch_engine #(
    parameter H_ACTIVE       = 640,
    parameter V_ACTIVE       = 400,
    parameter STRIDE_WORDS   = 512,        // memory stride in 32-bit words
    parameter FB_BASE_PARAM  = 26'h810000  // must be 2KB-aligned with STRIDE=512
) (
    input  wire        clk,
    input  wire        resetn,

    // Display timing strobes (one-cycle pulses from VGA/GPU timing generator)
    input  wire        hsync_start,  // start of horizontal blanking interval
    input  wire        vsync_start,  // start of vertical blanking interval

    // Run-time framebuffer base (byte address, must match alignment requirement)
    input  wire [25:0] fb_base,

    // SDRAM burst interface (to sdram_arbiter video port)
    output reg         burst_rd,
    output reg  [25:0] burst_addr,
    output reg   [8:0] burst_len,
    input  wire [31:0] burst_dout,
    input  wire        burst_valid,
    input  wire        burst_busy,

    // FIFO write port (sys-clock domain)
    output wire [31:0] fifo_wdata,
    output wire        fifo_wen,
    input  wire        fifo_full,

    // Status
    output reg  [9:0]  line_num   // scanline currently being fetched
);

    // Words per active scanline (must be <= 2 * SDRAM_ROW_WORDS = 512)
    localparam LINE_WORDS     = H_ACTIVE / 2;           // 320 for 640-wide
    localparam SDRAM_ROW_WORDS = 256;

    // -------------------------------------------------------------------------
    // FIFO write: burst_dout goes directly into FIFO when burst_valid
    // -------------------------------------------------------------------------
    assign fifo_wdata = burst_dout;
    assign fifo_wen   = burst_valid & ~fifo_full;

    // -------------------------------------------------------------------------
    // Scanline base address calculation
    //
    // line_byte_offset = line_num * STRIDE_WORDS * 4
    //   STRIDE_WORDS = 512 = 2^9
    //   line_byte_offset = line_num << (9 + 2) = line_num << 11
    //   = line_num * 2048
    //
    // For general STRIDE_WORDS, use a multiply:
    //   line_byte_offset = line_num * (STRIDE_WORDS * 4)
    //
    // We use the parameterised multiply and rely on synthesis to optimise for
    // power-of-two strides.
    // -------------------------------------------------------------------------
    wire [25:0] line_byte_offset = line_num * (STRIDE_WORDS * 4);
    wire [25:0] line_addr        = fb_base + line_byte_offset;

    // Starting column within an SDRAM row (word index, 0..255)
    // col_start = (line_addr >> 2) & 255 = line_addr[9:2]
    wire [7:0] col_start = line_addr[9:2];

    // Number of words from col_start to the end of the SDRAM row
    wire [8:0] words_to_row_end = SDRAM_ROW_WORDS - {1'b0, col_start};

    // Burst A: from col_start to end of row (or all of LINE_WORDS if it fits)
    wire [8:0] burst_a_len = (LINE_WORDS <= words_to_row_end) ?
                              LINE_WORDS[8:0] : words_to_row_end;

    // Burst B: remaining words in the next SDRAM row (starts at col 0)
    wire [8:0] burst_b_len = LINE_WORDS[8:0] - burst_a_len;

    // Burst B base address: next 1KB boundary after line_addr
    // = (line_addr[25:10] + 1) << 10
    wire [25:0] burst_b_base = {line_addr[25:10] + 16'd1, 10'b0};

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    localparam S_IDLE          = 3'd0;
    localparam S_BURST_A_REQ   = 3'd1;
    localparam S_BURST_A_ARMED = 3'd2;  // wait for burst_busy to rise (accept confirmation)
    localparam S_BURST_A_WAIT  = 3'd3;  // wait for burst_busy to fall (burst complete)
    localparam S_BURST_B_REQ   = 3'd4;
    localparam S_BURST_B_ARMED = 3'd5;
    localparam S_BURST_B_WAIT  = 3'd6;

    reg [2:0] state = S_IDLE;
    reg       frame_active;

    // Registered copies of burst parameters to avoid combinatorial glitches
    // while the burst is in progress
    reg [25:0] r_burst_a_addr;
    reg  [8:0] r_burst_a_len;
    reg [25:0] r_burst_b_addr;
    reg  [8:0] r_burst_b_len;
    reg        r_need_burst_b;

    always @(posedge clk) begin
        if (!resetn) begin
            state        <= S_IDLE;
            line_num     <= 0;
            burst_rd     <= 0;
            frame_active <= 1;  // Start active immediately
        end else begin
            burst_rd <= 0; // default: no request

            case (state)

                S_IDLE: begin
                    if (vsync_start || (line_num >= V_ACTIVE)) begin
                        line_num <= 0;
                    end

                    // Simple: fetch one line per hsync when line_num < V_ACTIVE.
                    // The FIFO VSync flush ensures we start clean each frame.
                    // No VBlank gating — during VBlank, hsync is gated by fetch_enabled
                    // externally, so bursts only happen when mode 2 is active.
                    if (hsync_start && (line_num < V_ACTIVE) && !fifo_full) begin
                        // Register burst parameters for this scanline before
                        // line_addr changes (line_num could change next cycle)
                        r_burst_a_addr <= line_addr;
                        r_burst_a_len  <= burst_a_len;
                        r_burst_b_addr <= burst_b_base;
                        r_burst_b_len  <= burst_b_len;
                        r_need_burst_b <= (burst_b_len > 0);
                        state          <= S_BURST_A_REQ;
                    end
                end

                S_BURST_A_REQ: begin
                    // Issue the burst A request.  burst_busy is guaranteed low
                    // here because we only enter from S_IDLE where the arbiter
                    // was previously idle.  Assert burst_rd for one cycle.
                    burst_rd   <= 1;
                    burst_addr <= r_burst_a_addr;
                    burst_len  <= r_burst_a_len;
                    state      <= S_BURST_A_ARMED;
                end

                S_BURST_A_ARMED: begin
                    // burst_rd has been deasserted (default 0 this cycle).
                    // Wait for the arbiter/controller to raise burst_busy,
                    // confirming the burst has been accepted and started.
                    if (burst_busy) state <= S_BURST_A_WAIT;
                end

                S_BURST_A_WAIT: begin
                    // Wait for burst_busy to fall (burst complete).
                    if (!burst_busy) begin
                        if (r_need_burst_b) begin
                            state <= S_BURST_B_REQ;
                        end else begin
                            line_num <= line_num + 1;
                            state    <= S_IDLE;
                        end
                    end
                end

                S_BURST_B_REQ: begin
                    // burst_busy is guaranteed low (we just came from WAIT where it fell).
                    burst_rd   <= 1;
                    burst_addr <= r_burst_b_addr;
                    burst_len  <= r_burst_b_len;
                    state      <= S_BURST_B_ARMED;
                end

                S_BURST_B_ARMED: begin
                    if (burst_busy) state <= S_BURST_B_WAIT;
                end

                S_BURST_B_WAIT: begin
                    if (!burst_busy) begin
                        line_num <= line_num + 1;
                        state    <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
