
// sdram_arbiter.v — Two-master arbiter for muchtoremember_burst
//
// Masters:
//   Port 0 (video): burst-read only, strict display timing.
//   Port 1 (cpu):   single-word read/write via sdram_cache.
//
// Arbitration policy:
//   - An in-progress transaction is never preempted.
//   - When both masters are pending and the controller is idle, video wins.
//   - The arbiter latches CPU requests so a one-cycle sdram_rd pulse from
//     the cache is not lost if the controller is temporarily busy.
//   - Video's burst_rd is expected to be held high until accepted (the
//     video_fetch_engine already does this — it checks burst_busy before
//     asserting burst_rd, so burst_rd is a level that means "I want a burst"
//     rather than a one-cycle pulse).  The arbiter accepts it when idle.
//
// CPU stall:
//   The sdram_cache module watches sdram_busy.  We expose cpu_busy = 1
//   whenever the CPU cannot make forward progress: burst in progress,
//   controller initialising, or a CPU transaction is in flight.
//   The cache's internal wait_cnt is not disturbed — it counts down from
//   when its own sdram_rd is forwarded to the controller.
//
// Connecting in femtosoc.v:
//   Replace the direct cache <-> muchtoremember wires with:
//     sdram_arbiter arb (
//       .clk, .resetn,
//       .vid_burst_*   <- video_fetch_engine
//       .cpu_wmask     <- cache_sdram_wmask
//       .cpu_rd        <- cache_sdram_rd
//       .cpu_addr      <- cache_sdram_addr
//       .cpu_din       <- cache_sdram_din
//       .cpu_dout      -> cache_sdram_dout
//       .cpu_busy      -> cache_sdram_busy
//       .ctrl_*        <-> muchtoremember_burst
//     );

