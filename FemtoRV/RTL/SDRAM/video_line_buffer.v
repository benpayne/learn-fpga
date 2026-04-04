// video_line_buffer.v — Double-buffered scanline buffer (ping-pong)
//
// 640 x 32-bit BRAM: addresses 0-319 = buffer A, 320-639 = buffer B
// BRAM-friendly: separate read and write always blocks for inference.

module video_line_buffer (
    input  wire        clk,
    input  wire        resetn,

    // Write port (sequential, from SDRAM burst)
    input  wire [31:0] wr_data,
    input  wire        wr_en,

    // Read port (random access, from pixel output)
    input  wire [8:0]  rd_addr,       // 0-319
    output reg  [31:0] rd_data,

    // Sync
    input  wire        hsync          // Swap + reset on rising edge
);

    reg [31:0] mem [0:639];
    reg        active_buf;
    reg [8:0]  wr_ptr;

    // Buffer A = 0-319, Buffer B = 320-639
    wire [9:0] rd_full_addr = active_buf ? (10'd320 + {1'b0, rd_addr}) : {1'b0, rd_addr};
    wire [9:0] wr_full_addr = active_buf ? {1'b0, wr_ptr} : (10'd320 + {1'b0, wr_ptr});
    wire       do_write = wr_en && wr_ptr < 320;

    // BRAM read port (separate always block for inference)
    always @(posedge clk)
        rd_data <= mem[rd_full_addr];

    // BRAM write port (separate always block for inference)
    always @(posedge clk)
        if (do_write) mem[wr_full_addr] <= wr_data;

    // Control logic
    always @(posedge clk) begin
        if (!resetn) begin
            active_buf <= 0;
            wr_ptr     <= 0;
        end else begin
            if (do_write)
                wr_ptr <= wr_ptr + 1;
            if (hsync) begin
                active_buf <= ~active_buf;
                wr_ptr <= 0;
            end
        end
    end

endmodule
