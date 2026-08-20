/*
 * acc_driver.c -- implements acc_driver.h. See that file for the truth
 * sources this was cross-checked against (acc_bits.vh, acc_regs.v,
 * acc_top.v, femtosoc.v) and what the contract doc does/doesn't cover.
 *
 * *** Addressing: w_q/w_s are BYTE pointers, not word addresses ***
 * acc_weight_fetch.v's ADDR_WIDTH parameter comment says "SDRAM word
 * address width", which reads as if the base registers wanted a word
 * index. They do not: acc_weight_fetch.v's own state machine computes
 * `burst_addr <= op_w_q_base + q_byte_off` where `q_byte_off` is
 * incremented by 4 per WORD consumed (i.e. it IS a running byte offset),
 * and that combined address is fed straight into
 * muchtoremember_burst.v's `burst_addr`/`addr` ports, whose internal
 * column/row extraction (`burst_col <= burst_addr[9:2]`, matching every
 * other consumer of that controller in femtosoc.v, e.g. the CPU's own
 * `cache_sdram_addr`) only makes sense for a BYTE address. So
 * `op_w_q_base` itself must already be a byte address for the whole chain
 * to be internally consistent -- exactly what the contract doc's example
 * (`acc_set(ACC_W_Q_BASE, (uint32_t)w->q)`, a raw pointer cast, no shift)
 * assumes. This driver follows that: no >>2 anywhere below.
 *
 * *** Spin-loop / instruction-cache contract (accelerator-interface.md,
 * DESIGN.md sec 5.4) ***
 * cycles() (femtorv32.h) is `extern uint64_t cycles()` -- a REAL function
 * living elsewhere in the binary, not a macro. Calling it every poll
 * iteration would itself be the failure mode the contract warns about:
 * every spin would fetch cycles()'s code from a different address than
 * the poll loop's own few instructions, defeating exactly the locality
 * the contract requires. So the timeout below is a NESTED loop: an inner
 * loop that only touches ACC_REG_READ/ACC_REG_WRITE (femtorv32.h's
 * IO_OUT/IO_IN macros -- direct volatile memory access, no calls, no
 * function-pointer indirection) for ACC_POLL_CHECK_INTERVAL iterations,
 * and only THEN calls cycles() once to check the wall-clock deadline. The
 * inner loop is what needs to fit in a few cache lines, and it does not
 * call anything. Confirmed in the build's disassembly (verify_fw_math /
 * runq.list) -- see this feature's report for the actual instruction
 * count observed. ACC_POLL_CHECK_INTERVAL and ACC_TIMEOUT_CYCLES below
 * are UNTUNED placeholders (no hardware access here to measure a real
 * operation's latency) -- see the header comment on both.
 */

#include "acc_driver.h"
#include <femtorv32.h>

/* Matches the CPU_HZ convention used throughout this directory
 * (model_load.c, profile.c) -- Colorlight i5 runs at a fixed 25MHz, no
 * PLL on the CPU clock. */
#define CPU_HZ 25000000u

/* UNTUNED placeholders, see file header. 250ms is a generous first-bring-
 * up budget: even a badly stalled small matmul (this model's largest
 * tensor is dim*vocab = 64*512 = 32768 int8 weights) should complete in
 * far less time than that at any plausible clock/bandwidth; a real
 * timeout should be set from T052's measured single-operation latency
 * once that exists. ACC_POLL_CHECK_INTERVAL trades timeout granularity
 * (worst case, the deadline is discovered up to this many iterations
 * late) against how rarely cycles() is called; 4096 tight iterations is
 * a few thousand cycles at most, negligible against the 250ms budget. */
#define ACC_TIMEOUT_CYCLES        (CPU_HZ / 4)   /* 250 ms */
#define ACC_POLL_CHECK_INTERVAL   4096u

/* Index-then-data register access. Macros, not functions -- deliberately,
 * so there is zero risk of the compiler leaving a real CALL inside the
 * poll loop even at a lower optimization level than -O3 (matches the
 * project's existing GPU_WRITE/GPU_READ style in femtorv32.h). */
#define ACC_REG_WRITE(idx, val) \
    (IO_OUT(IO_ACC_IDX, (uint32_t)(idx)), IO_OUT(IO_ACC_DAT, (uint32_t)(val)))
#define ACC_REG_READ(idx) \
    (IO_OUT(IO_ACC_IDX, (uint32_t)(idx)), IO_IN(IO_ACC_DAT))

const char *acc_strerror(acc_status_t st) {
    switch (st) {
    case ACCST_OK:          return "ok";
    case ACCST_ERR_DIM:     return "n is not a whole number of groups (ERR_DIM)";
    case ACCST_ERR_GS:      return "group size unsupported, not a power of two in range (ERR_GS)";
    case ACCST_ERR_RANGE:   return "n or d exceeds configured maxima (ERR_RANGE)";
    case ACCST_ERR_SLOT:    return "result or activation would overflow its slot (ERR_SLOT)";
    case ACCST_ERR_FULL:    return "descriptor queue full (ERR_FULL)";
    case ACCST_ERR_MODE:    return "mode not implemented on this hardware (ERR_MODE)";
    case ACCST_ERR_TIMEOUT: return "operation did not complete within the poll timeout (aborted)";
    case ACCST_ERR_UNKNOWN: return "STATUS.ERR set with an error code this driver does not recognise";
    default:                return "unknown acc_status_t";
    }
}

