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
//   - row_valid/row_result appear exactly 4 cycles after group_done (a
//     4-stage int->float / fp-multiply / fp-multiply / fp-accumulate
//     pipeline), i.e. 5 cycles after the group's last input chunk.
//   - The pipeline is fully streaming (a new group_done may be presented
//     every cycle; each stage is a single register with no stall), EXCEPT
//     that the row-accumulate stage is a true in-place accumulator: two
//     groups belonging to the SAME row must not be presented back-to-back
//     faster than acc_top's own group cadence naturally allows, which is
//     never a problem in practice (gs/LANES >= 8 cycles per group for any
//     realistic (gs>=32, LANES<=8) combination, versus a 5-cycle pipeline).
//     acc_top MUST NOT interleave a second row's groups into this module
//     until the first row's row_valid for its last group has been consumed
//     (this module processes one streaming matmul row sequence at a time).
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
    // IEEE754 binary32 helpers (round-to-nearest-even). Used only on the
    // once-per-group rescale/accumulate path below -- there is gs/LANES
    // cycles of slack per group (>=8 for any realistic parameterisation),
    // so these are plain combinational functions feeding registered
    // pipeline stages, not something that needs to close timing in a
    // single fast cycle the way the int8 lane multiply does.
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

    // Signed integer -> binary32. Exact whenever |v| < 2^24 (always true in
    // this application: max |ival| is 127*127*65535 ~= 1.06e9 < 2^31 but
    // the mantissa is only 24 bits, so this DOES need a general
    // round-to-nearest-even path, not just the exact case, to stay correct
    // at large GS).
    function [31:0] i2f32;
        input signed [31:0] v;
        reg                sign;
        reg [31:0]         mag;
        reg [5:0]          lz, msb_pos;
        reg [24:0]         mant_r; // 24-bit candidate + 1 bit for rounding overflow
        reg [7:0]          exp_r;
        reg [7:0]          shift_r;
        reg                guard, sticky, round_up;
        begin
            if (v == 32'sd0) begin
                i2f32 = 32'h0000_0000;
            end else begin
                sign = v[31];
                mag  = sign ? (~v + 32'd1) : v;
                lz   = clz32(mag);
                msb_pos = 6'd31 - lz;
                if (msb_pos <= 6'd23) begin
                    mant_r = {1'b0, mag << (6'd23 - msb_pos)};
                    exp_r  = 8'd127 + {2'b0, msb_pos};
                end else begin
                    shift_r = {2'b0, msb_pos} - 8'd23;
                    mant_r  = {1'b0, mag >> shift_r};
                    guard   = mag[shift_r-1];
                    sticky  = (shift_r >= 8'd2) ? |(mag & ((32'd1 << (shift_r - 8'd1)) - 32'd1)) : 1'b0;
                    round_up = guard & (sticky | mant_r[0]);
                    if (round_up) begin
                        mant_r = mant_r + 25'd1;
                    end
                    exp_r = 8'd127 + {2'b0, msb_pos};
                    if (mant_r[24]) begin
                        mant_r = mant_r >> 1;
                        exp_r  = exp_r + 8'd1;
                    end
                end
                i2f32 = {sign, exp_r, mant_r[22:0]};
            end
        end
    endfunction

    function [31:0] fp_mul32;
        input [31:0] a, b;
        reg         sign_a, sign_b, sign_r;
        reg [7:0]   exp_a, exp_b;
        reg [22:0]  mant_a, mant_b;
        reg         a_zero, b_zero;
        reg [23:0]  fa, fb;
        reg [47:0]  product;
        reg signed [9:0] exp_sum;
        reg [24:0]  mant_r;
        reg         guard, sticky, round_up;
        begin
            sign_a = a[31]; exp_a = a[30:23]; mant_a = a[22:0];
            sign_b = b[31]; exp_b = b[30:23]; mant_b = b[22:0];
            a_zero = (exp_a == 8'd0) && (mant_a == 23'd0);
            b_zero = (exp_b == 8'd0) && (mant_b == 23'd0);
            sign_r = sign_a ^ sign_b;
            if (a_zero || b_zero) begin
                fp_mul32 = {sign_r, 31'b0};
            end else begin
                fa = {1'b1, mant_a};
                fb = {1'b1, mant_b};
                product = fa * fb; // behavioural -> DSP-friendly
                exp_sum = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd127;
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
                    fp_mul32 = {sign_r, 31'b0};           // underflow: flush to zero (not expected)
                end else if (exp_sum >= 10'sd255) begin
                    fp_mul32 = {sign_r, 8'hFF, 23'b0};     // overflow: saturate (not expected)
                end else begin
                    fp_mul32 = {sign_r, exp_sum[7:0], mant_r[22:0]};
                end
            end
        end
    endfunction

    function [31:0] fp_add32;
        input [31:0] a, b;
        reg        sign_a, sign_b, sign_r;
        reg [7:0]  exp_a, exp_b, exp_hi, exp_r;
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
        reg [23:0] mant_window;
        reg        guard, sticky, round_up;
        reg [24:0] mant_rounded;
        reg signed [9:0] exp_wide;
        begin
            sign_a = a[31]; exp_a = a[30:23]; mant_a = a[22:0];
            sign_b = b[31]; exp_b = b[30:23]; mant_b = b[22:0];
            a_zero = (exp_a == 8'd0) && (mant_a == 23'd0);
            b_zero = (exp_b == 8'd0) && (mant_b == 23'd0);
            if (a_zero) begin
                fp_add32 = b;
            end else if (b_zero) begin
                fp_add32 = a;
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
                    align_sticky    = 1'b1; // mant_lo_ext's implicit 1 is always set -> definitely lost
                end else begin
                    mant_lo_shifted = mant_lo_ext >> exp_diff;
                    reconstructed   = mant_lo_shifted << exp_diff;
                    align_sticky    = (reconstructed != mant_lo_ext);
                end

                // BUG FIX, take 2 (research.md has both: the first attempt
                // below was ALSO wrong, caught by the same T035/T036
                // integration path finding a second real-data case at
                // GS=64 -- this project's own real group size -- that the
                // first fix didn't cover). acc_mac.v was unit-tested
                // 1000/1000 bit-exact in acc_mac_tb.py, but never chained
                // real groups through a same-magnitude-order subtraction
                // the way a real matmul row does; see research.md for both
                // reproductions and their exact-arithmetic proofs.
                //
                // mant_lo_shifted is mant_lo_ext right-shifted by exp_diff
                // and TRUNCATED (align_sticky flags that real bits were
                // dropped). For addition that only makes the sum an UNDER-
                // estimate of the true value, exactly what the guard/sticky
                // convention below expects. For SUBTRACTION it is the
                // opposite: hi - trunc(lo) OVER-shoots the true difference,
                // because less was subtracted than the true lo.
                //
                // The first attempt "fixed" this by subtracting the CEILING
                // of mant_lo_shifted instead of the floor when align_sticky
                // was set -- restoring an under-estimate, but the amount by
                // which it under-estimates (some fraction strictly between
                // 0 and 1 ULP at the subtrahend's own LSB) is not
                // represented by ANY bit still being tracked: it lives
                // below the one bit position the ceiling adjustment just
                // consumed. Reading norm_field's own low bits for `sticky`
                // after that point sees whatever they happen to be, which
                // is uncorrelated with whether real precision was lost --
                // exactly the failure this take-2 fixes.
                //
                // Correct (standard FPU) technique: use the plain FLOOR-
                // based subtraction, then -- only when align_sticky (bits
                // really were dropped from the subtrahend) -- DECREMENT the
                // difference by one whole ULP (ordinary integer subtract,
                // which correctly ripple-borrows across any run of zero
                // bits) and treat `sticky` as unconditionally 1 from that
                // point on, regardless of what the decremented value's own
                // low bits show. This is exact: true_diff = decremented +
                // (some fraction in (0,1)), so decremented is a valid lower
                // bound AND we know for certain there is nonzero weight
                // below it -- the one thing the ceiling approach could not
                // establish. (Provably cannot underflow past zero: pick_a
                // guarantees true_hi >= true_lo, so floor(mant_hi_ext -
                // mant_lo_shifted) >= 1 whenever align_sticky = 1; the
                // degenerate "hi exactly equals a truncated lo" case would
                // require true_lo <= floor(lo) < true_lo, a contradiction.)
                if (same_sign) begin
                    mag_wide = {1'b0, mant_hi_ext} + {1'b0, mant_lo_shifted};
                end else begin
                    mag_wide = {1'b0, mant_hi_ext} - {1'b0, mant_lo_shifted};
                    if (align_sticky) mag_wide = mag_wide - 28'd1;
                end

                if (mag_wide == 28'b0) begin
                    fp_add32 = 32'b0; // exact cancellation -> +0
                end else begin
                    lzp    = clz32({4'b0, mag_wide});      // leading zeros in a 32-bit view
                    bitpos = 6'd31 - lzp;                  // position of the leading 1, 0..27
                    shift_amt = {3'b0, bitpos} - 9'sd26;    // >0: carry-out (right shift); <0: cancellation (left shift)

                    if (shift_amt > 0) begin
                        shifted_out_mask = (28'd1 << shift_amt) - 28'd1;
                        rshift_sticky    = |(mag_wide & shifted_out_mask);
                        norm_field28     = mag_wide >> shift_amt;
                    end else begin
                        rshift_sticky    = 1'b0;
                        norm_field28     = mag_wide << (-shift_amt);
                    end
                    norm_field = norm_field28[26:0];

                    exp_wide = $signed({2'b0, exp_hi}) + shift_amt;

                    mant_window = norm_field[26:3];
                    guard       = norm_field[2];
                    // Uniform for both paths now (take 2, see the mag_wide
                    // computation above): for addition align_sticky already
                    // meant "the sum under-estimates truth", and for
                    // subtraction the decrement-when-align_sticky above
                    // establishes exactly the same guarantee, so both are
                    // "there is real nonzero weight below what we kept" and
                    // both belong in sticky the same way.
                    sticky      = align_sticky | rshift_sticky | norm_field[1] | norm_field[0];
                    round_up    = guard & (sticky | mant_window[0]);
                    mant_rounded = {1'b0, mant_window} + round_up;
                    if (mant_rounded[24]) begin
                        mant_rounded = mant_rounded >> 1;
                        exp_wide     = exp_wide + 10'sd1;
                    end

                    if (exp_wide <= 10'sd0) begin
                        fp_add32 = {sign_r, 31'b0};          // underflow: flush to zero (not expected)
                    end else if (exp_wide >= 10'sd255) begin
                        fp_add32 = {sign_r, 8'hFF, 23'b0};   // overflow: saturate (not expected)
                    end else begin
                        exp_r = exp_wide[7:0];
                        fp_add32 = {sign_r, exp_r, mant_rounded[22:0]};
                    end
                end
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Stages 1-4: int->float, two chained fp multiplies (matching runq.c's
    // `(float)ival * w_scale * x_scale` left-to-right evaluation), then
    // accumulate into the running row result. One register stage each.
    // ------------------------------------------------------------------

    reg        s1_valid_q;
    reg [31:0] s1_ival_f_q, s1_wscale_q, s1_xscale_q;
    reg        s1_row_first_q;

    reg        s2_valid_q;
    reg [31:0] s2_tmp_f_q, s2_xscale_q;
    reg        s2_row_first_q;

    reg        s3_valid_q;
    reg [31:0] s3_rescaled_f_q;
    reg        s3_row_first_q;

    reg [31:0] row_acc_q;
    reg        row_valid_q;
    reg [31:0] row_result_q;

    always @(posedge clk) begin
        if (!resetn) begin
            s1_valid_q <= 1'b0; s1_ival_f_q <= 32'b0; s1_wscale_q <= 32'b0; s1_xscale_q <= 32'b0; s1_row_first_q <= 1'b0;
            s2_valid_q <= 1'b0; s2_tmp_f_q  <= 32'b0; s2_xscale_q <= 32'b0; s2_row_first_q <= 1'b0;
            s3_valid_q <= 1'b0; s3_rescaled_f_q <= 32'b0; s3_row_first_q <= 1'b0;
            row_acc_q    <= 32'b0;
            row_valid_q  <= 1'b0;
            row_result_q <= 32'b0;
        end else begin
            // Stage 1: latch group completion + convert ival to float.
            s1_valid_q     <= group_done_q;
            s1_ival_f_q    <= i2f32(group_acc_q);
            s1_wscale_q    <= w_scale;
            s1_xscale_q    <= x_scale;
            s1_row_first_q <= group_row_first_q;

            // Stage 2: (float)ival * w_scale
            s2_valid_q     <= s1_valid_q;
            s2_tmp_f_q     <= fp_mul32(s1_ival_f_q, s1_wscale_q);
            s2_xscale_q    <= s1_xscale_q;
            s2_row_first_q <= s1_row_first_q;

            // Stage 3: (...) * x_scale
            s3_valid_q     <= s2_valid_q;
            s3_rescaled_f_q <= fp_mul32(s2_tmp_f_q, s2_xscale_q);
            s3_row_first_q  <= s2_row_first_q;

            // Stage 4: accumulate into the row result (fresh start if this
            // group opened a new row, else add to the running value).
            row_valid_q <= s3_valid_q;
            if (s3_valid_q) begin
                row_acc_q    <= s3_row_first_q ? s3_rescaled_f_q : fp_add32(row_acc_q, s3_rescaled_f_q);
                row_result_q <= s3_row_first_q ? s3_rescaled_f_q : fp_add32(row_acc_q, s3_rescaled_f_q);
            end
        end
    end

    assign row_valid  = row_valid_q;
    assign row_result = row_result_q;

endmodule
