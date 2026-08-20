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

// ---- Operating modes ----
`define ACC_MODE_MATMUL    2'd0
`define ACC_MODE_ATT_SCORE 2'd1
`define ACC_MODE_ATT_SUM   2'd2

// ---- Supported group-size bounds ----
// Lower bound is 4, deliberately not 64: research R16 found a real model whose
// only valid group size was 4 before hidden_dim padding was adopted. Do not
// narrow this to the value the current model happens to use.
`define ACC_GS_MIN        4
`define ACC_GS_MAX     1024

`endif
