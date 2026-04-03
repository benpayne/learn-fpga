// video_fetch_engine.v — Scanline prefetch engine for framebuffer display
//
// Reads scanlines from SDRAM into a FIFO, driven by the GPU's actual
// v_count signal. No redundant line counter — the GPU is the source of truth.
//
// On each hsync_start during visible lines (v_count < V_ACTIVE), fetches
// the NEXT scanline (v_count + 1) so it's ready when the GPU needs it.
// During the last VBlank line (v_count == V_TOTAL-1), prefetches line 0.
//
// Each scanline may span two SDRAM rows and is split into burst A + burst B.

module video_fetch_engine #(
    parameter H_ACTIVE       = 640,
    parameter V_ACTIVE       = 400,
    parameter V_TOTAL        = 449,
    parameter STRIDE_WORDS   = 512,
    parameter FB_BASE_PARAM  = 26'hA00000
) (
    input  wire        clk,
    input  wire        resetn,

    // Display timing from GPU
    input  wire        hsync_start,  // 1-cycle pulse at start of HBlank
    input  wire        vsync_start,  // 1-cycle pulse at start of VBlank
    input  wire [9:0]  v_count,      // Current display line from GPU

    // Framebuffer base address
    input  wire [25:0] fb_base,

    // SDRAM burst interface
    output reg         burst_rd,
    output reg  [25:0] burst_addr,
    output reg   [8:0] burst_len,
    input  wire [31:0] burst_dout,
    input  wire        burst_valid,
    input  wire        burst_busy,

    // Line buffer write port
    output wire [31:0] fifo_wdata,
    output wire        fifo_wen,
    input  wire        fifo_full,  // Actually: !wr_ready from line buffer

    // Status
    output wire [9:0]  line_num
);

    localparam LINE_WORDS      = H_ACTIVE / 2;     // 320 words per scanline
    localparam SDRAM_ROW_WORDS = 256;

    // FIFO write: burst data goes directly to FIFO
    assign fifo_wdata = burst_dout;
    assign fifo_wen   = burst_valid & ~fifo_full;

    // ---- Line tracking ----
    // GPU's v_count is source of truth for frame sync (VSync resets).
    // fetch_line tracks which line to fetch next — increments after each
    // completed fetch. This is needed because with the ping-pong buffer,
    // multiple fetches per v_count would overwrite the same buffer.
    reg [9:0] fetch_line;

    wire should_fetch = (fetch_line < V_ACTIVE);

    assign line_num = fetch_line;

    // ---- Address calculation ----
    wire [25:0] line_byte_offset = fetch_line * (STRIDE_WORDS * 4);
    wire [25:0] line_addr        = fb_base + line_byte_offset;

    wire [7:0] col_start = line_addr[9:2];
    wire [8:0] words_to_row_end = SDRAM_ROW_WORDS - {1'b0, col_start};

    wire [8:0] burst_a_len = (LINE_WORDS <= words_to_row_end) ?
                              LINE_WORDS[8:0] : words_to_row_end;
    wire [8:0] burst_b_len = LINE_WORDS[8:0] - burst_a_len;
    wire [25:0] burst_b_base = {line_addr[25:10] + 16'd1, 10'b0};

    // ---- State machine ----
    localparam S_IDLE          = 3'd0;
    localparam S_BURST_A_REQ   = 3'd1;
    localparam S_BURST_A_WAIT  = 3'd2;
    localparam S_BURST_B_REQ   = 3'd3;
    localparam S_BURST_B_WAIT  = 3'd4;

    reg [2:0] state;

    reg [25:0] r_burst_a_addr;
    reg  [8:0] r_burst_a_len;
    reg [25:0] r_burst_b_addr;
    reg  [8:0] r_burst_b_len;
    reg        r_need_burst_b;

    always @(posedge clk) begin
        if (!resetn) begin
            state      <= S_IDLE;
            burst_rd   <= 0;
            fetch_line <= 0;
        end else begin
            burst_rd <= 0;

            // VSync resets line counter (GPU is source of truth for frame sync)
            if (vsync_start)
                fetch_line <= 0;

            case (state)

                S_IDLE: begin
                    // On hsync, if we should fetch and buffer has room, start
                    if (hsync_start && should_fetch && !fifo_full) begin
                        r_burst_a_addr <= line_addr;
                        r_burst_a_len  <= burst_a_len;
                        r_burst_b_addr <= burst_b_base;
                        r_burst_b_len  <= burst_b_len;
                        r_need_burst_b <= (burst_b_len > 0);
                        state          <= S_BURST_A_REQ;
                    end
                end

                S_BURST_A_REQ: begin
                    burst_rd   <= 1;
                    burst_addr <= r_burst_a_addr;
                    burst_len  <= r_burst_a_len;
                    state      <= S_BURST_A_WAIT;
                end

                S_BURST_A_WAIT: begin
                    if (!burst_busy && state == S_BURST_A_WAIT) begin
                        if (r_need_burst_b)
                            state <= S_BURST_B_REQ;
                        else begin
                            fetch_line <= fetch_line + 1;
                            state <= S_IDLE;
                        end
                    end
                end

                S_BURST_B_REQ: begin
                    burst_rd   <= 1;
                    burst_addr <= r_burst_b_addr;
                    burst_len  <= r_burst_b_len;
                    state      <= S_BURST_B_WAIT;
                end

                S_BURST_B_WAIT: begin
                    if (!burst_busy) begin
                        fetch_line <= fetch_line + 1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