acc_status_t acc_load_activation(int slot, const int8_t *q, const float *s, int n, int gs) {
    if (slot < 0 || slot >= ACC_NUM_SLOTS)
        return ACCST_ERR_SLOT;
    if (n <= 0 || gs <= 0 || (n % ACC_LANES) != 0 || (n % gs) != 0)
        return ACCST_ERR_DIM;

    int words_q = n / ACC_LANES;
    int groups  = n / gs;
    if (words_q > ACC_ACT_XQ_WORDS || groups > ACC_ACT_XS_WORDS)
        return ACCST_ERR_SLOT;   /* pre-empt acc_top.v's accept_slot_bad without touching hardware */

    /* q/s are copied as whole 32-bit words -- matches acc_top.v's own
     * "LANES elements/word, same packing as the weight q block" layout
     * convention, and the target CPU's native little-endian byte order
     * means a plain word-wise copy of the int8 array reproduces exactly
     * that packing. Caller MUST pass a 4-byte-aligned q (see header);
     * every quantize_activations() output in this project already is. */
    volatile uint32_t *slot_base = (volatile uint32_t *)(ACC_ACT_BASE +
                                        (uint32_t)slot * ACC_ACT_SLOT_WORDS * 4u);
    const uint32_t *qw = (const uint32_t *)(const void *)q;
    for (int i = 0; i < words_q; i++) slot_base[i] = qw[i];

    volatile uint32_t *xs_base = slot_base + ACC_ACT_XQ_WORDS;
    const uint32_t *sw = (const uint32_t *)(const void *)s;
    for (int i = 0; i < groups; i++) xs_base[i] = sw[i];

    return ACCST_OK;
}

acc_status_t acc_matmul_q8(int out_slot, const int8_t *w_q, const float *w_s,
                            int x_slot, int n, int d, int gs, acc_perf_t *perf) {
    if (out_slot < 0 || out_slot >= ACC_NUM_SLOTS || x_slot < 0 || x_slot >= ACC_NUM_SLOTS)
        return ACCST_ERR_SLOT;
    if (n <= 0 || d <= 0 || gs <= 0)
        return ACCST_ERR_DIM;
    if (n > ACC_MAX_N || d > ACC_MAX_D)
        return ACCST_ERR_RANGE;

    ACC_REG_WRITE(ACC_REG_W_Q_BASE, (uint32_t)w_q);
    ACC_REG_WRITE(ACC_REG_W_S_BASE, (uint32_t)w_s);
    ACC_REG_WRITE(ACC_REG_X_SLOT,   (uint32_t)x_slot);
    ACC_REG_WRITE(ACC_REG_OUT_SLOT, (uint32_t)out_slot);
    ACC_REG_WRITE(ACC_REG_N,        (uint32_t)n);
    ACC_REG_WRITE(ACC_REG_D,        (uint32_t)d);
    ACC_REG_WRITE(ACC_REG_GS,       (uint32_t)gs);
    ACC_REG_WRITE(ACC_REG_MODE,     ACC_MODE_MATMUL);
    ACC_REG_WRITE(ACC_REG_CTRL,     ACC_CTRL_START);

    uint32_t status = 0;
    uint64_t deadline = cycles() + (uint64_t)ACC_TIMEOUT_CYCLES;
    int timed_out = 0;

    for (;;) {
        uint32_t spins = ACC_POLL_CHECK_INTERVAL;
        int busy_cleared = 0;
        /* Inner loop: the ONLY part of this function that must fit a few
         * cache lines. No calls, no memory access outside the two IO
         * registers. */
        while (spins != 0) {
            status = ACC_REG_READ(ACC_REG_STATUS);
            if (!(status & ACC_STATUS_BUSY)) { busy_cleared = 1; break; }
            spins--;
        }
        if (busy_cleared) break;
        if (cycles() >= deadline) { timed_out = 1; break; }
    }

    if (timed_out) {
        /* Contract (accelerator-interface.md "Abort and recovery"): a
         * timeout MUST abort and report, never spin forever. */
        ACC_REG_WRITE(ACC_REG_CTRL, ACC_CTRL_ABORT);
        return ACCST_ERR_TIMEOUT;
    }

    if (perf) {
        perf->cycles      = ACC_REG_READ(ACC_REG_PERF_CYC);
        perf->stall       = ACC_REG_READ(ACC_REG_PERF_STALL);
        perf->queue_depth = ACC_STATUS_QUEUE_DEPTH(status);
    }

    if (status & ACC_STATUS_ERR) {
        switch (ACC_STATUS_ERRCODE(status)) {
        case ACC_ERR_DIM:   return ACCST_ERR_DIM;
        case ACC_ERR_GS:    return ACCST_ERR_GS;
        case ACC_ERR_RANGE: return ACCST_ERR_RANGE;
        case ACC_ERR_SLOT:  return ACCST_ERR_SLOT;
        case ACC_ERR_FULL:  return ACCST_ERR_FULL;
        case ACC_ERR_MODE:  return ACCST_ERR_MODE;
        default:            return ACCST_ERR_UNKNOWN;
        }
    }

    return ACCST_OK;
}

void acc_read_result(int slot, float *out, int d) {
    const volatile float *base = (const volatile float *)(ACC_RESULT_BASE +
                                      (uint32_t)slot * ACC_RESULT_SLOT_WORDS * 4u);
    for (int i = 0; i < d; i++) out[i] = base[i];
}

uint32_t acc_queue_depth(void) {
    return ACC_STATUS_QUEUE_DEPTH(ACC_REG_READ(ACC_REG_STATUS));
}
