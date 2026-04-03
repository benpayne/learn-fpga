
// SDRAM interface for EM638325-6H on Colorlight i5
// 2Mx32 (64Mbit), 32-bit data bus, single access (no burst)
//
// Based on muchtoremember by Matthias Koch (January 2022)
// Modified for 32-bit data bus and EM638325 geometry:
//   4 banks × 2048 rows × 256 columns × 32 bits = 8MB
//
// Address mapping (from FemtoRV):
//   addr[1:0]   = byte within word (handled by wmask)
//   addr[8:2]   = 7-bit column command (A0-A6, giving 128 positions)
//                  With burst=1, full 256 columns need 8 command bits,
//                  but controller LSB is addr[2] so column = addr[9:2] = 8 bits
//   addr[20:9]  = 12-bit row (only 11 used: A0-A10)
//   addr[22:21] = 2-bit bank (BA0-BA1)

module muchtoremember (

  // Interface to SDRAM chip
  output             sd_clk,
  inout      [31:0]  sd_d,          // 32-bit bidirectional data
  output     [12:0]  sd_addr,       // Address bus (only A0-A10 connected)
  output      [1:0]  sd_ba,         // Bank select
  output      [3:0]  sd_dqm,        // Byte mask (4 bytes for 32-bit)
  output             sd_cs,
  output             sd_we,
  output             sd_ras,
  output             sd_cas,

  // Interface to processor
  input  clk,
  input  resetn,
  input  [3:0] wmask,
  input  rd,
  input  [25:0] addr,
  input  [31:0] din,
  output reg [31:0] dout,
  output reg busy,

  // Burst reader override — muxes command outputs when active
  input         ovr_active,
  input  [12:0] ovr_addr,
  input   [1:0] ovr_ba,
  input   [3:0] ovr_dqm,
  input         ovr_cs,
  input         ovr_we,
  input         ovr_ras,
  input         ovr_cas,

  // Data input exposed for burst reader
  output wire [31:0] sd_data_in_out
);

  // Internal command registers (state machine drives these)
  reg [12:0] int_sd_addr;
  reg  [1:0] int_sd_ba;
  reg  [3:0] int_sd_dqm;
  reg        int_sd_cs, int_sd_we, int_sd_ras, int_sd_cas;

  // Output: when override is active, the burst reader drives commands
  // directly into the output registers via the always block below.
  // When not active, the state machine drives them normally.
  assign sd_addr = int_sd_addr;
  assign sd_ba   = int_sd_ba;
  assign sd_dqm  = int_sd_dqm;
  assign sd_cs   = int_sd_cs;
  assign sd_we   = int_sd_we;
  assign sd_ras  = int_sd_ras;
  assign sd_cas  = int_sd_cas;

  parameter sdram_startup_cycles = 10100;
  parameter sdram_refresh_cycles = 195;

  assign sd_clk = ~clk;

  wire [31:0] sd_data_in;
  reg  [31:0] sd_data_out;
  reg         sd_data_drive;

  // Expose sd_data_in for burst reader
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

  // Configuration: burst length 1 (single 32-bit access)
  localparam NO_WRITE_BURST = 1'b0;
  localparam OP_MODE        = 2'b00;
  localparam CAS_LATENCY    = 3'd2;
  localparam ACCESS_TYPE    = 1'b0;
  localparam BURST_LENGTH   = 3'b000; // 000=1 (single access)

  localparam MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

  //                           CS, RAS, CAS, WE
  localparam CMD_INHIBIT         = 4'b1111;
  localparam CMD_NOP             = 4'b0111;
  localparam CMD_BURST_TERMINATE = 4'b0110;
  localparam CMD_READ            = 4'b0101;
  localparam CMD_WRITE           = 4'b0100;
  localparam CMD_ACTIVE          = 4'b0011;
  localparam CMD_PRECHARGE       = 4'b0010;
  localparam CMD_AUTO_REFRESH    = 4'b0001;
  localparam CMD_LOAD_MODE       = 4'b0000;

  // States
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

  (* onehot *)
  reg [13:0] state = s_init;

  reg [14:0] reset_counter = sdram_startup_cycles;
  reg  [7:0] refresh_counter = 0;
  reg        refresh_pending = 1;
  reg           rd_sticky  = 0;
  reg  [3:0] wmask_sticky  = 4'b0000;

  // Busy clears when read or write completes
  wire stillatwork = ~(state[s_read_4_bit] | state[s_write_1_bit]);
  wire [8:0] refresh_counterN = refresh_counter - 1;

  always @(posedge clk)
    if(!resetn) begin
      state         <= s_init;
      reset_counter <= sdram_startup_cycles;
      busy          <= 0;
      rd_sticky     <= 0;
      wmask_sticky  <= 4'b0000;
    end else begin

      busy      <= ((|wmask) | rd) | (busy         &    stillatwork   );
      rd_sticky <=             rd  | (rd_sticky    &    stillatwork   );
      wmask_sticky <=    wmask     | (wmask_sticky & {4{stillatwork}} );

      refresh_counter <= refresh_counterN[8] ? sdram_refresh_cycles : refresh_counterN[7:0];
      refresh_pending <= (refresh_pending & ~state[s_idle_bit]) | refresh_counterN[8];

      (* parallel_case *)
      case(1'b1)

        state[s_init_bit]: begin
          int_sd_ba  <= 2'b00;
          int_sd_dqm <= 4'b1111;
          sd_data_drive <= 0;

          case (reset_counter)
            33: begin int_sd_cs <= 0; end
            31: begin {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_PRECHARGE; int_sd_addr <= 13'b0010000000000; end
            23: begin {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_AUTO_REFRESH; end
            15: begin {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_AUTO_REFRESH; end
            7:  begin {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_LOAD_MODE; int_sd_addr <= MODE; end
            default: {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP;
          endcase

          reset_counter <= reset_counter - 1;
          if (reset_counter == 0) state <= s_idle;
        end

        state[s_idle_in_6_bit]: begin state <= s_idle_in_5; {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end
        state[s_idle_in_5_bit]: begin state <= s_idle_in_4; {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end
        state[s_idle_in_4_bit]: begin state <= s_idle_in_3; {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end
        state[s_idle_in_3_bit]: begin state <= s_idle_in_2; {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end
        state[s_idle_in_2_bit]: begin state <= s_idle_in_1; {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end
        state[s_idle_in_1_bit]: begin state <= s_idle;      {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP; end

        state[s_idle_bit]: begin
          // Row activate: bank and row address
          int_sd_ba                          <= addr[22:21];                  // Bank select
          int_sd_addr                        <= {2'b00, addr[20:10]} ;       // Row address (11 bits, A0-A10)

          {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= refresh_pending             ? CMD_AUTO_REFRESH :
                                            (|wmask_sticky) | rd_sticky ? CMD_ACTIVE :
                                                                          CMD_NOP;

          state                          <= refresh_pending             ? s_idle_in_2 :
                                            (|wmask_sticky) | rd_sticky ? s_activate :
                                                                          s_idle;
        end

        state[s_activate_bit]: begin
          sd_data_drive                  <= ~rd_sticky;
          {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP;
          state                          <= rd_sticky ? s_read_1 : s_write_1;
        end

        // ---- Read: single 32-bit access ----

        state[s_read_1_bit]: begin
          int_sd_dqm                         <= 4'b0000; // All bytes active
          {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_READ;
          int_sd_addr                        <= {3'b001, 2'b00, addr[9:2]}; // A10=auto-precharge, A7:A0=column
          state                          <= s_read_2;
        end

        state[s_read_2_bit]: begin
          {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_NOP;
          state                          <= s_read_3;
        end

        state[s_read_3_bit]: state       <= s_read_4;

        // Busy clears here:
        state[s_read_4_bit]: begin
          dout                           <= sd_data_in; // All 32 bits at once
          state                          <= s_idle;
        end

        // ---- Write: single 32-bit access ----

        // Busy clears here:
        state[s_write_1_bit]: begin
          int_sd_addr                        <= {3'b001, 2'b00, addr[9:2]}; // A10=auto-precharge, A7:A0=column
          sd_data_out                    <= din;
          int_sd_dqm                         <= ~wmask_sticky;  // 4-bit byte mask
          {int_sd_cs, int_sd_ras, int_sd_cas, int_sd_we} <= CMD_WRITE;
          state                          <= s_idle_in_2;
        end

      endcase

      // Burst override: when active, the burst reader takes over the command
      // registers. The state machine is forced to IDLE so it doesn't issue
      // conflicting commands. When override ends, the state machine resumes
      // cleanly from IDLE.
      if (ovr_active) begin
         int_sd_addr <= ovr_addr;
         int_sd_ba   <= ovr_ba;
         int_sd_dqm  <= ovr_dqm;
         int_sd_cs   <= ovr_cs;
         int_sd_we   <= ovr_we;
         int_sd_ras  <= ovr_ras;
         int_sd_cas  <= ovr_cas;
         sd_data_drive <= 0;
         // Force state machine to IDLE — when override ends, it resumes clean
         state <= s_idle;
         busy <= 0;
         rd_sticky <= 0;
         wmask_sticky <= 0;
      end

   end

endmodule
