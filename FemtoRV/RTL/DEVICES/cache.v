// Pass-through "cache" - no actual caching, just forwards to SDRAM
// Used to verify the wiring is correct before adding real caching logic

module sdram_cache (
    input  wire        clk,
    input  wire        resetn,
    input  wire [3:0]  cpu_wmask,
    input  wire        cpu_rd,
    input  wire [22:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    output wire        cpu_busy,
    output wire [3:0]  sdram_wmask,
    output wire        sdram_rd,
    output wire [25:0] sdram_addr,
    output wire [31:0] sdram_din,
    input  wire [31:0] sdram_dout,
    input  wire        sdram_busy
);
    // Pure pass-through: no caching
    assign sdram_wmask = cpu_wmask;
    assign sdram_rd    = cpu_rd;
    assign sdram_addr  = {3'b000, cpu_addr};
    assign sdram_din   = cpu_din;
    assign cpu_dout    = sdram_dout;
    assign cpu_busy    = sdram_busy;
endmodule