module sdram_arbiter (
    input  wire        clk,
    input  wire        resetn,

    // ---- Video port (burst reads only) ----
    input  wire        vid_burst_rd,    // Level: hold high until accepted
    input  wire [25:0] vid_burst_addr,
    input  wire  [8:0] vid_burst_len,
    output wire [31:0] vid_burst_dout,
    output wire        vid_burst_valid,
    output wire        vid_burst_busy,

    // ---- CPU port (single-word read/write, from/to sdram_cache) ----
    input  wire  [3:0] cpu_wmask,       // One-cycle pulse from cache
    input  wire        cpu_rd,          // One-cycle pulse from cache
    input  wire [25:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    output reg         cpu_busy,

    // ---- SDRAM controller (muchtoremember_burst) ----
    output reg   [3:0] ctrl_wmask,
    output reg         ctrl_rd,
    output reg  [25:0] ctrl_addr,
    output reg  [31:0] ctrl_din,
    input  wire [31:0] ctrl_dout,
    input  wire        ctrl_busy,

    output reg         ctrl_burst_rd,
    output reg  [25:0] ctrl_burst_addr,
    output reg   [8:0] ctrl_burst_len,
    input  wire [31:0] ctrl_burst_dout,
    input  wire        ctrl_burst_valid,
    input  wire        ctrl_burst_busy
);

    // Video burst outputs pass straight through
    assign vid_burst_dout  = ctrl_burst_dout;
    assign vid_burst_valid = ctrl_burst_valid;
    assign vid_burst_busy  = ctrl_burst_busy;

    // CPU read data passes straight through
    assign cpu_dout = ctrl_dout;

    // -------------------------------------------------------------------------
    // Grant state machine
    // -------------------------------------------------------------------------
    localparam GRANT_NONE  = 2'd0;
    localparam GRANT_VIDEO = 2'd1;
    localparam GRANT_CPU   = 2'd2;

    reg [1:0] grant = GRANT_NONE;

    // Latch for CPU requests that arrived while the controller was busy
    reg        cpu_rd_pending    = 0;
    reg  [3:0] cpu_wmask_pending = 0;
    reg [25:0] cpu_addr_pending  = 0;
    reg [31:0] cpu_din_pending   = 0;

    // Effective CPU request: either live or latched
    wire        cpu_req   = cpu_rd | (|cpu_wmask) | cpu_rd_pending | (|cpu_wmask_pending);
    wire        cpu_rd_e  = cpu_rd    | cpu_rd_pending;
    wire  [3:0] cpu_wm_e  = cpu_wmask | cpu_wmask_pending;
    wire [25:0] cpu_addr_e = cpu_rd ? cpu_addr : (|cpu_wmask) ? cpu_addr : cpu_addr_pending;
    wire [31:0] cpu_din_e  = cpu_rd ? cpu_din  : (|cpu_wmask) ? cpu_din  : cpu_din_pending;

    wire ctrl_free = !ctrl_busy && !ctrl_burst_busy;

    always @(posedge clk) begin
        if (!resetn) begin
            grant            <= GRANT_NONE;
            ctrl_burst_rd    <= 0;
            ctrl_rd          <= 0;
            ctrl_wmask       <= 0;
            cpu_busy         <= 0;
            cpu_rd_pending   <= 0;
            cpu_wmask_pending <= 0;
        end else begin

            // Defaults: one-cycle pulse signals deasserted
            ctrl_burst_rd <= 0;
            ctrl_rd       <= 0;
            ctrl_wmask    <= 0;

            // Latch incoming CPU requests to avoid losing one-cycle pulses
            if (cpu_rd)          begin cpu_rd_pending    <= 1;        cpu_addr_pending <= cpu_addr; cpu_din_pending <= cpu_din; end
            if (|cpu_wmask)      begin cpu_wmask_pending <= cpu_wmask; cpu_addr_pending <= cpu_addr; cpu_din_pending <= cpu_din; end

            case (grant)

                // ----------------------------------------------------------
                // GRANT_NONE: controller idle, pick the next requester
                // ----------------------------------------------------------
                GRANT_NONE: begin
                    cpu_busy <= 0;

                    if (ctrl_free) begin
                        if (vid_burst_rd) begin
                            // Video wins when both pending
                            ctrl_burst_rd   <= 1;
                            ctrl_burst_addr <= vid_burst_addr;
                            ctrl_burst_len  <= vid_burst_len;
                            grant           <= GRANT_VIDEO;
                            // Stall CPU during burst
                            cpu_busy <= 1;

                        end else if (cpu_req) begin
                            // Grant CPU
                            ctrl_rd    <= cpu_rd_e;
                            ctrl_wmask <= cpu_wm_e;
                            ctrl_addr  <= cpu_addr_e;
                            ctrl_din   <= cpu_din_e;
                            // Clear latched request
                            cpu_rd_pending    <= 0;
                            cpu_wmask_pending <= 0;
                            grant    <= GRANT_CPU;
                            cpu_busy <= 1;
                        end

                    end else begin
                        // Controller not free yet: stall CPU if it is requesting
                        if (vid_burst_rd || cpu_req) cpu_busy <= 1;
                    end
                end

                // ----------------------------------------------------------
                // GRANT_VIDEO: burst in progress, CPU stalled
                // ----------------------------------------------------------
                GRANT_VIDEO: begin
                    cpu_busy <= 1;   // keep stalling CPU

                    if (!ctrl_burst_busy) begin
                        // Burst complete.  If CPU has a pending request, we
                        // can immediately transition to serve it; otherwise idle.
                        if (cpu_req) begin
                            ctrl_rd    <= cpu_rd_e;
                            ctrl_wmask <= cpu_wm_e;
                            ctrl_addr  <= cpu_addr_e;
                            ctrl_din   <= cpu_din_e;
                            cpu_rd_pending    <= 0;
                            cpu_wmask_pending <= 0;
                            grant <= GRANT_CPU;
                            // cpu_busy stays 1
                        end else begin
                            grant    <= GRANT_NONE;
                            cpu_busy <= 0;
                        end
                    end
                end

                // ----------------------------------------------------------
                // GRANT_CPU: single-word transaction in progress
                // ----------------------------------------------------------
                GRANT_CPU: begin
                    cpu_busy <= ctrl_busy;   // mirror controller busy to cache

                    if (!ctrl_busy) begin
                        // Transaction complete.
                        if (vid_burst_rd) begin
                            // Start video burst immediately
                            ctrl_burst_rd   <= 1;
                            ctrl_burst_addr <= vid_burst_addr;
                            ctrl_burst_len  <= vid_burst_len;
                            grant           <= GRANT_VIDEO;
                            cpu_busy        <= 1;
                        end else begin
                            grant    <= GRANT_NONE;
                            cpu_busy <= 0;
                        end
                    end
                end

                default: begin
                    grant    <= GRANT_NONE;
                    cpu_busy <= 0;
                end

            endcase
        end
    end

endmodule
