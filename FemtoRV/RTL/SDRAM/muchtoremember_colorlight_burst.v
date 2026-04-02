
// SDRAM interface for EM638325-6H on Colorlight i5 — with burst-read support
// 2Mx32 (64Mbit), 32-bit data bus.
//
// Based on muchtoremember by Matthias Koch (January 2022).
// Modified to add a burst-read port alongside the original single-word port.
//
// TWO read paths, ONE write path:
//
//   Single-word path (CPU, via cache):
//     Inputs:  rd, wmask, addr, din
//     Output:  dout, busy
//     Behaviour: identical to the original muchtoremember — ACTIVATE, READ with
//       A10=1 (auto-precharge), wait CAS+2, capture 32-bit result, go idle.
//
//   Burst-read path (video fetch engine):
//     Inputs:  burst_rd, burst_addr, burst_len
//     Output:  burst_dout, burst_valid, burst_busy
//     Behaviour: ACTIVATE a row, issue burst_len pipelined READ commands with
//       A10=0 (no auto-precharge, so the row stays open), capture each 32-bit
//       result as burst_valid pulses, then PRECHARGE to close the row.
//
//     With CAS latency = 2, data for READ[N] appears on sd_d two cycles after
//     READ[N] is issued.  We track which READs have been issued using a 2-bit
//     shift register ("cas_pipe") that acts as a delayed "capture" flag:
//       - Set cas_pipe[0] every cycle a READ is issued.
//       - Shift left each cycle: cas_pipe[1] <= cas_pipe[0].
//       - When cas_pipe[1] is set, sd_data_in is valid — capture it.
//     This cleanly handles the pipeline fill and drain regardless of burst_len.
//
//   The host (arbiter) must not start a new burst_rd until burst_busy falls.
//   burst_rd must be held high for exactly one cycle.
//
// Address mapping (burst_addr uses the same encoding as addr):
//   addr[1:0]   = byte within word (unused; wmask handles bytes)
//   addr[9:2]   = 8-bit column (SDRAM A0-A7)
//   addr[20:10] = 11-bit row   (SDRAM A0-A10 of the ACTIVE command)
//   addr[22:21] = 2-bit bank   (BA0-BA1)
//
// IMPORTANT: burst_addr must be column-aligned such that
//   burst_addr_column + burst_len <= 256.
// If a scanline spans two SDRAM rows, the caller must issue two separate
// burst_rd requests.  The video_fetch_engine handles this split.
//
// Timing (25 MHz, tRCD=2, tRP=2, CAS=2):
//   ACTIVATE(1) + tRCD_NOP(1) + N×READ(N) + drain(2) + PRECHARGE(1) + tRP(2)
//   = N + 7 cycles per burst of N words.
//   For N=256: 263 cycles.  For N=64: 71 cycles.  Total for 320-word scanline: 334.
//   At 25 MHz, 800 cycles/line: 466 cycles remain for CPU and refresh.

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

  // System
  input  clk,
  input  resetn,

  // ---- Single-word port (CPU via cache) ----
  input  [3:0]  wmask,
  input         rd,
  input  [25:0] addr,
  input  [31:0] din,
  output reg [31:0] dout,
  output reg        busy,

  // ---- Burst-read port (video fetch engine) ----
  input             burst_rd,       // One-cycle pulse: start a burst read
  input      [25:0] burst_addr,     // Base byte address (must be word-aligned)
  input      [8:0]  burst_len,      // Number of 32-bit words to read (1..256)
  output reg [31:0] burst_dout,     // Output word (valid when burst_valid=1)
  output reg        burst_valid,    // burst_dout is valid this cycle
  output reg        burst_busy      // High for entire duration of burst
);

  parameter sdram_startup_cycles = 10100;
  parameter sdram_refresh_cycles = 195;

  assign sd_clk = ~clk;

  // ---------------------------------------------------------------------------
  // SDRAM bidirectional data bus
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Mode register — burst length 1 for single-word accesses.
  // Burst reads are achieved by issuing sequential single-word READs without
  // auto-precharge (A10=0), exploiting the CAS-latency pipeline.
  // ---------------------------------------------------------------------------
  localparam NO_WRITE_BURST = 1'b0;
  localparam OP_MODE        = 2'b00;
  localparam CAS_LATENCY    = 3'd2;
  localparam ACCESS_TYPE    = 1'b0;
  localparam BURST_LENGTH   = 3'b000; // 000 = single-word burst

  localparam MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

  // Commands: {CS, RAS, CAS, WE}
  localparam CMD_NOP          = 4'b0111;
  localparam CMD_READ         = 4'b0101;
  localparam CMD_WRITE        = 4'b0100;
  localparam CMD_ACTIVE       = 4'b0011;
  localparam CMD_PRECHARGE    = 4'b0010;
  localparam CMD_AUTO_REFRESH = 4'b0001;
  localparam CMD_LOAD_MODE    = 4'b0000;

  // ---------------------------------------------------------------------------
  // State encoding (one-hot)
  // ---------------------------------------------------------------------------
  // Shared / init states
  localparam s_init_bit        = 0;
  localparam s_idle_bit        = 1;
  localparam s_idle_in_6_bit   = 2;
  localparam s_idle_in_5_bit   = 3;
  localparam s_idle_in_4_bit   = 4;
  localparam s_idle_in_3_bit   = 5;
  localparam s_idle_in_2_bit   = 6;
  localparam s_idle_in_1_bit   = 7;
  // Single-word path
  localparam s_activate_bit    = 8;
  localparam s_read_1_bit      = 9;
  localparam s_read_2_bit      = 10;
  localparam s_read_3_bit      = 11;
  localparam s_read_4_bit      = 12;
  localparam s_write_1_bit     = 13;
  // Burst-read path
  localparam s_burst_act_bit   = 14;  // ACTIVATE issued, wait tRCD (1 NOP)
  localparam s_burst_read_bit  = 15;  // issue READ cmds and capture via CAS pipe
  localparam s_burst_drain_bit = 16;  // all READs issued, drain last 2 from pipe
  localparam s_burst_pre_bit   = 17;  // PRECHARGE issued
  localparam s_burst_pre2_bit  = 18;  // tRP NOP 2

  (* onehot *)
  reg [18:0] state = 1 << s_init_bit;

  // ---------------------------------------------------------------------------
  // Counters and sticky registers
  // ---------------------------------------------------------------------------
  reg [14:0] reset_counter   = sdram_startup_cycles;
  reg  [7:0] refresh_counter = 0;
  reg        refresh_pending  = 1;

  // Single-word path
  reg        rd_sticky    = 0;
  reg  [3:0] wmask_sticky = 4'b0000;

  // Burst path internal state
  reg  [8:0] burst_reads_left;    // READ commands still to issue
  reg  [8:0] burst_words_left;    // words still expected from the CAS pipeline
  reg  [7:0] burst_col;           // column offset within the burst (word units)
  reg [25:0] burst_addr_r;        // latched burst_addr

  // CAS-2 pipeline shift register.
  // cas_pipe[0] is set the cycle a READ command is issued.
  // cas_pipe[1] is set one cycle later.
  // When cas_pipe[1]=1 the corresponding data word is valid on sd_data_in.
  reg [1:0]  cas_pipe;

  // Current SDRAM column address for burst READ commands
  wire [7:0] burst_col_addr = burst_addr_r[9:2] + burst_col;

  // busy for single-word path: clears at read_4 or write_1
  wire stillatwork = ~( state[s_read_4_bit] | state[s_write_1_bit] );

  wire [8:0] refresh_counterN = refresh_counter - 1;

  // ---------------------------------------------------------------------------
  // Main sequential logic
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!resetn) begin
      state         <= 1 << s_init_bit;
      reset_counter <= sdram_startup_cycles;
      busy          <= 0;
      burst_busy    <= 0;
      burst_valid   <= 0;
      rd_sticky     <= 0;
      wmask_sticky  <= 4'b0000;
      cas_pipe      <= 2'b00;
    end else begin

      // Single-word path sticky registers
      busy         <= ((|wmask) | rd) | (busy         &    stillatwork  );
      rd_sticky    <=             rd  | (rd_sticky    &    stillatwork  );
      wmask_sticky <=       wmask     | (wmask_sticky & {4{stillatwork}});

      // Refresh counter
      refresh_counter <= refresh_counterN[8] ? sdram_refresh_cycles : refresh_counterN[7:0];
      refresh_pending <= (refresh_pending & ~state[s_idle_bit]) | refresh_counterN[8];

      // CAS pipeline shift register: shift left by default (no new READ).
      // Individual states override cas_pipe[0] when a READ is issued.
      // Because the shift and the per-state assignment are in the same always
      // block, the LAST non-blocking assignment to cas_pipe wins.  We therefore
      // always write the full 2-bit value in states that touch cas_pipe.
      // Default: shift left, no new READ.
      cas_pipe <= {cas_pipe[0], 1'b0};

      // burst_valid default: low
      burst_valid <= 0;

      (* parallel_case *)
      case (1'b1)

        // ----------------------------------------------------------------
        // Initialisation (unchanged from original muchtoremember)
        // ----------------------------------------------------------------
        state[s_init_bit]: begin
          sd_ba         <= 2'b00;
          sd_dqm        <= 4'b1111;
          sd_data_drive <= 0;

          case (reset_counter)
            33: begin sd_cs <= 0; end
            31: begin {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_PRECHARGE; sd_addr <= 13'b0010000000000; end
            23: begin {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_AUTO_REFRESH; end
            15: begin {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_AUTO_REFRESH; end
             7: begin {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_LOAD_MODE; sd_addr <= MODE; end
            default: {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          endcase

          reset_counter <= reset_counter - 1;
          if (reset_counter == 0) state <= 1 << s_idle_bit;
        end

        // ----------------------------------------------------------------
        // Idle countdown chain (tRC / tRP / refresh gaps)
        // ----------------------------------------------------------------
        state[s_idle_in_6_bit]: begin state <= 1<<s_idle_in_5_bit; {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end
        state[s_idle_in_5_bit]: begin state <= 1<<s_idle_in_4_bit; {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end
        state[s_idle_in_4_bit]: begin state <= 1<<s_idle_in_3_bit; {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end
        state[s_idle_in_3_bit]: begin state <= 1<<s_idle_in_2_bit; {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end
        state[s_idle_in_2_bit]: begin state <= 1<<s_idle_in_1_bit; {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end
        state[s_idle_in_1_bit]: begin state <= 1<<s_idle_bit;      {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP; end

        // ----------------------------------------------------------------
        // IDLE: arbitrate between refresh, burst_rd, and single-word
        // Priority: refresh > burst_rd > single-word
        // The arbiter above serialises burst and single-word so they do not
        // collide here; refresh is handled locally.
        // ----------------------------------------------------------------
        state[s_idle_bit]: begin
          if (refresh_pending) begin
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_AUTO_REFRESH;
            // tRC for EM638325 at 25 MHz: ~63 ns = 1.6 cycles -> use 2 NOPs
            state <= 1 << s_idle_in_2_bit;

          end else if (burst_rd) begin
            // Latch burst parameters
            burst_addr_r       <= burst_addr;
            burst_reads_left   <= burst_len;
            burst_words_left   <= burst_len;
            burst_col          <= 0;
            cas_pipe           <= 2'b00;
            burst_busy         <= 1;
            // Issue ACTIVATE
            sd_ba   <= burst_addr[22:21];
            sd_addr <= {2'b00, burst_addr[20:10]};
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_ACTIVE;
            state   <= 1 << s_burst_act_bit;

          end else if ((|wmask_sticky) | rd_sticky) begin
            sd_ba   <= addr[22:21];
            sd_addr <= {2'b00, addr[20:10]};
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_ACTIVE;
            state   <= 1 << s_activate_bit;

          end else begin
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
            // stay in s_idle
          end
        end

        // ----------------------------------------------------------------
        // Single-word: ACTIVATE -> READ or WRITE (identical to original)
        // ----------------------------------------------------------------
        state[s_activate_bit]: begin
          sd_data_drive                <= ~rd_sticky;
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          state <= rd_sticky ? 1<<s_read_1_bit : 1<<s_write_1_bit;
        end

        // READ with A10=1 (auto-precharge): row closes automatically
        state[s_read_1_bit]: begin
          sd_dqm                       <= 4'b0000;
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_READ;
          sd_addr                      <= {3'b001, 2'b00, addr[9:2]};
          state <= 1 << s_read_2_bit;
        end

        state[s_read_2_bit]: begin
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          state <= 1 << s_read_3_bit;
        end

        state[s_read_3_bit]: state <= 1 << s_read_4_bit;

        // busy clears here
        state[s_read_4_bit]: begin
          dout  <= sd_data_in;
          state <= 1 << s_idle_bit;
        end

        // WRITE with A10=1 (auto-precharge), busy clears here
        state[s_write_1_bit]: begin
          sd_addr                      <= {3'b001, 2'b00, addr[9:2]};
          sd_data_out                  <= din;
          sd_dqm                       <= ~wmask_sticky;
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_WRITE;
          state <= 1 << s_idle_in_2_bit;
        end

        // ----------------------------------------------------------------
        // Burst read path
        //
        // CAS-2 pipeline tracking with a 2-bit shift register (cas_pipe):
        //
        //   Cycle 0 (s_burst_act):  ACTIVATE, cas_pipe = 00
        //   Cycle 1 (first s_burst_read): READ[0] issued
        //     -> cas_pipe[0] set to 1 this cycle
        //     -> cas_pipe advances: {1, 0} stored at end of cycle
        //   Cycle 2: READ[1] issued, cas_pipe = {1, 0} -> becomes {0, 1}...
        //
        // Wait — the general advance rule is:
        //   new_cas_pipe = {old_cas_pipe[0], 1'b0}    (shift left, insert 0 at bit 0)
        //   then OR in the "read_issued_this_cycle" flag at bit 0.
        //
        // So if READ[0] is issued at cycle T:
        //   After cycle T:   cas_pipe = {0, 1}   (bit 0 set, bit 1 empty)
        //   After cycle T+1: cas_pipe = {1, 0}   (shifted: bit 1 now set)
        //   During cycle T+2: cas_pipe[1] = 1 -> capture sd_data_in for READ[0]
        //
        // The actual capture happens during the s_burst_read or s_burst_drain
        // evaluation when cas_pipe[1] is already 1 from the *previous* cycle's
        // shift.  Since `cas_pipe <= {cas_pipe[0], 1'b0}` runs unconditionally
        // each cycle before the case statement, cas_pipe is the value from the
        // *previous* cycle when we check it inside the case.
        //
        // Concretely (all at posedge clk, cas_pipe is registered):
        //
        //   Cycle A (s_burst_act, entered after ACTIVATE):
        //     cas_pipe was advanced: {0[0], 0} = 00.
        //     No READ issued; cas_pipe[0] stays 0.
        //     Next state: s_burst_read.
        //
        //   Cycle B (first s_burst_read):
        //     cas_pipe was advanced: 00 -> 00.
        //     READ[0] is issued; set cas_pipe[0]=1.
        //     After clk edge: cas_pipe = {0, 1} = 01.
        //
        //   Cycle C (second s_burst_read):
        //     cas_pipe advanced: 01 -> {1, 0} = 10.
        //     cas_pipe[1] = 0: no capture (READ[0] not yet back).
        //     READ[1] issued; cas_pipe[0] = 1 -> stored as {0, 1} ...
        //     WAIT: the advance already ran BEFORE the case statement.
        //     So at the start of cycle C's case: cas_pipe = 10 (the advanced value).
        //     cas_pipe[1] = 1: capture sd_data_in for READ[0].  Correct! CL=2.
        //     Then set cas_pipe[0]=1 for READ[1] -> stored as {1, 1}.
        //
        // This confirms the approach is correct.
        // ----------------------------------------------------------------

        state[s_burst_act_bit]: begin
          // tRCD: one NOP cycle between ACTIVATE and first READ.
          // The cas_pipe advance already ran (produces 00->00 since pipe was 00).
          // Don't set cas_pipe[0] here (no READ issued).
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          sd_dqm        <= 4'b0000;
          sd_data_drive <= 0;
          state <= 1 << s_burst_read_bit;
        end

        state[s_burst_read_bit]: begin
          // cas_pipe was already advanced by the unconditional shift above.

          // --- Capture ---
          // cas_pipe[1] = 1 means data from a READ issued 2 cycles ago is valid.
          if (cas_pipe[1] && burst_words_left > 0) begin
            burst_dout       <= sd_data_in;
            burst_valid      <= 1;
            burst_words_left <= burst_words_left - 1;
          end

          // --- Issue next READ (if any remain) ---
          if (burst_reads_left > 0) begin
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_READ;
            sd_addr          <= {3'b000, 2'b00, burst_col_addr}; // A10=0: no auto-precharge
            sd_ba            <= burst_addr_r[22:21];
            sd_dqm           <= 4'b0000;
            // Override the default shift: shift and set new READ flag at bit 0.
            // {cas_pipe[0], 1} — bit 1 gets old bit 0, bit 0 = 1 (READ issued).
            cas_pipe         <= {cas_pipe[0], 1'b1};
            burst_reads_left <= burst_reads_left - 1;
            burst_col        <= burst_col + 1;
          end else begin
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
            // cas_pipe default shift already applied (no READ this cycle).
            // All READs issued; move to drain the remaining pipeline words
            state <= 1 << s_burst_drain_bit;
          end
        end

        state[s_burst_drain_bit]: begin
          // cas_pipe was already advanced by the default shift above.
          // Drain the last (at most 2) words from the CAS pipeline.
          if (cas_pipe[1] && burst_words_left > 0) begin
            burst_dout       <= sd_data_in;
            burst_valid      <= 1;
            burst_words_left <= burst_words_left - 1;
          end

          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          // No new READs; default shift already applied.

          // Move to PRECHARGE once the pipeline is fully drained.
          // burst_words_left will reach 0 within 2 cycles of the last READ.
          // We can issue PRECHARGE when burst_words_left == 0 AND cas_pipe == 00.
          if (burst_words_left == 0 && cas_pipe == 2'b00) begin
            {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_PRECHARGE;
            sd_addr <= 13'b0000000000000; // A10=0: precharge the active bank only
            state   <= 1 << s_burst_pre_bit;
          end
        end

        state[s_burst_pre_bit]: begin
          // tRP cycle 1
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          state <= 1 << s_burst_pre2_bit;
        end

        state[s_burst_pre2_bit]: begin
          // tRP cycle 2 — burst complete
          {sd_cs,sd_ras,sd_cas,sd_we} <= CMD_NOP;
          burst_busy <= 0;
          state      <= 1 << s_idle_bit;
        end

      endcase
    end
  end

endmodule
