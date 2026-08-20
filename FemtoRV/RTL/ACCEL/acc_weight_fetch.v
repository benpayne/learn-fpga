// acc_weight_fetch.v -- burst-read orchestrator feeding acc_mac's FIFO
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 3.2 (block diagram), section 3.3
// (why a FIFO), and section 9a ("Reusing the existing video/SDRAM path").
// Modelled directly on FemtoRV/RTL/SDRAM/video_fetch_engine.v, which already
// does burst-request + FIFO-feed correctly and is proven in hardware; this
// module is that structure with a weight-matrix address pattern instead of
// a scanline one.
//
// Q8_0 stores weights and scales as TWO SEPARATE CONTIGUOUS BLOCKS, not
// interleaved (data-model.md entity 1/2, research R1). So this module takes
// two independent base addresses and runs two phases per operation:
//   1. Scale prefetch: read the small `s` block (d*n/gs fp32 values) into
//      the scale BRAM. Small -- 1.5% of the data at GS=64 (data-model.md
//      entity 2).
//   2. Weight stream: read the dense `q` block (d*n int8 values, 4/word)
//      into the weight FIFO at full burst rate, decoupling SDRAM bursts
//      (with gaps) from acc_mac's one-word/cycle appetite.
// The two streams MUST NOT be interleaved so the inner loop stays
// single-source at full lane rate (data-model.md entity 2, "Rules"). This
// module enforces that by construction: phase 2 (S_Q_*) cannot begin until
// phase 1's word count has reached zero, and there is exactly one active
// burst target (either w_s_base+offset or w_q_base+offset) at any time.
//
// Word-count arithmetic assumes upstream validation (acc_regs/acc_top,
// FR-009) has already rejected any descriptor where `gs` is not a power of
// two dividing `n`; this module does not re-validate. n*d/gs is computed as
// (n>>log2(gs))*d, which is exact for a valid descriptor. n*d/4 (the q word
// count) is exact because gs>=4 in every supported configuration (see
// acc_regs.v's GS_MIN), so n is always a multiple of 4.
//
// Drives FemtoRV/RTL/SDRAM/muchtoremember_burst.v's burst read port
// unchanged (DESIGN.md sec 9a: "Use it unchanged"). Read-only -- there is
// no burst write port; results go to the result BRAM instead (acc_top).
//
// Abort: muchtoremember_burst.v offers no mid-burst cancel (bursts are
// atomic once launched -- DESIGN.md sec 9a). On `abort`, this module stops
// issuing further burst_rd requests immediately; if a burst is already in
// flight it is drained (its words are silently discarded -- fifo_wen/
// scale_wen are gated off by FSM state) rather than written, and the FSM
// returns to IDLE as soon as that burst completes. This bounds abort
// latency to at most one outstanding burst (BURST_LEN words plus the
// controller's fixed setup/drain overhead), satisfying the contract's
// "bounded time" requirement. This module does not own the weight FIFO's
// storage (only its wdata/wen/room handshake), so it cannot clear entries
// already accepted before the abort; acc_top -- which does own the FIFO
// instance -- is responsible for actually flushing/resetting it on abort.
//
// Overflow safety: bursts are atomic, so the burst-start decision must be
// made against "is there room for a WHOLE burst", not "is there room right
// now". A single `fifo_full` bit cannot express that -- checking it before
// issuing a BURST_LEN-word burst only proves room for one more word, not
// BURST_LEN more, so a burst started near-full can overrun the FIFO by the
// time it completes. This module therefore gates burst issue on
// `fifo_room_for_burst`, which acc_top's FIFO instance must assert only
// when it has at least BURST_LEN free entries (i.e. an "almost full"
// threshold sized to the current BURST_LEN, not literal full). That makes
// "never overflow" structural rather than a sizing coincidence between
// FIFO_DEPTH and BURST_LEN.

