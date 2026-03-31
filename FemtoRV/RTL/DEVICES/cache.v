// Direct-mapped write-through cache for SDRAM with read-modify-write
// 64 entries x 1 word. Handles byte/halfword writes correctly.
//
// Read hit: 0 stall. Read miss: SDRAM read + cache fill.
// Write hit: merge bytes with cached data, write full word to SDRAM.
// Write miss (partial): read word from SDRAM, merge, write back, cache result.
// Write miss (full word): write directly, cache result.

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

    reg [22:0] saved_addr;
    assign sdram_addr = {3'b000, saved_addr};

    // States
    localparam S_IDLE      = 3'd0;
    localparam S_READ      = 3'd1;  // Read miss: waiting for SDRAM read
    localparam S_WRITE     = 3'd2;  // Write: waiting for SDRAM write
    localparam S_RMW_READ  = 3'd3;  // RMW: reading existing word from SDRAM
    localparam S_RMW_WRITE = 3'd4;  // RMW: writing merged word to SDRAM

    reg [2:0] state;
    reg [IDX_BITS-1:0] pend_idx;
    reg [TAG_BITS-1:0] pend_tag;
    reg [3:0] pend_wmask;           // Saved wmask for RMW merge
    reg [31:0] pend_wdata;          // Saved write data for RMW merge
    reg [3:0] wait_cnt;

    // Merge helper: combine old word with new partial data
    function [31:0] merge_word;
        input [31:0] old_word;
        input [31:0] new_data;
        input [3:0]  wmask;
        merge_word = {wmask[3] ? new_data[31:24] : old_word[31:24],
                      wmask[2] ? new_data[23:16] : old_word[23:16],
                      wmask[1] ? new_data[15:8]  : old_word[15:8],
                      wmask[0] ? new_data[7:0]   : old_word[7:0]};
    endfunction

    integer i;

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_IDLE; cpu_busy <= 0;
            sdram_rd <= 0; sdram_wmask <= 0;
            wait_cnt <= 0;
            for (i = 0; i < ENTRIES; i = i + 1) valid[i] <= 0;
        end else begin

            case (state)
            S_IDLE: begin
                sdram_rd <= 0;
                sdram_wmask <= 0;
                cpu_busy <= 0;

                if (cpu_rd) begin
                    if (hit) begin
                        // Read hit
                        cpu_dout <= data_mem[addr_idx];
                    end else begin
                        // Read miss
                        saved_addr <= cpu_addr;
                        sdram_rd   <= 1;
                        pend_idx   <= addr_idx;
                        pend_tag   <= addr_tag;
                        cpu_busy   <= 1;
                        wait_cnt   <= 4'd2;
                        state      <= S_READ;
                    end
                end else if (|cpu_wmask) begin
                    saved_addr <= cpu_addr;
                    pend_idx   <= addr_idx;
                    pend_tag   <= addr_tag;
                    cpu_busy   <= 1;

                    if (cpu_wmask == 4'b1111) begin
                        // Full word write — direct to SDRAM, cache result
                        sdram_din   <= cpu_din;
                        sdram_wmask <= 4'b1111;
                        if (hit) data_mem[addr_idx] <= cpu_din;
                        else begin
                            // Cache the written value
                            data_mem[addr_idx] <= cpu_din;
                            tag_mem[addr_idx]  <= addr_tag;
                            valid[addr_idx]    <= 1'b1;
                        end
                        wait_cnt <= 4'd2;
                        state    <= S_WRITE;
                    end else if (hit) begin
                        // Partial write, cache hit — merge and write
                        sdram_din   <= merge_word(data_mem[addr_idx], cpu_din, cpu_wmask);
                        sdram_wmask <= 4'b1111;
                        data_mem[addr_idx] <= merge_word(data_mem[addr_idx], cpu_din, cpu_wmask);
                        wait_cnt <= 4'd2;
                        state    <= S_WRITE;
                    end else begin
                        // Partial write, cache MISS — need RMW
                        // Step 1: read existing word from SDRAM
                        sdram_rd   <= 1;
                        pend_wmask <= cpu_wmask;
                        pend_wdata <= cpu_din;
                        wait_cnt   <= 4'd2;
                        state      <= S_RMW_READ;
                    end
                end
            end

            S_READ: begin
                // Read miss: wait for SDRAM
                sdram_rd <= 0;
                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    cpu_dout <= sdram_dout;
                    data_mem[pend_idx] <= sdram_dout;
                    tag_mem[pend_idx]  <= pend_tag;
                    valid[pend_idx]    <= 1'b1;
                    cpu_busy <= 0;
                    state    <= S_IDLE;
                end
            end

            S_WRITE: begin
                // Write: wait for SDRAM write to complete
                sdram_wmask <= 0;
                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    cpu_busy <= 0;
                    state    <= S_IDLE;
                end
            end

            S_RMW_READ: begin
                // RMW step 1: wait for SDRAM read of existing word
                sdram_rd <= 0;
                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    // Got existing word — merge with pending write data
                    sdram_din   <= merge_word(sdram_dout, pend_wdata, pend_wmask);
                    sdram_wmask <= 4'b1111;
                    // Cache the merged result
                    data_mem[pend_idx] <= merge_word(sdram_dout, pend_wdata, pend_wmask);
                    tag_mem[pend_idx]  <= pend_tag;
                    valid[pend_idx]    <= 1'b1;
                    wait_cnt <= 4'd2;
                    state    <= S_RMW_WRITE;
                end
            end

            S_RMW_WRITE: begin
                // RMW step 2: wait for merged word write to complete
                sdram_wmask <= 0;
                if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end else if (!sdram_busy) begin
                    cpu_busy <= 0;
                    state    <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        state = S_IDLE; cpu_busy = 0; sdram_rd = 0; sdram_wmask = 0; wait_cnt = 0;
        for (i = 0; i < ENTRIES; i = i + 1) valid[i] = 0;
    end
endmodule
