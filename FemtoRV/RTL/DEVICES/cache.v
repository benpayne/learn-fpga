// Direct-mapped write-through cache for SDRAM
// 64 entries × 1 word. On hit: 0 stall. On miss: SDRAM read + cache fill.
// Writes: write-through to SDRAM, invalidate cached entry.

module sdram_cache (
    input  wire        clk,
    input  wire        resetn,
    input  wire [3:0]  cpu_wmask,
    input  wire        cpu_rd,
    input  wire [22:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output reg  [31:0] cpu_dout,
    output reg         cpu_busy,
    output reg  [3:0]  sdram_wmask,
    output reg         sdram_rd,
    output wire [25:0] sdram_addr,
    output reg  [31:0] sdram_din,
    input  wire [31:0] sdram_dout,
    input  wire        sdram_busy
);

    localparam ENTRIES = 64;
    localparam IDX_BITS = 6;
    localparam TAG_BITS = 15;

    wire [IDX_BITS-1:0] addr_idx = cpu_addr[7:2];
    wire [TAG_BITS-1:0] addr_tag = cpu_addr[22:8];

    reg [TAG_BITS-1:0] tag_mem [0:ENTRIES-1];
    reg                valid   [0:ENTRIES-1];
    reg [31:0]         data_mem[0:ENTRIES-1];

    wire hit = valid[addr_idx] && (tag_mem[addr_idx] == addr_tag);

    // Mux address: use saved address during pending operations
    reg [22:0] saved_addr;
    assign sdram_addr = {3'b000, saved_addr};

    reg [1:0] state;  // 0=IDLE, 1=READ, 2=WRITE
    reg [IDX_BITS-1:0] pend_idx;
    reg [TAG_BITS-1:0] pend_tag;
    reg [3:0] wait_cnt;  // Wait counter

    integer i;

    always @(posedge clk) begin
        if (!resetn) begin
            state <= 0; cpu_busy <= 0; sdram_rd <= 0; sdram_wmask <= 0;
            wait_cnt <= 0;
            for (i = 0; i < ENTRIES; i = i + 1) valid[i] <= 0;
        end else begin

            case (state)
            2'd0: begin  // IDLE
                sdram_rd <= 0;
                sdram_wmask <= 0;
                cpu_busy <= 0;

                if (cpu_rd) begin
                    if (hit) begin
                        cpu_dout <= data_mem[addr_idx];
                        // cpu_busy stays 0 — no stall on hit
                    end else begin
                        // Cache miss — start SDRAM read
                        saved_addr <= cpu_addr;
                        sdram_rd   <= 1;
                        pend_idx   <= addr_idx;
                        pend_tag   <= addr_tag;
                        cpu_busy   <= 1;
                        wait_cnt   <= 4'd2;  // Skip 2 cycles before checking busy
                        state      <= 2'd1;
                    end
                end else if (|cpu_wmask) begin
                    saved_addr  <= cpu_addr;
                    // SDRAM has no byte masking (DQM hardwired).
                    // For partial writes: merge with cached data, write full word.
                    if (cpu_wmask == 4'b1111) begin
                        sdram_din <= cpu_din;
                    end else if (hit) begin
                        // Merge partial write with cached word
                        sdram_din <= {cpu_wmask[3] ? cpu_din[31:24] : data_mem[addr_idx][31:24],
                                      cpu_wmask[2] ? cpu_din[23:16] : data_mem[addr_idx][23:16],
                                      cpu_wmask[1] ? cpu_din[15:8]  : data_mem[addr_idx][15:8],
                                      cpu_wmask[0] ? cpu_din[7:0]   : data_mem[addr_idx][7:0]};
                    end else begin
                        // Cache miss + partial write: need read-modify-write
                        // For now: just write what we have (may corrupt other bytes)
                        // TODO: implement RMW for cache-miss partial writes
                        sdram_din <= cpu_din;
                    end
                    sdram_wmask <= 4'b1111;  // Always full word to SDRAM
                    // Update cache
                    if (hit) begin
                        data_mem[addr_idx] <= {cpu_wmask[3] ? cpu_din[31:24] : data_mem[addr_idx][31:24],
                                               cpu_wmask[2] ? cpu_din[23:16] : data_mem[addr_idx][23:16],
                                               cpu_wmask[1] ? cpu_din[15:8]  : data_mem[addr_idx][15:8],
                                               cpu_wmask[0] ? cpu_din[7:0]   : data_mem[addr_idx][7:0]};
                    end else begin
                        valid[addr_idx] <= 0;
                    end
                    cpu_busy    <= 1;
                    wait_cnt    <= 4'd2;
                    state       <= 2'd2;
                end
            end

            2'd1: begin  // READ: wait for SDRAM
                sdram_rd <= 0;

                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    // SDRAM finished — latch data
                    cpu_dout <= sdram_dout;
                    data_mem[pend_idx] <= sdram_dout;
                    tag_mem[pend_idx]  <= pend_tag;
                    valid[pend_idx]    <= 1'b1;
                    cpu_busy <= 0;
                    state    <= 2'd0;
                end
            end

            2'd2: begin  // WRITE: wait for SDRAM
                sdram_wmask <= 0;

                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    cpu_busy <= 0;
                    state    <= 2'd0;
                end
            end

            default: state <= 2'd0;
            endcase
        end
    end

    initial begin
        state = 0; cpu_busy = 0; sdram_rd = 0; sdram_wmask = 0; wait_cnt = 0;
        for (i = 0; i < ENTRIES; i = i + 1) valid[i] = 0;
    end
endmodule
