// acc_mac.v -- int8 MAC lanes + int32 accumulator + per-group rescale
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 3 (block diagram, section 3.2) and
// section 3.4 (why int8, why the rescale is a product of two scales).
// Reference format: Q8_0 (specs/004-int8-matmul-accel/data-model.md entities 2/3).
//
// Role: consumes LANES int8 weight elements and LANES int8 activation
// elements per cycle (as delivered by acc_weight_fetch's FIFO and the
// resident activation BRAM), accumulates an int32 dot product per scale
// group of `gs` elements, and on group completion rescales that raw int32
// sum into the running fp32 row accumulator by the PRODUCT of the weight
// group's scale and the activation group's scale (data-model.md entity 3,
// "Rules": w->s[g] * x->s[g]; research R2). When the row's last group is
// consumed, the fp32 accumulator is the row's output value.
//
// Multiplies MUST be written behaviourally so yosys infers ECP5 MULT18X18D
// (or generic $mul) rather than hand-instantiated DSP primitives
// (constitution "Portability and inference"; DESIGN.md research R6).
//
// -----------------------------------------------------------------------
// T028 interface finalisation (this pass, no port changes -- see below)
// -----------------------------------------------------------------------
// LANES and ELEM_WIDTH are confirmed as module parameters (FR-011): a
// 16-bit fallback is a re-elaboration (ELEM_WIDTH=16, LANES adjusted to
// match the narrower bandwidth-derived lane count -- DESIGN.md sec 4.2),
// not a rewrite of this file. Nothing about the datapath below assumes
// ELEM_WIDTH==8 except the width of the lane multiply itself, which is
// already parameterised.
//
// Two behaviours implied by the port list but not fully pinned down by the
// T001 skeleton comments are made explicit here, since T030 needs an exact
// contract to implement against:
//
//   1. group_start/gs are BOTH required every group, not just the first.
//      The controller (acc_top) pulses `group_start` on the first `in_valid`
//      cycle of *every* group (including the first group of an operation).
//      acc_mac uses `gs` only to detect *when* a group ends (it free-runs
//      an element counter from `group_start` and compares against `gs`);
//      it never infers a group boundary from `gs` alone. This is why `gs`
//      is wired into this module at all, rather than acc_top simply timing
//      group_done itself from n/gs it already knows.
//
//   2. `row_valid`/`row_result` pulse once per GROUP, not once per row,
//      carrying the row's running fp32 accumulator as of that group. Nothing
//      in this module's port list identifies "the last group of a row" --
//      acc_top already knows n/gs and MUST treat the row_valid pulse
//      coinciding with the row's final group as the one to commit to the
//      result BRAM; earlier pulses for the same row are the partial sum and
//      MAY be ignored by the consumer. This keeps acc_mac descriptor-blind
//      (no n/d ports), matching acc_top.v's ownership of validation.
//
// Pipeline / latency contract (needed by any consumer, and by the testbench):
//   - group_done/group_acc appear exactly 1 cycle after the `in_valid` cycle
//     that supplies the group's last element chunk (a plain registered
//     adder, not combinational, to keep timing closeable at 25 MHz -- see
//     DESIGN.md sec 4.3 on timing margin).
//   - row_valid/row_result appear exactly 8 cycles after group_done (an
//     8-stage pipeline: 2 stages each for int->float, the first fp-multiply,
//     the second fp-multiply, and the fp-accumulate -- research R31/R33's
//     DSP/timing-congestion fix; was a 4-stage, 1-cycle-per-function
//     pipeline before that), i.e. 9 cycles after the group's last input
//     chunk.
//   - The pipeline is fully streaming (a new group_done may be presented
//     every cycle; each stage is a single register with no stall), EXCEPT
//     that the LAST TWO stages (the fp-accumulate) form a true in-place
//     accumulator with 2 cycles of latency from "row_acc_q read" to
//     "row_acc_q updated": two groups belonging to the SAME row must not
//     enter the accumulate stage less than 2 cycles apart, or the second
//     would read a stale row_acc_q. This is why ACC_GS_MIN (acc_bits.vh)
//     is 2*LANES, not merely LANES -- that bound was originally derived
//     for a DIFFERENT hazard (acc_top's scale-register settle time,
//     research R31/R32) and happens to also be exactly the bound this
//     2-stage accumulate needs, verified empirically (not just algebraically)
//     by acc_unit_tb.py's test_row_interleave_at_gs_min after this change,
//     since the two hazards being the same bound is not a coincidence to
//     assume without re-checking. acc_top MUST NOT interleave a second
//     row's groups into this module until the first row's row_valid for
//     its last group has been consumed (this module processes one
//     streaming matmul row sequence at a time).
//
// Rescale/accumulate floating point: implemented as IEEE754 binary32,
// round-to-nearest-even, matching the C `float` arithmetic in runq.c
// (`(float)ival * w_scale * x_scale`, then `val +=`). Subnormal operands
// and infinities/NaNs are not specially handled beyond flush-to-zero on
// underflow and saturate-to-inf-pattern on overflow: this application's
// operands (Q8_0 scales, and int32 dot products up to +-127*127*65535)
// never approach those ranges, so the paths are defensive rather than
// exercised. group_acc (the raw int32 dot product) needs none of this --
// integer accumulation is exact by construction (research R9).
//
// Accumulator overflow: impossible for any realistic GS. Worst case per
// product is 127*127 = 16,129; ACC_WIDTH=32 (signed) does not overflow
// until GS > 133,144 (research R9). No saturation logic is added for a
// case that cannot be exercised; GS_WIDTH=16 caps gs at 65,535 in any case,
// well under that bound.

