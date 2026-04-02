// SDRAM controller with burst read support for EM638325-6H on Colorlight i5
// 2Mx32 (64Mbit), 32-bit data bus
//
// Based on muchtoremember by Matthias Koch (January 2022)
// Extended with a burst read port for video framebuffer fetch.
//
// The SDRAM MODE register stays at burst_length=1. Burst reads are
// implemented as back-to-back pipelined READ commands with A10=0
// (no auto-precharge). After CAS latency 2, data arrives every cycle.
//
// Two ports:
//   Port A (single-word): Original CPU interface (rd, wmask, addr, din, dout, busy)
//   Port B (burst read):  Video interface (burst_rd, burst_addr, burst_len,
//                          burst_dout, burst_valid, burst_done)
//
// Priority: refresh > burst > single-word

module muchtoremember_burst (

  // Interface to SDRAM chip
  output             sd_clk,
  inout      [31:0]  sd_d,
  output reg [12:0]  sd_addr,
  output reg  [1:0]  sd_ba,
  output reg  [3:0]  sd_dqm,
  output reg         sd_cs,
  output reg         sd_we,
  output reg         sd_ras,
  output reg         sd_cas,

  // Clock and reset
  input  clk,
  input  resetn,

  // Port A: Single-word (CPU)
  input  [3:0]  wmask,
  input         rd,
  input  [25:0] addr,
  input  [31:0] din,
  output reg [31:0] dout,
  output reg busy,

  // Port B: Burst read (Video)
  input         burst_rd,       // Pulse to start burst
  input  [25:0] burst_addr,     // Start address (word-aligned)
  input  [8:0]  burst_len,      // Number of words to read (1-256)
  output reg [31:0] burst_dout, // Burst data output
  output reg    burst_valid,    // Pulse when burst_dout is valid
  output reg    burst_done,     // Pulse when burst completes
  output reg    burst_busy      // High while burst is in progress
);

  parameter sdram_startup_cycles = 10100;
  parameter sdram_refresh_cycles = 195;

  assign sd_clk = ~clk;

  wire [31:0] sd_data_in;
  reg  [31:0] sd_data_out;
  reg         sd_data_drive;

  `ifdef __ICARUS__
  reg [31:0] sd_data_in_buffered;
  assign sd_d = sd_data_drive ? sd_data_out : 32'bz;
  always @(posedge clk) sd_data_in_buffered <= sd_d;
  assign sd_data_in = sd_data_in_buffered;
  `else
  wire [31:0] sd_data_in_unbuffered;
  TRELLIS_IO #(.DIR("BIDIR"))
  sdio_tristate[31:0] (
    .B(sd_d),
    .I(sd_data_out),
    .O(sd_data_in_unbuffered),
    .T(!sd_data_drive)
  );
  IFS1P3BX dbi_ff[31:0] (.D(sd_data_in_unbuffered), .Q(sd_data_in), .SCLK(clk), .PD({32{sd_data_drive}}));
  `endif

  // Configuration: burst length 1, CAS latency 2
  localparam NO_WRITE_BURST = 1'b0;
  localparam OP_MODE        = 2'b00;
  localparam CAS_LATENCY    = 3'd2;
  localparam ACCESS_TYPE    = 1'b0;
  localparam BURST_LENGTH   = 3'b000; // 000=1 (single access)

  localparam MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

  localparam CMD_INHIBIT         = 4'b1111;
  localparam CMD_NOP             = 4'b0111;
  localparam CMD_BURST_TERMINATE = 4'b0110;
  localparam CMD_READ            = 4'b0101;
  localparam CMD_WRITE           = 4'b0100;
  localparam CMD_ACTIVE          = 4'b0011;
  localparam CMD_PRECHARGE       = 4'b0010;
  localparam CMD_AUTO_REFRESH    = 4'b0001;
  localparam CMD_LOAD_MODE       = 4'b0000;

  // ---- States ----
  // Original single-word states
  localparam S_INIT       = 0;
  localparam S_IDLE       = 1;
  localparam S_ACTIVATE   = 2;
  localparam S_READ_1     = 3;
  localparam S_READ_2     = 4;
  localparam S_READ_3     = 5;
  localparam S_READ_4     = 6;
  localparam S_WRITE_1    = 7;
  localparam S_IDLE_IN_6  = 8;
  localparam S_IDLE_IN_5  = 9;
  localparam S_IDLE_IN_4  = 10;
  localparam S_IDLE_IN_3  = 11;
  localparam S_IDLE_IN_2  = 12;
  localparam S_IDLE_IN_1  = 13;
  // Burst read states
  localparam S_BURST_ACT  = 14;  // Row activate for burst
  localparam S_BURST_RD   = 15;  // Issuing READ commands + collecting data
  localparam S_BURST_DRAIN= 16;  // Draining CAS pipeline after last READ
  localparam S_BURST_PRE  = 17;  // Precharge after burst

  reg [4:0] state;

  reg [14:0] reset_counter;
  reg  [7:0] refresh_counter;
  reg        refresh_pending;
  reg        rd_sticky;
  reg  [3:0] wmask_sticky;

  // Burst state
  reg [25:0] burst_cur_addr;    // Current burst address
  reg [8:0]  burst_remaining;   // Words left to issue READ for
  reg [8:0]  burst_to_receive;  // Words left to capture from data bus
  reg [2:0]  cas_pipe;          // 3-bit shift register: CAS2 + input register = 3 cycle latency
  reg [7:0]  burst_col;         // Current column for burst

  wire [7:0] refresh_counterN = refresh_counter - 1;

  always @(posedge clk) begin
    if (!resetn) begin
      state           <= S_INIT;
      reset_counter   <= sdram_startup_cycles;
      busy            <= 0;
      rd_sticky       <= 0;
      wmask_sticky    <= 4'b0000;
      burst_valid     <= 0;
      burst_done      <= 0;
      burst_busy      <= 0;
      cas_pipe        <= 0;
      sd_data_drive   <= 0;
      refresh_pending <= 1;
      refresh_counter <= 0;
    end else begin

      // Default: clear one-cycle pulses
      burst_valid <= 0;
      burst_done  <= 0;

      // Sticky request latching for single-word port
      if (state == S_IDLE || state == S_READ_4 || state == S_WRITE_1) begin
        busy         <= (|wmask) | rd;
        rd_sticky    <= rd;
        wmask_sticky <= wmask;
      end else begin
        busy         <= ((|wmask) | rd) | busy;
        rd_sticky    <= rd | rd_sticky;
        wmask_sticky <= wmask | wmask_sticky;
      end

      // Refresh counter
      if (refresh_counter == 0) begin
        refresh_counter <= sdram_refresh_cycles;
        refresh_pending <= 1;
      end else begin
        refresh_counter <= refresh_counter - 1;
      end

      // Latch burst request
      if (burst_rd && !burst_busy) begin
        burst_busy <= 1;
      end

      case (state)

        // ======== INIT ========
        S_INIT: begin
          sd_ba  <= 2'b00;
          sd_dqm <= 4'b1111;
          sd_data_drive <= 0;

          case (reset_counter)
            33: begin sd_cs <= 0; end
            31: begin {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_PRECHARGE; sd_addr <= 13'b0010000000000; end
            23: begin {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_AUTO_REFRESH; end
            15: begin {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_AUTO_REFRESH; end
            7:  begin {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_LOAD_MODE; sd_addr <= MODE; end
            default: {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          endcase

          reset_counter <= reset_counter - 1;
          if (reset_counter == 0) state <= S_IDLE;
        end

        // ======== IDLE ========
        S_IDLE: begin
          sd_data_drive <= 0;
          sd_dqm <= 4'b1111;

          if (refresh_pending) begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_AUTO_REFRESH;
            refresh_pending <= 0;
            state <= S_IDLE_IN_2;
          end else if (burst_busy) begin
            // Start burst: activate row
            sd_ba   <= burst_addr[22:21];
            sd_addr <= {2'b00, burst_addr[20:10]};
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_ACTIVE;
            burst_cur_addr  <= burst_addr;
            burst_remaining <= burst_len;
            burst_col       <= burst_addr[9:2];
            cas_pipe        <= 0;
            state           <= S_BURST_ACT;
          end else if ((|wmask_sticky) | rd_sticky) begin
            // Single-word access
            sd_ba   <= addr[22:21];
            sd_addr <= {2'b00, addr[20:10]};
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_ACTIVE;
            state <= S_ACTIVATE;
          end else begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          end
        end

        // ======== Single-word read/write (unchanged) ========
        S_ACTIVATE: begin
          sd_data_drive <= ~rd_sticky;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          state <= rd_sticky ? S_READ_1 : S_WRITE_1;
        end

        S_READ_1: begin
          sd_dqm <= 4'b0000;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_READ;
          sd_addr <= {3'b001, 2'b00, addr[9:2]}; // A10=1 auto-precharge
          state <= S_READ_2;
        end

        S_READ_2: begin
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          state <= S_READ_3;
        end

        S_READ_3: state <= S_READ_4;

        S_READ_4: begin
          dout  <= sd_data_in;
          state <= S_IDLE;
        end

        S_WRITE_1: begin
          sd_addr     <= {3'b001, 2'b00, addr[9:2]};
          sd_data_out <= din;
          sd_dqm      <= ~wmask_sticky;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_WRITE;
          state <= S_IDLE_IN_2;
        end

        // ======== Burst read ========
        // Pipeline: READ issued → CAS latency 2 → data valid on sd_data_in
        // We use a 2-bit shift register (cas_pipe) to track when data arrives.
        // cas_pipe[0] = READ was issued 1 cycle ago
        // cas_pipe[1] = READ was issued 2 cycles ago = data is valid NOW

        S_BURST_ACT: begin
          // tRCD wait (1 cycle after ACTIVATE)
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          sd_dqm <= 4'b0000;
          cas_pipe <= 3'b000;
          burst_to_receive <= burst_remaining;
          state <= S_BURST_RD;
        end

        S_BURST_RD: begin
          // Advance CAS pipeline (3 stages: CAS2 + input buffer = 3 cycle total)
          cas_pipe <= {cas_pipe[1:0], 1'b0};

          // Issue READ if more words needed
          if (burst_remaining > 0) begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_READ;
            sd_addr <= {3'b000, 2'b00, burst_col};
            burst_col <= burst_col + 1;
            burst_remaining <= burst_remaining - 1;
            cas_pipe[0] <= 1'b1;
          end else begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          end

          // Capture data when pipeline delivers (3 cycles after READ)
          if (cas_pipe[2]) begin
            burst_dout  <= sd_data_in;
            burst_valid <= 1;
            burst_to_receive <= burst_to_receive - 1;
          end

          // All data received? Go to drain.
          if (burst_to_receive == 0 ||
              (burst_to_receive == 1 && cas_pipe[2])) begin
            state <= S_BURST_DRAIN;
          end
        end

        S_BURST_DRAIN: begin
          // Drain remaining words from CAS pipeline
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          cas_pipe <= {cas_pipe[1:0], 1'b0};

          if (cas_pipe[2]) begin
            burst_dout  <= sd_data_in;
            burst_valid <= 1;
            burst_to_receive <= burst_to_receive - 1;
          end

          if (cas_pipe == 3'b000) begin
            state <= S_BURST_PRE;
          end
        end

        S_BURST_PRE: begin
          // Precharge all banks
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_PRECHARGE;
          sd_addr <= 13'b0010000000000; // A10=1 = all banks
          burst_done <= 1;
          burst_busy <= 0;
          state <= S_IDLE_IN_2;
        end

        // ======== Idle countdown ========
        S_IDLE_IN_6: begin state <= S_IDLE_IN_5; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        S_IDLE_IN_5: begin state <= S_IDLE_IN_4; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        S_IDLE_IN_4: begin state <= S_IDLE_IN_3; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        S_IDLE_IN_3: begin state <= S_IDLE_IN_2; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        S_IDLE_IN_2: begin state <= S_IDLE_IN_1; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        S_IDLE_IN_1: begin state <= S_IDLE;      {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
