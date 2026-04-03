// SDRAM controller with burst read support for EM638325-6H
// 2Mx32 (64Mbit), 32-bit data bus
//
// Based on muchtoremember by Matthias Koch (January 2022)
// Extended with burst read port for video framebuffer fetch.
//
// Single-word port: identical timing to original muchtoremember.
// Burst read port: back-to-back pipelined READs, ~1 word/cycle.
// Priority: refresh > burst (when requested) > single-word.
//
// Uses one-hot state encoding identical to the original to preserve
// the exact busy signal timing that the cache depends on.

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

  // Single-word port (from cache)
  input  [3:0]  wmask,
  input         rd,
  input  [25:0] addr,
  input  [31:0] din,
  output reg [31:0] dout,
  output reg busy,

  // Burst read port (from video fetch engine)
  input         burst_rd,       // Pulse to start burst
  input  [25:0] burst_addr,     // Start address
  input  [8:0]  burst_len,      // Words to read (1-256)
  output reg [31:0] burst_dout, // Data output
  output reg    burst_valid,    // Data valid pulse
  output reg    burst_done,     // Burst complete pulse
  output reg    burst_busy,     // High during burst

  // Exposed data input for sharing
  output wire [31:0] sd_data_in_out
);

  parameter sdram_startup_cycles = 10100;
  parameter sdram_refresh_cycles = 195;

  assign sd_clk = ~clk;

  wire [31:0] sd_data_in;
  reg  [31:0] sd_data_out;
  reg         sd_data_drive;

  assign sd_data_in_out = sd_data_in;

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
  localparam BURST_LENGTH   = 3'b000;

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

  // One-hot states — single-word states match original exactly
  localparam s_init_bit      = 0;  localparam s_init      = 1 << s_init_bit;
  localparam s_idle_bit      = 1;  localparam s_idle      = 1 << s_idle_bit;
  localparam s_activate_bit  = 2;  localparam s_activate  = 1 << s_activate_bit;
  localparam s_read_1_bit    = 3;  localparam s_read_1    = 1 << s_read_1_bit;
  localparam s_read_2_bit    = 4;  localparam s_read_2    = 1 << s_read_2_bit;
  localparam s_read_3_bit    = 5;  localparam s_read_3    = 1 << s_read_3_bit;
  localparam s_read_4_bit    = 6;  localparam s_read_4    = 1 << s_read_4_bit;
  localparam s_write_1_bit   = 7;  localparam s_write_1   = 1 << s_write_1_bit;
  localparam s_idle_in_6_bit = 8;  localparam s_idle_in_6 = 1 << s_idle_in_6_bit;
  localparam s_idle_in_5_bit = 9;  localparam s_idle_in_5 = 1 << s_idle_in_5_bit;
  localparam s_idle_in_4_bit = 10; localparam s_idle_in_4 = 1 << s_idle_in_4_bit;
  localparam s_idle_in_3_bit = 11; localparam s_idle_in_3 = 1 << s_idle_in_3_bit;
  localparam s_idle_in_2_bit = 12; localparam s_idle_in_2 = 1 << s_idle_in_2_bit;
  localparam s_idle_in_1_bit = 13; localparam s_idle_in_1 = 1 << s_idle_in_1_bit;
  // Burst-specific states
  localparam s_burst_act_bit = 14; localparam s_burst_act = 1 << s_burst_act_bit;
  localparam s_burst_rd_bit  = 15; localparam s_burst_rd  = 1 << s_burst_rd_bit;
  localparam s_burst_drn_bit = 16; localparam s_burst_drn = 1 << s_burst_drn_bit;
  localparam s_burst_pre_bit = 17; localparam s_burst_pre = 1 << s_burst_pre_bit;

  (* onehot *)
  reg [17:0] state = s_init;

  reg [14:0] reset_counter = sdram_startup_cycles;
  reg  [7:0] refresh_counter = 0;
  reg        refresh_pending = 1;
  reg        rd_sticky  = 0;
  reg  [3:0] wmask_sticky = 4'b0000;

  // Burst state
  reg [8:0]  burst_remaining;
  reg [7:0]  burst_col;
  reg [2:0]  cas_pipe;

  // Busy: identical to original — clears on s_read_4 and s_write_1
  wire stillatwork = ~(state[s_read_4_bit] | state[s_write_1_bit]);
  wire [8:0] refresh_counterN = refresh_counter - 1;

  always @(posedge clk)
    if(!resetn) begin
      state          <= s_init;
      reset_counter  <= sdram_startup_cycles;
      busy           <= 0;
      rd_sticky      <= 0;
      wmask_sticky   <= 4'b0000;
      burst_valid    <= 0;
      burst_done     <= 0;
      burst_busy     <= 0;
      cas_pipe       <= 0;
      sd_data_drive  <= 0;
      refresh_pending<= 1;
      refresh_counter<= 0;
    end else begin

      // Busy logic — IDENTICAL to original
      busy      <= ((|wmask) | rd) | (busy         &    stillatwork   );
      rd_sticky <=             rd  | (rd_sticky    &    stillatwork   );
      wmask_sticky <=    wmask     | (wmask_sticky & {4{stillatwork}} );

      refresh_counter <= refresh_counterN[8] ? sdram_refresh_cycles : refresh_counterN[7:0];
      refresh_pending <= (refresh_pending & ~state[s_idle_bit]) | refresh_counterN[8];

      // Burst one-cycle pulses
      burst_valid <= 0;
      burst_done  <= 0;

      // Latch burst request
      if (burst_rd && !burst_busy)
        burst_busy <= 1;

      (* parallel_case *)
      case(1'b1)

        // ======== INIT (unchanged) ========
        state[s_init_bit]: begin
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
          if (reset_counter == 0) state <= s_idle;
        end

        // ======== IDLE COUNTDOWN (unchanged) ========
        state[s_idle_in_6_bit]: begin state <= s_idle_in_5; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        state[s_idle_in_5_bit]: begin state <= s_idle_in_4; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        state[s_idle_in_4_bit]: begin state <= s_idle_in_3; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        state[s_idle_in_3_bit]: begin state <= s_idle_in_2; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        state[s_idle_in_2_bit]: begin state <= s_idle_in_1; {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end
        state[s_idle_in_1_bit]: begin state <= s_idle;      {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP; end

        // ======== IDLE: priority = refresh > burst > single ========
        state[s_idle_bit]: begin
          sd_ba   <= addr[22:21];
          sd_addr <= {2'b00, addr[20:10]};

          if (refresh_pending) begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_AUTO_REFRESH;
            state <= s_idle_in_2;
          end else if (burst_busy) begin
            // Start burst read
            sd_ba   <= burst_addr[22:21];
            sd_addr <= {2'b00, burst_addr[20:10]};
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_ACTIVE;
            burst_col       <= burst_addr[9:2];
            burst_remaining <= burst_len;
            cas_pipe        <= 0;
            state           <= s_burst_act;
          end else if ((|wmask_sticky) | rd_sticky) begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_ACTIVE;
            state <= s_activate;
          end else begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          end
        end

        // ======== SINGLE-WORD READ/WRITE (unchanged) ========
        state[s_activate_bit]: begin
          sd_data_drive <= ~rd_sticky;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          state <= rd_sticky ? s_read_1 : s_write_1;
        end

        state[s_read_1_bit]: begin
          sd_dqm <= 4'b0000;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_READ;
          sd_addr <= {3'b001, 2'b00, addr[9:2]};
          state <= s_read_2;
        end

        state[s_read_2_bit]: begin
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          state <= s_read_3;
        end

        state[s_read_3_bit]: state <= s_read_4;

        state[s_read_4_bit]: begin
          dout  <= sd_data_in;
          state <= s_idle;
        end

        state[s_write_1_bit]: begin
          sd_addr     <= {3'b001, 2'b00, addr[9:2]};
          sd_data_out <= din;
          sd_dqm      <= ~wmask_sticky;
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_WRITE;
          state <= s_idle_in_2;
        end

        // ======== BURST READ ========
        state[s_burst_act_bit]: begin
          // tRCD wait
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          sd_dqm <= 4'b0000;
          sd_data_drive <= 0;
          state <= s_burst_rd;
        end

        state[s_burst_rd_bit]: begin
          // Advance CAS pipeline (3 stages for CAS2 + input register)
          cas_pipe <= {cas_pipe[1:0], 1'b0};

          if (burst_remaining > 0) begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_READ;
            sd_addr <= {3'b000, 2'b00, burst_col};  // A10=0, no auto-precharge
            burst_col <= burst_col + 1;
            burst_remaining <= burst_remaining - 1;
            cas_pipe[0] <= 1'b1;
          end else begin
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          end

          // Capture data from pipeline
          if (cas_pipe[2]) begin
            burst_dout  <= sd_data_in;
            burst_valid <= 1;
          end

          // All READs issued and pipeline draining
          if (burst_remaining == 0 && !cas_pipe[0] && !cas_pipe[1]) begin
            state <= s_burst_drn;
          end
        end

        state[s_burst_drn_bit]: begin
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          cas_pipe <= {cas_pipe[1:0], 1'b0};

          if (cas_pipe[2]) begin
            burst_dout  <= sd_data_in;
            burst_valid <= 1;
          end

          if (cas_pipe == 3'b000) begin
            // Precharge all banks
            {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_PRECHARGE;
            sd_addr <= 13'b0010000000000;
            state <= s_burst_pre;
          end
        end

        state[s_burst_pre_bit]: begin
          {sd_cs, sd_ras, sd_cas, sd_we} <= CMD_NOP;
          burst_done <= 1;
          burst_busy <= 0;
          state <= s_idle_in_2;  // tRP recovery
        end

      endcase
   end

endmodule
