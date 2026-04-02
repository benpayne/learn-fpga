
// video_line_fifo.v — Dual-clock FIFO for scanline pixel data
//
// Write port: system clock (clk_w, 25 MHz) — fed by the video fetch engine.
// Read  port: pixel clock  (clk_r, 25 MHz from a different PLL net) — fed by
//             the GPU pixel output logic.
//
// Width: 32 bits (two 16-bit pixels per word).
// Depth: 512 entries = 512 × 32 bits = 2KB.
//        ECP5: one DP16KD configured as 512×32 (2 BRAM blocks).
//        This gives 512 pixels of prefetch (= 0.8 scanlines), enough to
//        guarantee the FIFO is full before active video starts.
//
// CDC method: Gray-code pointer synchronisation.
//   Write pointer crosses to the read  domain via 2-FF synchroniser.
//   Read  pointer crosses to the write domain via 2-FF synchroniser.
//   This is the standard dual-clock async FIFO (Cliff Cummings, SNUG 2002).
//
// Full/empty flags:
//   almost_empty: asserted when fewer than PREFETCH_GUARD words remain.
//                 The pixel clock domain uses this to detect underrun.
//   full:         asserted to the fetch engine to prevent overflow.
//
// Pixel consumer interface:
//   rd_en:        assert to consume one word.
//   rd_data:      the 32-bit word (two packed 16-bit pixels), valid one cycle
//                 after rd_en (registered output).
//   empty:        no data available.
//
// Usage:
//   - Reset both domains by asserting rst_w and rst_r simultaneously.
//   - The fetch engine writes into the FIFO during hblank.
//   - The GPU pixel logic reads one word every 2 pixel clocks (since each
//     32-bit word contains 2 pixels).
//   - The FIFO must be flushed/reset at the start of each frame (vsync).

module video_line_fifo #(
    parameter DEPTH       = 512,   // must be a power of 2
    parameter ADDR_BITS   = 9,     // log2(DEPTH)
    parameter GUARD       = 16     // almost_empty threshold
) (
    // Write port (system clock domain)
    input  wire        clk_w,
    input  wire        rst_w,      // synchronous reset in write domain
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    output wire        full,
    output wire        almost_full,

    // Read port (pixel clock domain)
    input  wire        clk_r,
    input  wire        rst_r,      // synchronous reset in read domain
    output reg  [31:0] rd_data,
    input  wire        rd_en,
    output wire        empty,
    output wire        almost_empty,

    // Debug / status (write-domain)
    output wire [ADDR_BITS:0] wr_fill  // current occupancy (write domain estimate)
);

    // -------------------------------------------------------------------------
    // Storage (simple synchronous BRAM inferred)
    // ECP5 nextpnr will map this to DP16KD primitives.
    // -------------------------------------------------------------------------
    reg [31:0] mem [0:DEPTH-1];

    // -------------------------------------------------------------------------
    // Write domain: binary and Gray-code write pointer
    // -------------------------------------------------------------------------
    reg [ADDR_BITS:0] wr_ptr_bin = 0;  // MSB = wrap bit
    wire [ADDR_BITS:0] wr_ptr_bin_next = wr_ptr_bin + 1;
    wire [ADDR_BITS:0] wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);

    // -------------------------------------------------------------------------
    // Read domain: binary and Gray-code read pointer
    // -------------------------------------------------------------------------
    reg [ADDR_BITS:0] rd_ptr_bin = 0;
    wire [ADDR_BITS:0] rd_ptr_bin_next = rd_ptr_bin + 1;
    wire [ADDR_BITS:0] rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1);

    // -------------------------------------------------------------------------
    // CDC synchronisers
    // -------------------------------------------------------------------------
    // Read pointer Gray code, synchronised into write domain (2 FF stages)
    reg [ADDR_BITS:0] rd_gray_sync1_w = 0, rd_gray_sync2_w = 0;
    always @(posedge clk_w) begin
        rd_gray_sync1_w <= rd_ptr_gray;
        rd_gray_sync2_w <= rd_gray_sync1_w;
    end

    // Write pointer Gray code, synchronised into read domain (2 FF stages)
    reg [ADDR_BITS:0] wr_gray_sync1_r = 0, wr_gray_sync2_r = 0;
    always @(posedge clk_r) begin
        wr_gray_sync1_r <= wr_ptr_gray;
        wr_gray_sync2_r <= wr_gray_sync1_r;
    end

    // -------------------------------------------------------------------------
    // Convert synchronised Gray-code pointers back to binary for arithmetic
    // -------------------------------------------------------------------------

    // rd_ptr_bin as seen from the write domain
    function [ADDR_BITS:0] gray_to_bin;
        input [ADDR_BITS:0] gray;
        integer i;
        reg [ADDR_BITS:0] b;
        begin
            b[ADDR_BITS] = gray[ADDR_BITS];
            for (i = ADDR_BITS-1; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ gray[i];
            gray_to_bin = b;
        end
    endfunction

    wire [ADDR_BITS:0] rd_bin_in_wr_domain = gray_to_bin(rd_gray_sync2_w);
    wire [ADDR_BITS:0] wr_bin_in_rd_domain = gray_to_bin(wr_gray_sync2_r);

    // -------------------------------------------------------------------------
    // Full / almost_full (write domain)
    // Full when the next write pointer equals the read pointer with the MSB
    // flipped (standard Cliff Cummings condition).
    // -------------------------------------------------------------------------
    wire [ADDR_BITS:0] occupancy_w = wr_ptr_bin - rd_bin_in_wr_domain;

    assign full        = (occupancy_w >= DEPTH);
    assign almost_full = (occupancy_w >= DEPTH - 4);
    assign wr_fill     = occupancy_w;

    // -------------------------------------------------------------------------
    // Empty / almost_empty (read domain)
    // -------------------------------------------------------------------------
    wire [ADDR_BITS:0] occupancy_r = wr_bin_in_rd_domain - rd_ptr_bin;

    assign empty        = (occupancy_r == 0);
    assign almost_empty = (occupancy_r < GUARD);

    // -------------------------------------------------------------------------
    // Write logic (write domain)
    // -------------------------------------------------------------------------
    always @(posedge clk_w) begin
        if (rst_w) begin
            wr_ptr_bin <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr_bin[ADDR_BITS-1:0]] <= wr_data;
            wr_ptr_bin <= wr_ptr_bin_next;
        end
    end

    // -------------------------------------------------------------------------
    // Read logic (read domain) — registered output for BRAM timing
    // -------------------------------------------------------------------------
    always @(posedge clk_r) begin
        if (rst_r) begin
            rd_ptr_bin <= 0;
            rd_data    <= 0;
        end else if (rd_en && !empty) begin
            rd_data    <= mem[rd_ptr_bin[ADDR_BITS-1:0]];
            rd_ptr_bin <= rd_ptr_bin_next;
        end
    end

endmodule