module acc_weight_fetch #(
    parameter BURST_LEN   = 64,   // words requested per burst. Parameter, not a constant --
                                   // FR-020 requires it be chosen from measurement, and a sibling
                                   // agent's burst-efficiency sweep is already pushing this toward
                                   // 128 (64 measured 85.7% with the CPU idle, below SC-006's 90%
                                   // floor; 128 measured 91.4%). Nothing below this line assumes
                                   // any specific value.
    parameter FIFO_DEPTH  = 4*BURST_LEN, // weight FIFO depth in 32-bit words, EXPRESSED relative to
                                   // BURST_LEN rather than as an independent literal, so raising
                                   // BURST_LEN (e.g. to 128) carries FIFO_DEPTH with it instead of
                                   // silently shrinking the burst-to-depth margin. REQUIRED
                                   // RELATIONSHIP: FIFO_DEPTH >= BURST_LEN, or fifo_room_for_burst
                                   // (see below) can never legally assert and the engine deadlocks
                                   // in S_Q_REQ; the 4x default gives one burst in flight plus 3x
                                   // headroom beyond that floor. If acc_top's external FIFO
                                   // instance also independently defaults FIFO_DEPTH=256/
                                   // BURST_LEN=64, that same relationship should be applied there
                                   // too so the two module instantiations can't drift apart.
    parameter ADDR_WIDTH  = 26,   // SDRAM word address width, matches muchtoremember_burst.v's burst_addr
    parameter MAX_N       = 4096, // largest supported inner dimension (elements per row)
    parameter MAX_D       = 4096, // largest supported output row count
    parameter SCALE_AWIDTH = 12   // address width of the per-operation scale BRAM (max_n*max_d/min_gs)
) (
    input  wire                    clk,
    input  wire                    resetn,        // active-low, synchronous

    // Descriptor fields for the operation being fetched, latched by acc_top
    // at operation start (data-model.md entity 4 "Operation Descriptor").
    input  wire [ADDR_WIDTH-1:0]   w_q_base,      // base address of the dense int8 `q` block
    input  wire [ADDR_WIDTH-1:0]   w_s_base,      // base address of the fp32 `s` (scale) block,
                                                   // contiguous and AFTER the q block (research R1)
    input  wire [15:0]             n,             // inner dimension (elements per row)
    input  wire [15:0]             d,             // number of output rows
    input  wire [15:0]             gs,            // group size (elements per scale), runtime value

    // Control / status
    input  wire                    start,         // pulse: begin fetching for a new operation
    input  wire                    abort,         // pulse: abandon in-flight fetch, flush FIFO, -> IDLE
    output wire                    busy,          // high across both scale-prefetch and q-stream phases
    output wire                    done,          // pulse: all q words for this operation are in the FIFO

    // SDRAM burst read port -- FemtoRV/RTL/SDRAM/muchtoremember_burst.v, unmodified interface
    // (DESIGN.md sec 9a: "Nothing here is about video ... Use it unchanged.")
    output reg                     burst_rd,      // pulse to start a burst
    output reg  [ADDR_WIDTH-1:0]   burst_addr,    // burst start address
    output reg  [8:0]              burst_len,     // words requested (1-256)
    input  wire [31:0]             burst_dout,    // burst data output
    input  wire                    burst_valid,   // burst_dout valid this cycle
    input  wire                    burst_done,    // burst complete pulse
    input  wire                    burst_busy,    // high while a burst is in flight

    // Weight FIFO feed (dense int8 `q` stream, 4 elements packed per 32-bit word)
    output wire [31:0]             fifo_wdata,
    output wire                    fifo_wen,
    input  wire                    fifo_room_for_burst, // asserted when the FIFO has >= BURST_LEN
                                                          // free entries (an "almost full" threshold
                                                          // sized to the CURRENT BURST_LEN, not
                                                          // literal not-full). Gates burst issue --
                                                          // see the overflow-safety note above.

    // Scale BRAM feed -- prefetched once per operation, before q streaming begins
    output wire [31:0]             scale_wdata,   // one fp32 scale value
    output wire                    scale_wen,
    output wire [SCALE_AWIDTH-1:0] scale_waddr    // index into this operation's scale buffer,
                                                   // 0 .. (n*d/gs)-1
);

    // ---------------------------------------------------------------------
    // log2 of a power-of-two `gs`. Only used to turn `n/gs` into a shift;
    // `gs` is assumed already validated as a power of two upstream
    // (FR-009). Not time-critical -- evaluated once per operation, at
    // `start`.
    // ---------------------------------------------------------------------
    function [4:0] log2_of_pow2;
        input [15:0] value;
        integer i;
        begin
            log2_of_pow2 = 5'd0;
            for (i = 0; i < 16; i = i + 1)
                if (value[i]) log2_of_pow2 = i[4:0];
        end
    endfunction

    wire [4:0]  gs_shift        = log2_of_pow2(gs);
    wire [31:0] n_ext           = {16'b0, n};
    wire [31:0] d_ext           = {16'b0, d};
    wire [31:0] scale_words_calc = (n_ext >> gs_shift) * d_ext; // (n/gs)*d, exact
    wire [31:0] q_words_calc     = (n_ext * d_ext) >> 2;        // n*d/4, exact (n multiple of 4)

    // ---------------------------------------------------------------------
    // FSM. Binary encoding: small (7 states), not on the SDRAM timing-
    // critical path the way muchtoremember_burst.v's one-hot FSM is.
    // Mirrors video_fetch_engine.v's REQ/WAIT pair, once per phase, plus an
    // abort-drain state.
    // ---------------------------------------------------------------------
    localparam S_IDLE       = 3'd0; // waiting for `start`
    localparam S_SCALE_REQ  = 3'd1; // decide: issue next scale burst, or move to q phase
    localparam S_SCALE_WAIT = 3'd2; // scale burst in flight, sinking words into scale BRAM
    localparam S_Q_REQ      = 3'd3; // decide: issue next q burst, stall for FIFO room, or finish
    localparam S_Q_WAIT     = 3'd4; // q burst in flight, sinking words into the weight FIFO
    localparam S_DONE       = 3'd5; // one-cycle `done` pulse
    localparam S_ABORT_WAIT = 3'd6; // in-flight burst draining after abort; writes suppressed

    reg [2:0] state;

    // Latched descriptor. acc_top's own header comment says it holds the
    // input fields steady for the duration of the fetch, but this module
    // keeps its own copy so its behaviour does not depend on that promise.
    reg [ADDR_WIDTH-1:0] op_w_q_base, op_w_s_base;

    reg [31:0] scale_words_left;
    reg [31:0] q_words_left;
    reg [ADDR_WIDTH-1:0] scale_byte_off, q_byte_off; // running offset from the resp. base address
    reg [SCALE_AWIDTH-1:0] scale_waddr_r;
    reg done_r;

    assign busy   = (state != S_IDLE);
    assign done   = done_r;

    assign fifo_wdata  = burst_dout;
    assign fifo_wen    = burst_valid && (state == S_Q_WAIT);

    assign scale_wdata = burst_dout;
    assign scale_wen   = burst_valid && (state == S_SCALE_WAIT);
    assign scale_waddr = scale_waddr_r;

    always @(posedge clk) begin
        if (!resetn) begin
            state            <= S_IDLE;
            burst_rd         <= 1'b0;
            burst_addr       <= {ADDR_WIDTH{1'b0}};
            burst_len        <= 9'd0;
            op_w_q_base      <= {ADDR_WIDTH{1'b0}};
            op_w_s_base      <= {ADDR_WIDTH{1'b0}};
            scale_words_left <= 32'd0;
            q_words_left     <= 32'd0;
            scale_byte_off   <= {ADDR_WIDTH{1'b0}};
            q_byte_off       <= {ADDR_WIDTH{1'b0}};
            scale_waddr_r    <= {SCALE_AWIDTH{1'b0}};
            done_r           <= 1'b0;
        end else begin
            burst_rd <= 1'b0; // default: pulse, deasserted unless a REQ state issues it
            done_r   <= 1'b0; // default: pulse

            case (state)

                S_IDLE: begin
                    if (start) begin
                        op_w_q_base      <= w_q_base;
                        op_w_s_base      <= w_s_base;
                        scale_words_left <= scale_words_calc;
                        q_words_left     <= q_words_calc;
                        scale_byte_off   <= {ADDR_WIDTH{1'b0}};
                        q_byte_off       <= {ADDR_WIDTH{1'b0}};
                        scale_waddr_r    <= {SCALE_AWIDTH{1'b0}};
                        state            <= S_SCALE_REQ;
                    end
                end

                // ---- Phase 1: scale prefetch --------------------------------
                S_SCALE_REQ: begin
                    if (abort) begin
                        state <= S_IDLE; // nothing in flight yet, bail immediately
                    end else if (scale_words_left == 32'd0) begin
                        state <= S_Q_REQ; // scale block fully fetched, move to phase 2
                    end else begin
                        burst_rd   <= 1'b1;
                        burst_addr <= op_w_s_base + scale_byte_off;
                        burst_len  <= (scale_words_left > BURST_LEN[31:0]) ?
                                          BURST_LEN[8:0] : scale_words_left[8:0];
                        state      <= S_SCALE_WAIT;
                    end
                end

                S_SCALE_WAIT: begin
                    if (burst_valid) begin
                        scale_words_left <= scale_words_left - 32'd1;
                        scale_byte_off   <= scale_byte_off + {{(ADDR_WIDTH-3){1'b0}}, 3'd4};
                        scale_waddr_r    <= scale_waddr_r + {{(SCALE_AWIDTH-1){1'b0}}, 1'b1};
                    end
                    if (abort)
                        state <= S_ABORT_WAIT;
                    else if (!burst_busy)
                        state <= S_SCALE_REQ; // this burst's words are all in; ask for more (or move on)
                end

                // ---- Phase 2: dense q stream ---------------------------------
                S_Q_REQ: begin
                    if (abort) begin
                        state <= S_IDLE;
                    end else if (q_words_left == 32'd0) begin
                        done_r <= 1'b1;
                        state  <= S_DONE;
                    end else if (!fifo_room_for_burst) begin
                        // Backpressure, sized to the burst about to be issued
                        // (DESIGN.md sec 3.3): don't start a burst unless the
                        // FIFO already has room for a full BURST_LEN-word
                        // burst -- re-poll every cycle until it does. This is
                        // what makes "never overflow" structural rather than
                        // a FIFO_DEPTH-vs-BURST_LEN sizing coincidence (see
                        // the module header).
                        state <= S_Q_REQ;
                    end else begin
                        burst_rd   <= 1'b1;
                        burst_addr <= op_w_q_base + q_byte_off;
                        burst_len  <= (q_words_left > BURST_LEN[31:0]) ?
                                          BURST_LEN[8:0] : q_words_left[8:0];
                        state      <= S_Q_WAIT;
                    end
                end

                S_Q_WAIT: begin
                    if (burst_valid) begin
                        q_words_left <= q_words_left - 32'd1;
                        q_byte_off   <= q_byte_off + {{(ADDR_WIDTH-3){1'b0}}, 3'd4};
                    end
                    if (abort)
                        state <= S_ABORT_WAIT;
                    else if (!burst_busy)
                        state <= S_Q_REQ;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                S_ABORT_WAIT: begin
                    // Sink the remainder of the burst already in flight
                    // (fifo_wen/scale_wen are already low here, gated by
                    // FSM state via the continuous assigns above) and wait
                    // for the controller to finish it -- muchtoremember_
                    // burst.v offers no mid-burst cancel. Bounds abort
                    // latency to one outstanding burst.
                    if (!burst_busy)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
