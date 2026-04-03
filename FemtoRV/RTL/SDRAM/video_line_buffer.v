// video_line_buffer.v — Double-buffered (ping-pong) scanline buffer
//
// Two 320-word buffers in a single 640×32 BRAM.
// Buffer A (addr 0-319) and Buffer B (addr 320-639).
//
// At any time, one buffer is being displayed (read port) while the
// other is being filled from SDRAM (write port). At hsync, they swap.
//
// This eliminates FIFO underrun — the display always reads from a
// complete, stable buffer while the next line fills in the background.
//
// Uses true dual-port BRAM (ECP5 DP16KD supports this natively).

module video_line_buffer (
    input  wire        clk,
    input  wire        resetn,

    // Write port (from SDRAM burst reader)
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    output reg         wr_ready,      // High when write buffer is available
    output wire        wr_done,       // High when write buffer is full (320 words)

    // Read port (to pixel output)
    input  wire [8:0]  rd_addr,       // 0-319 (word index within line)
    output reg  [31:0] rd_data,

    // Swap control
    input  wire        swap           // Pulse to swap buffers (use when wr_done)
);

    // 640 x 32-bit BRAM: addresses 0-319 = buffer A, 320-639 = buffer B
    reg [31:0] mem [0:639];

    // Active display buffer: 0 = read from A (0-319), write to B (320-639)
    //                        1 = read from B (320-639), write to A (0-319)
    reg active_buf;

    // Write pointer (auto-increments within the write buffer)
    reg [8:0] wr_ptr;

    // Read address with buffer select
    wire [9:0] rd_full_addr = active_buf ? {1'b1, rd_addr} : {1'b0, rd_addr};

    // Write address with buffer select (write to OPPOSITE buffer)
    wire [9:0] wr_full_addr = active_buf ? {1'b0, wr_ptr} : {1'b1, wr_ptr};

    always @(posedge clk) begin
        if (!resetn) begin
            active_buf <= 0;
            wr_ptr     <= 0;
            wr_ready   <= 1;
        end else begin
            // Read port — registered output for BRAM timing
            rd_data <= mem[rd_full_addr];

            // Write port
            if (wr_en && wr_ptr < 320) begin
                mem[wr_full_addr] <= wr_data;
                wr_ptr <= wr_ptr + 1;
            end

            // Swap buffers at hsync
            if (swap) begin
                active_buf <= ~active_buf;
                wr_ptr     <= 0;
                wr_ready   <= 1;
            end

            // Mark write buffer as not ready once it's full
            if (wr_ptr >= 320)
                wr_ready <= 0;
        end
    end

    assign wr_done = (wr_ptr >= 320);

endmodule