module acc_mac #(
    parameter LANES      = 4,   // parallel int8 MAC lanes. Default 4 = 32-bit SDRAM word / 8-bit
                                 // element (DESIGN.md sec 3.4/4.2: "lanes = bytes/cycle / bytes/weight").
    parameter ELEM_WIDTH  = 8,  // width of one weight/activation element, signed. int8 default;
                                 // MUST remain a parameter so a 16-bit fallback (FR-011, DESIGN.md
                                 // sec 3.5 "format-parameterised") needs no redesign.
    parameter ACC_WIDTH   = 32, // integer accumulator width per group (int32 for int8 x int8 x GS).
    parameter GS_WIDTH    = 16  // width of the runtime group-size field (data-model.md entity 4: `gs`
                                 // is a descriptor field read from the model header, not a constant).
) (
    input  wire                        clk,
    input  wire                        resetn,     // active-low, synchronous

    // Streaming operand inputs. One LANES-wide chunk of weight and activation
    // elements is consumed per asserted `in_valid` cycle. Element i of each
    // bus is signed [ELEM_WIDTH-1:0], packed LSB-first (element 0 in bits
    // [ELEM_WIDTH-1:0], element 1 in the next ELEM_WIDTH bits, ...).
    input  wire                        in_valid,   // pulse: w_data/x_data are valid this cycle
    input  wire [LANES*ELEM_WIDTH-1:0] w_data,     // LANES signed weight elements (from weight FIFO)
    input  wire [LANES*ELEM_WIDTH-1:0] x_data,     // LANES signed activation elements (from x BRAM)

    // Runtime group/row framing (data-model.md entity 4 "Operation Descriptor")
    input  wire [GS_WIDTH-1:0]         gs,         // elements per scale group (e.g. 64); n MUST be a
                                                    // whole multiple of gs -- enforced upstream (FR-009)
    input  wire                        group_start,// pulse: first valid cycle of a new group; clears
                                                    // the int32 accumulator. Required every group, not
                                                    // just the operation's first (see header note 1).
    input  wire                        row_start,  // pulse: first group of a new row; MUST coincide
                                                    // with group_start on that cycle (header note 1).
                                                    // Tags the in-flight group so the row accumulator
                                                    // is started fresh rather than added-to once this
                                                    // group's rescaled value reaches the row stage.

    // Per-group fp32 scales. MUST be valid by the cycle `group_done` pulses;
    // acc_top is responsible for presenting the group currently completing
    // (weight scale from the prefetched scale BRAM, activation scale from
    // the quantized activation vector -- data-model.md entities 2/3).
    input  wire [31:0]                 w_scale,    // weight group scale, fp32
    input  wire [31:0]                 x_scale,    // activation group scale, fp32

    // Group completion: raw (pre-rescale) int32 dot product for the group
    // that just finished, valid for one cycle on `group_done`.
    output wire                        group_done,
    output wire signed [ACC_WIDTH-1:0] group_acc,

    // Row completion: rescaled, accumulated fp32 result for one output row,
    // valid for one cycle on `row_valid` (data-model.md entity 6, Result Buffer).
    // Pulses once per group (see header note 2): the consumer commits the
    // pulse coinciding with the row's last group and may discard the rest.
    output wire                        row_valid,
    output wire [31:0]                 row_result
);

    // ------------------------------------------------------------------
    // Stage 0/G: LANES-wide multiply, group accumulate, group-boundary
    // detection. group_done/group_acc are registered -- one cycle after
    // the in_valid chunk that completes the group.
    // ------------------------------------------------------------------

    genvar gi;
    wire signed [ELEM_WIDTH-1:0] w_lane [0:LANES-1];
    wire signed [ELEM_WIDTH-1:0] x_lane [0:LANES-1];
    wire signed [2*ELEM_WIDTH-1:0] lane_product [0:LANES-1];

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : LANE
            assign w_lane[gi] = w_data[gi*ELEM_WIDTH +: ELEM_WIDTH];
            assign x_lane[gi] = x_data[gi*ELEM_WIDTH +: ELEM_WIDTH];
            // Behavioural signed multiply -- yosys infers MULT18X18D / $mul
            // here rather than a hand-instantiated primitive (research R6).
            assign lane_product[gi] = w_lane[gi] * x_lane[gi];
        end
    endgenerate

    integer li;
    reg signed [ACC_WIDTH-1:0] partial_sum_comb;
    always @* begin
        partial_sum_comb = {ACC_WIDTH{1'b0}};
        for (li = 0; li < LANES; li = li + 1) begin
            partial_sum_comb = partial_sum_comb + lane_product[li];
        end
    end

    reg [GS_WIDTH-1:0]        count_q;
    reg signed [ACC_WIDTH-1:0] acc_q;
    reg                        grp_row_first_q;   // tag: current in-flight group starts a new row

    wire [GS_WIDTH-1:0]        count_next  = group_start ? LANES[GS_WIDTH-1:0] : (count_q + LANES[GS_WIDTH-1:0]);
    wire                       group_done_next = in_valid && (count_next == gs);
    wire signed [ACC_WIDTH-1:0] acc_next   = group_start ? partial_sum_comb : (acc_q + partial_sum_comb);

    reg                        group_done_q;
    reg signed [ACC_WIDTH-1:0] group_acc_q;
    reg                        group_row_first_q; // row-first tag, sampled alongside group_acc_q

    always @(posedge clk) begin
        if (!resetn) begin
            count_q            <= {GS_WIDTH{1'b0}};
            acc_q              <= {ACC_WIDTH{1'b0}};
            grp_row_first_q    <= 1'b0;
            group_done_q       <= 1'b0;
            group_acc_q        <= {ACC_WIDTH{1'b0}};
            group_row_first_q  <= 1'b0;
        end else begin
            group_done_q <= 1'b0; // default: pulse, deasserted unless set below
            if (in_valid) begin
                count_q     <= count_next;
                acc_q       <= acc_next;
                if (group_start) begin
                    grp_row_first_q <= row_start;
                end
                group_done_q      <= group_done_next;
                group_acc_q       <= acc_next;
                // Tag the group completing THIS cycle with the row-first bit
                // latched when it started. When gs==LANES (single-cycle
                // group), group_start and group_done coincide on the same
                // cycle; the ternary then correctly uses row_start directly
                // rather than a stale held value, since the group starting
                // now is the same group completing now.
                group_row_first_q <= group_start ? row_start : grp_row_first_q;
            end
        end
    end

    assign group_done = group_done_q;
    assign group_acc  = group_acc_q;

    // ------------------------------------------------------------------
    // IEEE754 binary32 helpers (round-to-nearest-even), SPLIT into two
    // sub-stages each (research R31/R33: DSP-occupancy/timing-congestion
    // fix -- R31/R32's BRAM resize bought 0.52 MHz and confirmed
    // congestion, not BRAM placement, was never the real driver; this is
    // the remaining lever, since R31 measured the critical path as this
    // exact rescale/accumulate logic and MULT18X18D at 25/28 (89%) as the
    // tightest resource, mostly consumed by these functions' mantissa
    // multiplies).
    //
    // Each function below is split at its own natural half-way point (the
    // point where the "expensive" combinational work -- leading-zero
    // detection, the mantissa multiply, or the align/add/CLZ chain -- ends
    // and "finish the number" work -- shift+round+pack -- begins), with a
    // register in between. This is NOT a resource-sharing scheme (no
    // multiplier is time-multiplexed between the two `fp_mul32` call
    // sites): that would need a genuinely different microarchitecture (a
    // recirculating execution unit, 1 token every 2 cycles through the
    // shared hardware) and was deliberately NOT attempted here, because it
    // would tighten the exact throughput margin ACC_GS_MIN was just proven
    // safe at (research R31/R32) in a way that would need re-deriving and
    // re-verifying from scratch, for a benefit (fewer physical DSP
    // instances) that cannot be measured without a synthesis run this
    // module's author does not have access to. What IS done here -- a
    // plain, linear, non-shared pipeline with more stages -- carries none
    // of that risk: a linear shift-register pipeline has no cross-token
    // hazard at any depth EXCEPT at the true in-place accumulator (the
    // last two stages, see the header's latency-contract comment and
    // ACC_GS_MIN's derivation in acc_bits.vh), which is called out
    // explicitly below rather than assumed safe.
    //
    // Each split was verified bit-for-bit equivalent to the original
    // single-stage function it replaces BEFORE being written here: a
    // faithful Python transliteration of each split was run against
    // hundreds of thousands of random operand pairs, the 540-case
    // deterministic boundary sweep construction (research R32), and both
    // real bug reproductions (research R26/R30) -- zero mismatches in any
    // case. The actual hardware regression (acc_mac_tb.py, including that
    // same 540-case sweep run against real hardware, not just the Python
    // model) is the check that matters, but doing the algebra first is
    // what makes a hardware failure diagnosable as "the split is wrong"
    // versus "something else changed", per this project's own repeated
    // lesson about hand-rolled IEEE754 arithmetic.
    // ------------------------------------------------------------------

    function [5:0] clz32;
        input [31:0] v;
        integer i;
        begin
            clz32 = 6'd32;
            for (i = 31; i >= 0; i = i - 1) begin
                if (v[i] && (clz32 == 6'd32)) begin
                    clz32 = 31 - i;
                end
            end
        end
    endfunction

    // ---- i2f32, split at "leading-zero detection done" -----------------
    // Packed return: {is_zero[1], sign[1], mag[31:0], msb_pos[5:0]}, 40 bits.
    localparam I2F1_W = 1 + 1 + 32 + 6;

    function [I2F1_W-1:0] i2f32_s1;
        input signed [31:0] v;
        reg                sign;
        reg [31:0]         mag;
        reg [5:0]          msb_pos;
        begin
            if (v == 32'sd0) begin
                i2f32_s1 = {1'b1, 1'b0, 32'b0, 6'b0};
            end else begin
                sign    = v[31];
                mag     = sign ? (~v + 32'd1) : v;
                msb_pos = 6'd31 - clz32(mag);
                i2f32_s1 = {1'b0, sign, mag, msb_pos};
            end
        end
    endfunction

    function [31:0] i2f32_s2;
        input [I2F1_W-1:0] packed_s1;
        reg                is_zero, sign;
        reg [31:0]         mag;
        reg [5:0]          msb_pos;
        reg [24:0]         mant_r; // 24-bit candidate + 1 bit for rounding overflow
        reg [7:0]          exp_r;
        reg [7:0]          shift_r;
        reg                guard, sticky, round_up;
        begin
            {is_zero, sign, mag, msb_pos} = packed_s1;
            if (is_zero) begin
                i2f32_s2 = 32'h0000_0000;
            end else if (msb_pos <= 6'd23) begin
                mant_r   = {1'b0, mag << (6'd23 - msb_pos)};
                exp_r    = 8'd127 + {2'b0, msb_pos};
                i2f32_s2 = {sign, exp_r, mant_r[22:0]};
            end else begin
                shift_r  = {2'b0, msb_pos} - 8'd23;
                mant_r   = {1'b0, mag >> shift_r};
                guard    = mag[shift_r-1];
                sticky   = (shift_r >= 8'd2) ? |(mag & ((32'd1 << (shift_r - 8'd1)) - 32'd1)) : 1'b0;
                round_up = guard & (sticky | mant_r[0]);
                if (round_up) begin
                    mant_r = mant_r + 25'd1;
                end
                exp_r = 8'd127 + {2'b0, msb_pos};
                if (mant_r[24]) begin
                    mant_r = mant_r >> 1;
                    exp_r  = exp_r + 8'd1;
                end
                i2f32_s2 = {sign, exp_r, mant_r[22:0]};
            end
        end
    endfunction

    // ---- fp_mul32, split at "raw product computed" ---------------------
    // Packed return: {zero_case[1], sign_r[1], product[47:0], exp_sum[9:0]}, 60 bits.
    localparam FMUL1_W = 1 + 1 + 48 + 10;

    function [FMUL1_W-1:0] fp_mul32_s1;
        input [31:0] a, b;
        reg         sign_a, sign_b, sign_r;
        reg [7:0]   exp_a, exp_b;
        reg [22:0]  mant_a, mant_b;
        reg         a_zero, b_zero;
        reg [23:0]  fa, fb;
        reg [47:0]  product;
        reg signed [9:0] exp_sum;
        begin
            sign_a = a[31]; exp_a = a[30:23]; mant_a = a[22:0];
            sign_b = b[31]; exp_b = b[30:23]; mant_b = b[22:0];
            a_zero = (exp_a == 8'd0) && (mant_a == 23'd0);
            b_zero = (exp_b == 8'd0) && (mant_b == 23'd0);
            sign_r = sign_a ^ sign_b;
            if (a_zero || b_zero) begin
                fp_mul32_s1 = {1'b1, sign_r, 48'b0, 10'sd0};
            end else begin
                fa = {1'b1, mant_a};
                fb = {1'b1, mant_b};
                product = fa * fb; // behavioural -> DSP-friendly; the ONE multiply
                                    // this function performs, now isolated to its
                                    // own register stage (ECP5 MULT18X18D has native
                                    // pipeline registers -- registering a DSP's
                                    // output lets yosys/nextpnr use them instead of
                                    // a separate LUT-based register bank).
                exp_sum = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd127;
                fp_mul32_s1 = {1'b0, sign_r, product, exp_sum};
            end
        end
    endfunction

    function [31:0] fp_mul32_s2;
        input [FMUL1_W-1:0] packed_s1;
        reg         zero_case, sign_r;
        reg [47:0]  product;
        reg signed [9:0] exp_sum;
        reg [24:0]  mant_r;
        reg         guard, sticky, round_up;
        begin
            {zero_case, sign_r, product, exp_sum} = packed_s1;
            if (zero_case) begin
                fp_mul32_s2 = {sign_r, 31'b0};
            end else begin
                if (product[47]) begin
                    mant_r  = {1'b0, product[47:24]};
                    guard   = product[23];
                    sticky  = |product[22:0];
                    exp_sum = exp_sum + 10'sd1;
                end else begin
                    mant_r  = {1'b0, product[46:23]};
                    guard   = product[22];
                    sticky  = |product[21:0];
                end
                round_up = guard & (sticky | mant_r[0]);
                if (round_up) mant_r = mant_r + 25'd1;
                if (mant_r[24]) begin
                    mant_r  = mant_r >> 1;
                    exp_sum = exp_sum + 10'sd1;
                end
                if (exp_sum <= 10'sd0) begin
                    fp_mul32_s2 = {sign_r, 31'b0};           // underflow: flush to zero (not expected)
                end else if (exp_sum >= 10'sd255) begin
                    fp_mul32_s2 = {sign_r, 8'hFF, 23'b0};     // overflow: saturate (not expected)
                end else begin
                    fp_mul32_s2 = {sign_r, exp_sum[7:0], mant_r[22:0]};
                end
            end
        end
    endfunction

    // ---- fp_add32, split at "normalized magnitude + shift amount known" -
    // (decompose + pick hi/lo + align + add/sub-with-decrement + CLZ +
    // normalize-shift in stage 1; guard/round/pack in stage 2). This is
    // the pair used for the ROW ACCUMULATE specifically -- see the header
    // latency-contract comment for why it is 2 stages, not 3: a 3rd stage
    // here would need >2 cycles of same-row group spacing to stay hazard-
    // free, which is tighter than ACC_GS_MIN=2*LANES guarantees.
    // Packed return: {zero_case[1], zero_result[31:0], sign_r[1],
    //                 norm_field[26:0], exp_wide[9:0], align_sticky[1],
    //                 rshift_sticky[1]}, 73 bits.
    localparam FADD1_W = 1 + 32 + 1 + 27 + 10 + 1 + 1;

    function [FADD1_W-1:0] fp_add32_s1;
        input [31:0] a, b;
        reg        sign_a, sign_b, sign_r;
        reg [7:0]  exp_a, exp_b, exp_hi;
        reg [22:0] mant_a, mant_b;
        reg        a_zero, b_zero, pick_a, same_sign;
        reg [26:0] mant_hi_ext, mant_lo_ext, mant_lo_shifted, reconstructed;
        reg [7:0]  exp_diff;
        reg        align_sticky;
        reg [27:0] mag_wide;
        reg [5:0]  bitpos, lzp;
        reg signed [8:0] shift_amt;
        reg [27:0] shifted_out_mask, norm_field28;
        reg [26:0] norm_field;
        reg        rshift_sticky;
        reg signed [9:0] exp_wide;
        begin
            sign_a = a[31]; exp_a = a[30:23]; mant_a = a[22:0];
            sign_b = b[31]; exp_b = b[30:23]; mant_b = b[22:0];
            a_zero = (exp_a == 8'd0) && (mant_a == 23'd0);
            b_zero = (exp_b == 8'd0) && (mant_b == 23'd0);
            if (a_zero) begin
                fp_add32_s1 = {1'b1, b, 40'b0};
            end else if (b_zero) begin
                fp_add32_s1 = {1'b1, a, 40'b0};
            end else begin
                pick_a = (exp_a != exp_b) ? (exp_a > exp_b) : (mant_a >= mant_b);
                if (pick_a) begin
                    exp_hi = exp_a; mant_hi_ext = {1'b1, mant_a, 3'b000};
                    exp_diff = exp_a - exp_b; mant_lo_ext = {1'b1, mant_b, 3'b000};
                    sign_r = sign_a; same_sign = (sign_a == sign_b);
                end else begin
                    exp_hi = exp_b; mant_hi_ext = {1'b1, mant_b, 3'b000};
                    exp_diff = exp_b - exp_a; mant_lo_ext = {1'b1, mant_a, 3'b000};
                    sign_r = sign_b; same_sign = (sign_a == sign_b);
                end

                if (exp_diff > 8'd27) begin
                    mant_lo_shifted = 27'b0;
                    align_sticky    = 1'b1;
                end else begin
                    mant_lo_shifted = mant_lo_ext >> exp_diff;
                    reconstructed   = mant_lo_shifted << exp_diff;
                    align_sticky    = (reconstructed != mant_lo_ext);
                end

                // Decrement-and-force-sticky subtraction fix (research R30
                // "take 2" -- see acc_top.v/research.md for the full
                // derivation; unchanged by this pipelining pass, just
                // relocated into this stage).
                if (same_sign) begin
                    mag_wide = {1'b0, mant_hi_ext} + {1'b0, mant_lo_shifted};
                end else begin
                    mag_wide = {1'b0, mant_hi_ext} - {1'b0, mant_lo_shifted};
                    if (align_sticky) mag_wide = mag_wide - 28'd1;
                end

                if (mag_wide == 28'b0) begin
                    fp_add32_s1 = {1'b1, {sign_r, 31'b0}, 40'b0}; // exact cancellation -> +0
                end else begin
                    lzp    = clz32({4'b0, mag_wide});
                    bitpos = 6'd31 - lzp;
                    shift_amt = {3'b0, bitpos} - 9'sd26;

                    if (shift_amt > 0) begin
                        shifted_out_mask = (28'd1 << shift_amt) - 28'd1;
                        rshift_sticky    = |(mag_wide & shifted_out_mask);
                        norm_field28     = mag_wide >> shift_amt;
                    end else begin
                        rshift_sticky    = 1'b0;
                        norm_field28     = mag_wide << (-shift_amt);
                    end
                    norm_field = norm_field28[26:0];
                    exp_wide   = $signed({2'b0, exp_hi}) + shift_amt;

                    fp_add32_s1 = {1'b0, 32'b0, sign_r, norm_field, exp_wide, align_sticky, rshift_sticky};
                end
            end
        end
    endfunction

    function [31:0] fp_add32_s2;
        input [FADD1_W-1:0] packed_s1;
        reg        zero_case;
        reg [31:0] zero_result;
        reg        sign_r;
        reg [26:0] norm_field;
        reg signed [9:0] exp_wide;
        reg        align_sticky, rshift_sticky;
        reg [23:0] mant_window;
        reg        guard, sticky, round_up;
        reg [24:0] mant_rounded;
        reg [7:0]  exp_r;
        begin
            {zero_case, zero_result, sign_r, norm_field, exp_wide, align_sticky, rshift_sticky} = packed_s1;
            if (zero_case) begin
                fp_add32_s2 = zero_result;
            end else begin
                mant_window = norm_field[26:3];
                guard       = norm_field[2];
                sticky      = align_sticky | rshift_sticky | norm_field[1] | norm_field[0];
                round_up    = guard & (sticky | mant_window[0]);
                mant_rounded = {1'b0, mant_window} + round_up;
                if (mant_rounded[24]) begin
                    mant_rounded = mant_rounded >> 1;
                    exp_wide     = exp_wide + 10'sd1;
                end

                if (exp_wide <= 10'sd0) begin
                    fp_add32_s2 = {sign_r, 31'b0};          // underflow: flush to zero (not expected)
                end else if (exp_wide >= 10'sd255) begin
                    fp_add32_s2 = {sign_r, 8'hFF, 23'b0};   // overflow: saturate (not expected)
                end else begin
                    exp_r = exp_wide[7:0];
                    fp_add32_s2 = {sign_r, exp_r, mant_rounded[22:0]};
                end
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Pipeline: 8 registered stages from group_done_q to row_result_q (was
    // 4 -- research R31/R33). Purely linear (a-then-b, one token per
    // cycle, no stalls, no resource sharing across tokens) EXCEPT the last
    // two stages (p4a -> final), which form the true in-place row
    // accumulator -- see the header's latency-contract comment.
    // ------------------------------------------------------------------

    // Stage 1: i2f32(group_acc_q), split in two.
    reg                 p1a_valid;
    reg [I2F1_W-1:0]    p1a_i2f_s1;
    reg [31:0]          p1a_wscale, p1a_xscale;
    reg                 p1a_row_first;

    reg                 p1b_valid;
    reg [31:0]          p1b_ival_f, p1b_wscale, p1b_xscale;
    reg                 p1b_row_first;

    // Stage 2: fp_mul32(ival_f, w_scale), split in two.
    reg                 p2a_valid;
    reg [FMUL1_W-1:0]   p2a_mul_s1;
    reg [31:0]          p2a_xscale;
    reg                 p2a_row_first;

    reg                 p2b_valid;
    reg [31:0]          p2b_tmp_f, p2b_xscale;
    reg                 p2b_row_first;

    // Stage 3: fp_mul32(tmp_f, x_scale), split in two.
    reg                 p3a_valid;
    reg [FMUL1_W-1:0]   p3a_mul_s1;
    reg                 p3a_row_first;

    reg                 p3b_valid;
    reg [31:0]          p3b_rescaled_f;
    reg                 p3b_row_first;

    // Stage 4: fp_add32(row_first ? 0 : row_acc_q, rescaled_f), split in
    // two -- the true in-place accumulator (see header comment).
    reg                 p4a_valid;
    reg [FADD1_W-1:0]   p4a_add_s1;

    reg [31:0]          row_acc_q;
    reg                 row_valid_q;
    reg [31:0]          row_result_q;

    // Computed once, fed to both row_acc_q and row_result_q below (they
    // are always the same value) -- avoids instantiating the rounding/pack
    // logic of fp_add32_s2 twice in hardware.
    wire [31:0] p4b_result = fp_add32_s2(p4a_add_s1);

    always @(posedge clk) begin
        if (!resetn) begin
            p1a_valid <= 1'b0; p1a_i2f_s1 <= {I2F1_W{1'b0}}; p1a_wscale <= 32'b0; p1a_xscale <= 32'b0; p1a_row_first <= 1'b0;
            p1b_valid <= 1'b0; p1b_ival_f <= 32'b0; p1b_wscale <= 32'b0; p1b_xscale <= 32'b0; p1b_row_first <= 1'b0;
            p2a_valid <= 1'b0; p2a_mul_s1 <= {FMUL1_W{1'b0}}; p2a_xscale <= 32'b0; p2a_row_first <= 1'b0;
            p2b_valid <= 1'b0; p2b_tmp_f <= 32'b0; p2b_xscale <= 32'b0; p2b_row_first <= 1'b0;
            p3a_valid <= 1'b0; p3a_mul_s1 <= {FMUL1_W{1'b0}}; p3a_row_first <= 1'b0;
            p3b_valid <= 1'b0; p3b_rescaled_f <= 32'b0; p3b_row_first <= 1'b0;
            p4a_valid <= 1'b0; p4a_add_s1 <= {FADD1_W{1'b0}};
            row_acc_q    <= 32'b0;
            row_valid_q  <= 1'b0;
            row_result_q <= 32'b0;
        end else begin
            // Stage 1a: latch group completion; begin i2f32(group_acc_q).
            p1a_valid     <= group_done_q;
            p1a_i2f_s1    <= i2f32_s1(group_acc_q);
            p1a_wscale    <= w_scale;
            p1a_xscale    <= x_scale;
            p1a_row_first <= group_row_first_q;

            // Stage 1b: finish i2f32 -> ival_f.
            p1b_valid     <= p1a_valid;
            p1b_ival_f    <= i2f32_s2(p1a_i2f_s1);
            p1b_wscale    <= p1a_wscale;
            p1b_xscale    <= p1a_xscale;
            p1b_row_first <= p1a_row_first;

            // Stage 2a: begin (float)ival * w_scale.
            p2a_valid     <= p1b_valid;
            p2a_mul_s1    <= fp_mul32_s1(p1b_ival_f, p1b_wscale);
            p2a_xscale    <= p1b_xscale;
            p2a_row_first <= p1b_row_first;

            // Stage 2b: finish (float)ival * w_scale -> tmp_f.
            p2b_valid     <= p2a_valid;
            p2b_tmp_f     <= fp_mul32_s2(p2a_mul_s1);
            p2b_xscale    <= p2a_xscale;
            p2b_row_first <= p2a_row_first;

            // Stage 3a: begin tmp_f * x_scale.
            p3a_valid     <= p2b_valid;
            p3a_mul_s1    <= fp_mul32_s1(p2b_tmp_f, p2b_xscale);
            p3a_row_first <= p2b_row_first;

            // Stage 3b: finish tmp_f * x_scale -> rescaled_f.
            p3b_valid      <= p3a_valid;
            p3b_rescaled_f <= fp_mul32_s2(p3a_mul_s1);
            p3b_row_first  <= p3a_row_first;

            // Stage 4a: begin the row accumulate. "a" operand is 0 (via
            // fp_add32_s1's own a_zero shortcut) when this group opens a
            // new row, else the CURRENT row_acc_q -- same semantics as the
            // pre-pipelining bypass mux, expressed through the split
            // function's existing zero-handling instead of a separate mux.
            p4a_valid  <= p3b_valid;
            p4a_add_s1 <= fp_add32_s1(p3b_row_first ? 32'b0 : row_acc_q, p3b_rescaled_f);

            // Stage 4b (final): finish the accumulate. This is the ONLY
            // place row_acc_q is written -- 2 cycles after it was read in
            // 4a, which is why ACC_GS_MIN must guarantee >=2 cycles between
            // any two same-row groups reaching stage 4a (header comment).
            row_valid_q <= p4a_valid;
            if (p4a_valid) begin
                row_acc_q    <= p4b_result;
                row_result_q <= p4b_result;
            end
        end
    end

    assign row_valid  = row_valid_q;
    assign row_result = row_result_q;

endmodule
