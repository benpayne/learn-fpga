// acc_bits.vh -- shared constants for the MatMul accelerator.
//
// Created centrally because acc_regs.v and acc_top.v must agree on the error
// encoding and there was no shared definition: acc_regs defined ERR_* locally
// and left a comment asking acc_top to reuse the same values. Two modules
// agreeing by comment is how they stop agreeing.
//
// Include with:  `include "acc_bits.vh"
//
// See specs/004-int8-matmul-accel/data-model.md entities 4 and 5, and
// specs/004-int8-matmul-accel/contracts/accelerator-interface.md.

`ifndef ACC_BITS_VH
`define ACC_BITS_VH

// ---- Register indices, selected via IO_ACC_IDX, accessed via IO_ACC_DAT ----
`define ACC_REG_W_Q_BASE   0
`define ACC_REG_W_S_BASE   1
`define ACC_REG_X_SLOT     2
`define ACC_REG_OUT_SLOT   3
`define ACC_REG_N          4
`define ACC_REG_D          5
`define ACC_REG_GS         6
`define ACC_REG_MODE       7
`define ACC_REG_CTRL       8
`define ACC_REG_STATUS     9
`define ACC_REG_PERF_CYC  10
`define ACC_REG_PERF_STALL 11

// ---- CTRL bits (write) ----
`define ACC_CTRL_START     0
`define ACC_CTRL_ABORT     1

// ---- STATUS bits (read) ----
`define ACC_STATUS_BUSY    0
`define ACC_STATUS_DONE    1
`define ACC_STATUS_ERR     2
// bit 3 reserved; 7:4 error code; 15:8 queue depth

// ---- Error codes (STATUS[7:4]) ----
// 0 means no error. ERR_DIM is the one that matters most: runq.c silently
// truncates when the group size does not divide the inner dimension, which
// produced garbage output that looked like quantization damage and cost real
// debugging time (research R16). The hardware rejects it loudly instead.
`define ACC_ERR_NONE       4'd0
`define ACC_ERR_DIM        4'd1   // n is not a whole number of groups
`define ACC_ERR_GS         4'd2   // group size unsupported (not a power of two, out of range)
`define ACC_ERR_RANGE      4'd3   // n or d exceeds configured maxima
`define ACC_ERR_SLOT       4'd4   // result would overflow its buffer slot
`define ACC_ERR_FULL       4'd5   // descriptor queue full
// Added after T034 found that a descriptor with mode != MODE_MATMUL would
// silently run the matmul datapath. Only MODE_MATMUL is implemented until
// T064 adds the attention modes; until then an unimplemented mode MUST be
// rejected rather than quietly producing a plausible wrong result. That is
// the same failure shape as the runq.c truncation in research R16.
`define ACC_ERR_MODE       4'd6   // mode not implemented / unrecognised

// ---- Operating modes ----
`define ACC_MODE_MATMUL    2'd0
`define ACC_MODE_ATT_SCORE 2'd1
`define ACC_MODE_ATT_SUM   2'd2

// ---- Supported group-size bounds ----
// Lower bound derivation (raised from 4 to 8, research R16->R26 addendum):
// gs=4 was a leftover from before hidden_dim padding (research R16), when
// this model's unpadded hidden_dim=172 forced a tiny group size. Padding to
// 192 removed that constraint; the model has used gs=64 exclusively since,
// so ACC_GS_MIN=4 was doing nothing but PERMITTING a configuration
// acc_top.v cannot execute correctly.
//
// The actual hazard, found and root-caused via T036's integration
// testbench (not assumed): acc_top.v's w_scale_q/x_scale_q registers only
// re-latch once per group, on that group's own LAST address-phase word
// (gated on is_group_last_c, using group_count_q/act_group_idx_q one cycle
// before they advance -- see acc_top.v's own comment on those registers).
// That gating buys exactly ONE cycle of settle time between "this group's
// scale becomes correct" and "the next group's scale read could overwrite
// it". At gs == LANES (a group is exactly one address-phase cycle wide),
// there IS no settle cycle -- every cycle is simultaneously the last word
// of its own group AND the first word of the next, so the very race the
// gating exists to prevent reopens. At gs == 2*LANES (two address-phase
// cycles per group), the settle cycle exists and the race cannot occur --
// confirmed empirically (acc_unit_tb.py's row-interleave sweep: gs=LANES
// produces gross, orders-of-magnitude-wrong results every time; gs=2*LANES
// is clean over dozens of randomised trials once acc_mac.v's fp_add32 bug,
// a separate and unrelated issue, was also fixed -- see research R26).
//
// This is NOT the acc_mac.v row-accumulator pipeline depth (5 cycles,
// group_done -> row_valid) T030 originally worried about -- that hazard
// turned out not to be real: acc_mac's rescale pipeline is a strict
// in-order shift register with no possibility of two tokens colliding in
// one stage, regardless of injection rate (traced cycle-by-cycle and
// confirmed the row_first tag threads through correctly even at gs=LANES).
// The binding constraint is the scale-register settle time above, which is
// the much tighter bound of the two.
//
// Bound: gs/LANES >= 2, i.e. ACC_GS_MIN >= 2*LANES. LANES defaults to 4
// (acc_mac.v/acc_top.v), giving ACC_GS_MIN=8. THIS DEPENDS ON LANES: if
// LANES is ever raised, this constant MUST be revisited and re-verified
// (empirically, the same way -- see acc_unit_tb.py's
// test_row_interleave_no_gap / test_row_interleave_at_gs_min), not just
// recomputed by formula, since deriving 2*LANES=8 the first time round
// also required finding the actual mechanism rather than trusting an
// earlier (wrong) 5-cycle guess.
`define ACC_GS_MIN        8
`define ACC_GS_MAX     1024

`endif
