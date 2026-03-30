// Synchronous BRAM sine table for TDM FM synthesis
// Quarter-wave, 256 entries, 16-bit unsigned (0..32767)
// 1-cycle read latency (infers ECP5 EBR block RAM)
module fm_sine_rom (
    input  wire        clk,
    input  wire [7:0]  addr,
    output reg  [15:0] data
);
    reg [15:0] rom [0:255];
    initial $readmemh("sine_table.hex", rom);

    always @(posedge clk)
        data <= rom[addr];
endmodule
