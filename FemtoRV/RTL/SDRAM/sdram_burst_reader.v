// sdram_burst_reader.v — Burst read overlay for existing SDRAM controller
//
// Sits alongside the original muchtoremember controller. When a burst
// is requested, this module takes over the SDRAM command/address/data pins
// and performs sequential reads. When idle, the original controller drives.
//
// This avoids modifying the original controller's busy signal timing,
// which the cache depends on.
//
// Usage: The arbiter muxes between this module and the original controller
// for the SDRAM pin outputs. The original controller is paused (rd=0, wmask=0)
// during bursts.

module sdram_burst_reader (
    input  wire        clk,
    input  wire        resetn,

    // Burst request interface
    input  wire        burst_rd,       // Pulse to start burst
    input  wire [25:0] burst_addr,     // Start address (byte address, word-aligned)
    input  wire [8:0]  burst_len,      // Number of 32-bit words to read (1-256)
    output reg  [31:0] burst_dout,     // Data output
    output reg         burst_valid,    // Pulse when burst_dout is valid
    output reg         burst_done,     // Pulse when burst completes
    output reg         burst_busy,     // High during burst

    // SDRAM pin control (active only during burst)
    output reg         active,         // 1 = this module drives SDRAM pins
    output reg  [12:0] sd_addr,
    output reg  [1:0]  sd_ba,
    output reg  [3:0]  sd_dqm,
    output reg         sd_cs,
    output reg         sd_we,
    output reg         sd_ras,
    output reg         sd_cas,

    // SDRAM data input (directly from SDRAM chip via input register)
    input  wire [31:0] sd_data_in,

    // Original controller busy signal — must wait for idle before taking over
    input  wire        ctrl_busy
);

    localparam CMD_NOP        = 4'b0111;
    localparam CMD_READ       = 4'b0101;
    localparam CMD_ACTIVE     = 4'b0011;
    localparam CMD_PRECHARGE  = 4'b0010;

    // States
    localparam S_IDLE        = 0;
    localparam S_WAIT_IDLE   = 1;  // Wait for original controller to finish
    localparam S_WAIT_SETTLE = 2;  // Extra settle cycles
    localparam S_ACTIVATE    = 3;  // Row activate issued, wait tRCD
    localparam S_READING     = 4;  // Issuing READs and collecting data
    localparam S_DRAIN       = 5;  // Draining CAS pipeline after last READ
    localparam S_PRECHARGE   = 6;  // Precharge issued, wait tRP

    reg [2:0] state;

    // Burst tracking
    reg [7:0]  col;              // Current column
    reg [8:0]  reads_remaining;  // READs left to issue
    reg [8:0]  data_remaining;   // Data words left to capture
    reg [2:0]  cas_pipe;         // 3-bit shift register tracking CAS pipeline
    reg [1:0]  pre_wait;         // Precharge recovery counter

    always @(posedge clk) begin
        if (!resetn) begin
            state          <= S_IDLE;
            burst_busy     <= 0;
            burst_valid    <= 0;
            burst_done     <= 0;
            active         <= 0;
            cas_pipe       <= 0;
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
        end else begin
            burst_valid <= 0;
            burst_done  <= 0;

            case (state)

            S_IDLE: begin
                active <= 0;
                if (burst_rd && !burst_busy) begin
                    burst_busy <= 1;
                    // Latch burst parameters
                    col     <= burst_addr[9:2];
                    reads_remaining <= burst_len;
                    data_remaining  <= burst_len;
                    cas_pipe <= 0;
                    state   <= S_WAIT_IDLE;
                end
            end

            S_WAIT_IDLE: begin
                // Wait for original controller to be idle, then wait 2 extra
                // cycles for it to settle in IDLE state before taking over pins.
                if (!ctrl_busy) begin
                    pre_wait <= 2;
                    state <= S_WAIT_SETTLE;
                end
            end

            S_WAIT_SETTLE: begin
                // Extra settle time after controller goes idle
                if (pre_wait > 0) begin
                    pre_wait <= pre_wait - 1;
                end else begin
                    active  <= 1;
                    sd_ba   <= burst_addr[22:21];
                    sd_addr <= {2'b00, burst_addr[20:10]};
                    {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_ACTIVE;
                    sd_dqm  <= 4'b0000;
                    state   <= S_ACTIVATE;
                end
            end

            S_ACTIVATE: begin
                // tRCD wait (1 cycle after ACTIVATE)
                {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
                state <= S_READING;
            end

            S_READING: begin
                // Shift CAS pipeline
                cas_pipe <= {cas_pipe[1:0], 1'b0};

                // Issue next READ if more needed
                if (reads_remaining > 0) begin
                    {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_READ;
                    sd_addr <= {3'b000, 2'b00, col};  // A10=0, no auto-precharge
                    col <= col + 1;
                    reads_remaining <= reads_remaining - 1;
                    cas_pipe[0] <= 1'b1;
                end else begin
                    {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
                end

                // Capture data from CAS pipeline (3 cycles after READ)
                if (cas_pipe[2]) begin
                    burst_dout <= sd_data_in;
                    burst_valid <= 1;
                    data_remaining <= data_remaining - 1;
                end

                // All READs issued and pipeline draining
                if (reads_remaining == 0 && !cas_pipe[0] && !cas_pipe[1]) begin
                    state <= S_DRAIN;
                end
            end

            S_DRAIN: begin
                {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
                cas_pipe <= {cas_pipe[1:0], 1'b0};

                if (cas_pipe[2]) begin
                    burst_dout <= sd_data_in;
                    burst_valid <= 1;
                    data_remaining <= data_remaining - 1;
                end

                if (cas_pipe == 3'b000) begin
                    // Precharge all banks
                    {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_PRECHARGE;
                    sd_addr <= 13'b0010000000000;  // A10=1 = all banks
                    pre_wait <= 2;
                    state <= S_PRECHARGE;
                end
            end

            S_PRECHARGE: begin
                {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
                pre_wait <= pre_wait - 1;
                if (pre_wait == 0) begin
                    burst_done <= 1;
                    burst_busy <= 0;
                    active     <= 0;
                    state      <= S_IDLE;
                end
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule
