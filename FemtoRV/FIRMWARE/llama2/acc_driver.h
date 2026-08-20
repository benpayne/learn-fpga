/*
 * acc_driver.h -- firmware driver for the int8 MatMul accelerator
 * (feature 004-int8-matmul-accel).
 *
 * TRUTH SOURCES, in priority order (per team-lead instruction: cross-check
 * every register index and error code against the RTL, do not invent an
 * encoding, stop and report rather than silently reconciling a conflict):
 *   1. FemtoRV/RTL/ACCEL/acc_bits.vh       -- register indices, CTRL/STATUS
 *                                              bits, ERR_* codes, MODE_*,
 *                                              GS_MIN/MAX. THE single
 *                                              source acc_regs.v/acc_top.v
 *                                              both compile against.
 *   2. FemtoRV/RTL/ACCEL/acc_regs.v        -- STATUS word bit layout
 *                                              (status_word assign), which
 *                                              register indices are R vs W.
 *   3. FemtoRV/RTL/ACCEL/acc_top.v         -- slot/BRAM geometry (NUM_SLOTS,
 *                                              ACT_AWIDTH/RESULT_AWIDTH,
 *                                              ACT_XS_WORDS, LANES, MAX_N,
 *                                              MAX_D) and its acceptance
 *                                              checks (accept_range_bad /
 *                                              accept_slot_bad), read from
 *                                              its DEFAULT parameter values
 *                                              since femtosoc.v's
 *                                              instantiation only overrides
 *                                              BURST_LEN.
 *   4. FemtoRV/RTL/femtosoc.v              -- address decode for the result
 *                                              BRAM (0x100000-0x17FFFF) and
 *                                              activation BRAM
 *                                              (0x180000-0x1FFFFF), and the
 *                                              io_word_address bit ->
 *                                              IO_ACC_IDX_bit/IO_ACC_DAT_bit
 *                                              wiring.
 *   5. specs/004-int8-matmul-accel/contracts/accelerator-interface.md --
 *      cross-checked LAST, as the human-readable summary of the same
 *      facts; where it and the RTL matched, that confirms this file;
 *      nowhere did they disagree (as of this writing) -- see the build
 *      report for confirmation the check was actually made, not assumed.
 *
 * WHAT THE CONTRACT DOC DOES NOT COVER (and this file fills in from the RTL
 * directly, NOT a disagreement, just an omission the contract doc's example
 * driver sketch skips over): how the quantized activation vector actually
 * gets INTO an "x_slot" before ACC_CTRL.START is written. acc_top.v's
 * act_sel/act_addr/act_wdata port comments and its ACT_XS_WORDS/NUM_SLOTS
 * parameters are the only source for this -- see ACC_ACT_BASE and the slot
 * layout constants below.
 *
 * NOT YET IMPLEMENTED (matches the RTL's own current scope): attention
 * modes (ACC_MODE_ATT_SCORE / ACC_MODE_ATT_SUM). acc_top.v rejects any
 * mode other than ACC_MODE_MATMUL with ACC_ERR_MODE (T034) -- this driver
 * only exposes the matmul path (acc_matmul_q8) for the same reason; a
 * driver function for a mode the hardware refuses to run would be dead,
 * untestable code.
 */
#ifndef ACC_DRIVER_H
#define ACC_DRIVER_H

#include <stdint.h>

/* ===================================================================
 * Register indices (acc_bits.vh `ACC_REG_*`) -- selected via IO_ACC_IDX,
 * accessed via IO_ACC_DAT (femtorv32.h). Names mirror acc_bits.vh's macro
 * names exactly, including the non-obvious `ACC_REG_PERF_CYC` (not
 * `_CYCLES`) so a reader can grep either file and find the other.
 * =================================================================== */
#define ACC_REG_W_Q_BASE    0
#define ACC_REG_W_S_BASE    1
#define ACC_REG_X_SLOT      2
#define ACC_REG_OUT_SLOT    3
#define ACC_REG_N            4
#define ACC_REG_D            5
#define ACC_REG_GS           6
#define ACC_REG_MODE         7
#define ACC_REG_CTRL          8
#define ACC_REG_STATUS        9
#define ACC_REG_PERF_CYC      10
#define ACC_REG_PERF_STALL    11

/* CTRL bits (write) -- acc_bits.vh `ACC_CTRL_*` */
#define ACC_CTRL_START_bit    0
#define ACC_CTRL_ABORT_bit    1
#define ACC_CTRL_START        (1u << ACC_CTRL_START_bit)
#define ACC_CTRL_ABORT        (1u << ACC_CTRL_ABORT_bit)

/* STATUS bits (read) -- acc_bits.vh `ACC_STATUS_*` plus the
 * error-code/queue-depth fields from acc_regs.v's `status_word`:
 *   0 BUSY, 1 DONE, 2 ERR, 3 reserved, 7:4 error code, 15:8 queue depth. */
#define ACC_STATUS_BUSY_bit   0
#define ACC_STATUS_DONE_bit   1
#define ACC_STATUS_ERR_bit    2
#define ACC_STATUS_BUSY       (1u << ACC_STATUS_BUSY_bit)
#define ACC_STATUS_DONE       (1u << ACC_STATUS_DONE_bit)
#define ACC_STATUS_ERR        (1u << ACC_STATUS_ERR_bit)
#define ACC_STATUS_ERRCODE(status)     (((status) >> 4) & 0xFu)
#define ACC_STATUS_QUEUE_DEPTH(status) (((status) >> 8) & 0xFFu)

/* Error codes, STATUS[7:4] -- acc_bits.vh `ACC_ERR_*`. Values, not just
 * names, MUST match acc_bits.vh exactly: this is the encoding the RTL
 * actually asserts on the wire. */
#define ACC_ERR_NONE    0
#define ACC_ERR_DIM     1   /* n is not a whole number of groups */
#define ACC_ERR_GS      2   /* group size unsupported (not pow2 / out of range) */
#define ACC_ERR_RANGE   3   /* n or d exceeds configured maxima */
#define ACC_ERR_SLOT    4   /* result or activation would overflow its slot */
#define ACC_ERR_FULL    5   /* descriptor queue full (back-pressure, not a fault) */
#define ACC_ERR_MODE    6   /* mode not implemented / unrecognised */

/* Operating modes -- acc_bits.vh `ACC_MODE_*`. Only MATMUL is wired up by
 * this driver (see file header). */
#define ACC_MODE_MATMUL     0
#define ACC_MODE_ATT_SCORE  1
#define ACC_MODE_ATT_SUM    2

/* Supported group-size bounds -- acc_bits.vh `ACC_GS_MIN`/`ACC_GS_MAX`. */
#define ACC_GS_MIN     4
#define ACC_GS_MAX  1024

/* ===================================================================
 * BRAM geometry -- derived from acc_top.v's DEFAULT parameters (LANES=4,
 * MAX_N=4096, MAX_D=4096, ACT_AWIDTH=12, RESULT_AWIDTH=12, NUM_SLOTS=8,
 * ACT_XS_WORDS=32); femtosoc.v's `acc_top #(.BURST_LEN(128))` instantiation
 * overrides ONLY BURST_LEN, which does not affect any of the geometry
 * below, so the defaults are the truth for THIS build. If acc_top.v's
 * parameter list or femtosoc.v's instantiation ever changes any of these,
 * this file goes stale silently -- there is no compile-time cross-check
 * across the Verilog/C boundary for BRAM geometry the way acc_bits.vh
 * gives one for register encodings.
 * =================================================================== */
#define ACC_RESULT_BASE        0x100000u  /* femtosoc.v mem_address_is_accel_res */
#define ACC_ACT_BASE           0x180000u  /* femtosoc.v mem_address_is_accel_act */

#define ACC_NUM_SLOTS           8         /* acc_top.v NUM_SLOTS */
#define ACC_RESULT_SLOT_WORDS  512        /* (1<<RESULT_AWIDTH)/NUM_SLOTS = 4096/8; 2KB/slot */
#define ACC_ACT_SLOT_WORDS     512        /* (1<<ACT_AWIDTH)/NUM_SLOTS = 4096/8 */
#define ACC_ACT_XS_WORDS        32        /* acc_top.v ACT_XS_WORDS: trailing words of each
                                            * act slot reserved for fp32 xs scales */
#define ACC_ACT_XQ_WORDS       (ACC_ACT_SLOT_WORDS - ACC_ACT_XS_WORDS) /* 480: leading words
                                            * holding packed int8 xq, 4 elements/word */
#define ACC_LANES                4        /* acc_top.v LANES: int8 elements packed per 32-bit
                                            * xq/weight-q word, matching the target's native
                                            * little-endian byte order */

#define ACC_MAX_N            4096         /* acc_top.v MAX_N */
#define ACC_MAX_D            4096         /* acc_top.v MAX_D */

/* Largest n this driver can stage into one activation slot (both the
 * packed-xq and the xs-scale-count limits, acc_top.v accept_slot_bad):
 *   n/LANES  <= ACT_XQ_WORDS  =>  n <= ACT_XQ_WORDS*LANES = 1920
 *   n/gs     <= ACT_XS_WORDS  =>  n <= ACT_XS_WORDS*gs (gs-dependent)
 * Comfortably above this project's actual n (<=192). */
#define ACC_ACT_MAX_N          (ACC_ACT_XQ_WORDS * ACC_LANES)  /* 1920 */

/* Largest d one result slot can hold (acc_top.v accept_slot_bad:
 * desc_d > RESULT_SLOT_WORDS). */
#define ACC_RESULT_MAX_D        ACC_RESULT_SLOT_WORDS  /* 512 */

/* ===================================================================
 * Driver-level status. ACC_OK plus the RTL's ACC_ERR_* set (renamed with
 * an ACCST_ prefix to keep them textually distinct from the register-level
 * ACC_ERR_* constants above, since acc_matmul_q8() returns this enum, not
 * a raw error-code nibble), plus two driver-only outcomes that do not
 * correspond to any RTL error code: a bounds violation caught BEFORE ever
 * writing to hardware, and a poll timeout (the RTL contract's abort
 * requirement -- see acc_driver.c).
 * =================================================================== */
typedef enum {
    ACCST_OK = 0,
    ACCST_ERR_DIM,
    ACCST_ERR_GS,
    ACCST_ERR_RANGE,
    ACCST_ERR_SLOT,
    ACCST_ERR_FULL,
    ACCST_ERR_MODE,
    ACCST_ERR_TIMEOUT,   /* driver-side: STATUS.BUSY never cleared within the
                           * poll budget; the driver already issued ABORT
                           * before returning this (contracts doc: "the
                           * firmware SHOULD apply a timeout ... and abort
                           * rather than waiting forever"). */
    ACCST_ERR_UNKNOWN     /* STATUS.ERR set with an error code this driver
                           * does not recognise (future RTL added a code
                           * this header hasn't been updated for) */
} acc_status_t;

const char *acc_strerror(acc_status_t st);

typedef struct {
    uint32_t cycles;      /* PERF_CYCLES: cycles the operation was active */
    uint32_t stall;       /* PERF_STALL: of which, cycles stalled on memory --
                           * the feature's primary bandwidth-vs-control-logic
                           * diagnostic (accelerator-interface.md). */
    uint32_t queue_depth; /* STATUS[15:8] at completion/rejection time. Lets
                           * a caller tell ACCST_ERR_FULL back-pressure
                           * (queue genuinely near capacity, worth retrying
                           * once it drains) from a hardware fault
                           * masquerading as FULL (depth reported low or
                           * zero while still rejecting) WITHOUT guessing --
                           * meaningless only for ACCST_ERR_TIMEOUT, where
                           * the driver already aborted rather than reading
                           * a final STATUS. */
} acc_perf_t;

/* Write a quantized activation vector (n int8 in `q`, n/gs fp32 scales in
 * `s`) into activation BRAM slot `slot`, ready for a subsequent
 * acc_matmul_q8() call with matching x_slot. `q` MUST be 4-byte aligned
 * (the whole vector is copied as 32-bit words, matching the RTL's packing)
 * and n MUST be a multiple of ACC_LANES (4) -- both hold for every
 * quantize_activations() output in this project (dim=64, hidden_dim=192,
 * kv_dim=32, all multiples of 4). Returns ACCST_ERR_SLOT/ACCST_ERR_DIM
 * WITHOUT writing anything if the vector would not fit the slot -- this
 * mirrors, ahead of time and without touching hardware, the same
 * accept_slot_bad check acc_top.v applies when the descriptor is later
 * started. */
acc_status_t acc_load_activation(int slot, const int8_t *q, const float *s, int n, int gs);

/* Issue one MODE_MATMUL operation and block until it completes, times out,
 * or is rejected. Preconditions (contracts doc): the quantized activation
 * is already in BRAM slot `x_slot` (via acc_load_activation()); n % gs ==
 * 0; gs a supported power of two; n/d within configured maxima. `w_q`/
 * `w_s` are SDRAM byte pointers (NOT word addresses -- see acc_driver.c's
 * header comment on why the raw pointer is correct here) to one weight
 * tensor's q and s blocks (q8_format.h layout). On ACCST_OK, `d` fp32
 * results are in result BRAM slot `out_slot` (read with
 * acc_read_result()). `perf`, if non-NULL, is filled from PERF_CYCLES/
 * PERF_STALL/queue_depth regardless of outcome (except ACCST_ERR_TIMEOUT,
 * where the operation's own counters are meaningless since it never
 * finished) -- on ACCST_ERR_FULL in particular, perf->queue_depth is the
 * STATUS queue-depth field at the moment of rejection (see acc_perf_t). */
acc_status_t acc_matmul_q8(int out_slot, const int8_t *w_q, const float *w_s,
                            int x_slot, int n, int d, int gs, acc_perf_t *perf);

/* Direct STATUS queue-depth query (STATUS[15:8]), independent of any
 * operation outcome -- a single register read, safe to call anytime
 * (STATUS reads have no side effect other than clearing DONE, which this
 * driver does not otherwise rely on between operations since it always
 * blocks to completion). Useful to poll BEFORE issuing an operation this
 * driver does not currently do (it only ever runs one descriptor at a
 * time, so ACCST_ERR_FULL should not occur in practice with this blocking
 * driver) -- kept as a public primitive for a future pipelined/non-
 * blocking driver, and for acc_test.c-style diagnostics. */
uint32_t acc_queue_depth(void);

/* Copy `d` fp32 results out of result BRAM slot `slot` into `out`. Caller
 * MUST have observed ACCST_OK from the operation that wrote this slot --
 * "reading while BUSY... MUST NOT return partial data" is enforced by the
 * accelerator not being busy by the time acc_matmul_q8() returns OK, not
 * by this function (data-model.md entity 6). d MUST be <=
 * ACC_RESULT_MAX_D and within the d actually written. */
void acc_read_result(int slot, float *out, int d);

#endif
