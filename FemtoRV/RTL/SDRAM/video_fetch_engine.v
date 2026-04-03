// video_fetch_engine.v — Minimal scanline fetch engine
//
// On each hsync: read 320 words from SDRAM as a single burst.
// The SDRAM controller handles row boundary crossing internally.
// Increment line counter after each fetch. VSync resets to line 0.

module video_fetch_engine #(
    parameter V_ACTIVE      = 400,
    parameter STRIDE_BYTES  = 2048,
    parameter LINE_WORDS    = 320,
    parameter FB_BASE_PARAM = 26'h200000
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        hsync_start,
    input  wire        vsync_start,
    input  wire [9:0]  v_count,

    input  wire [25:0] fb_base,

    output reg         burst_rd,
    output reg  [25:0] burst_addr,
    output reg   [8:0] burst_len,
    input  wire [31:0] burst_dout,
    input  wire        burst_valid,
    input  wire        burst_busy,

    output wire [31:0] fifo_wdata,
    output wire        fifo_wen,
    input  wire        fifo_full,

    output wire [9:0]  line_num
);

    assign fifo_wdata = burst_dout;
    assign fifo_wen   = burst_valid;

    reg [9:0] fetch_line;
    assign line_num = fetch_line;

    wire [25:0] line_addr = fb_base + (fetch_line * STRIDE_BYTES);

    localparam S_IDLE = 0;
    localparam S_REQ  = 1;
    localparam S_WAIT = 2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (!resetn) begin
            state      <= S_IDLE;
            fetch_line <= 0;
            burst_rd   <= 0;
        end else begin
            burst_rd <= 0;

            if (vsync_start)
                fetch_line <= 0;

            case (state)
                S_IDLE: begin
                    if (hsync_start && fetch_line < V_ACTIVE)
                        state <= S_REQ;
                end

                S_REQ: begin
                    burst_rd   <= 1;
                    burst_addr <= line_addr;
                    burst_len  <= LINE_WORDS;
                    state      <= S_WAIT;
                end

                S_WAIT: begin
                    if (!burst_busy) begin
                        fetch_line <= fetch_line + 1;
                        state      <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
