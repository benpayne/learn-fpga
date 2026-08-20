"""
IMPORTANT — how the input dumps MUST be produced.

Both .logt files must come from TEACHER-FORCED runs over the SAME token
sequence: give both models an identical long prompt and let them consume it,
then compare only the prompt positions.

Do NOT compare free-running generations. Two models that sample even one
different token are thereafter processing different text, and their logits at
every later position are incomparable. Measured on this project: free-running
dumps of the same model pair gave a mean KL of 7.77 nats and 34% top-1
agreement, while teacher-forcing the identical pair gave 0.000216 nats and
100% agreement. The first number is an artefact of sequence divergence, not
quantization error, and it is large enough to look like a catastrophic result.

Recipe:
    STORY=$(./run_host -s 2026 -n 210 -p "Once upon a time")   # any fixed text
    ./run_host   ... -p "$STORY" --dump-logits fp32.logt
    ./runq_host  ... -i "$STORY" --dump-logits q8.logt
    python3 kl_compare.py fp32.logt q8.logt --max-positions <prompt token count>

Compare only positions the prompt covers; positions past it are free-running
again and must be excluded.
"""
#!/usr/bin/env python3
"""kl_compare.py -- compare fp32 vs quantized model logits via KL divergence.

Reads two ".logt" logit dump files (one produced by the fp32 host reference,
one by the quantized/accelerated path, from the SAME prompt and seed so
positions correspond 1:1) and reports how far the quantized model's output
distribution has drifted from the full-precision one.

File format (fixed, both producers agree on this):

    int32   magic      = 0x4C4F4754   ('LOGT', little-endian)
    int32   n_positions
    int32   vocab_size
    float32 logits[n_positions * vocab_size]   // row-major, one row/position

This is the gate for T014 (SC-002): mean KL < 0.01 nats AND top-1 agreement
> 95% over at least 200 matched positions decides whether the project keeps
8-bit weights or falls back to 16-bit floating point.
"""

import argparse
import json
import struct
import sys

import numpy as np

MAGIC = 0x4C4F4754
HEADER_STRUCT = "<iii"
HEADER_SIZE = struct.calcsize(HEADER_STRUCT)

KL_THRESHOLD_NATS = 0.01
TOP1_THRESHOLD = 0.95
DEFAULT_MIN_POSITIONS = 200
EPSILON = 1e-12

CAVEAT = (
    "CAVEAT: the mean-KL < 0.01 nats and top-1 agreement > 95% thresholds are "
    "drawn from published quantization studies on models orders of magnitude "
    "larger than this ~260K-parameter one. They inform this decision; they do "
    "not automatically make it -- a reading of the generated text is still "
    "the final judgement."
)


class LogtError(ValueError):
    """Raised for anything wrong with a .logt file's contents."""


def read_logt(path):
    """Read a .logt file, returning (n_positions, vocab_size, logits[N,V])."""
    try:
        with open(path, "rb") as f:
            header = f.read(HEADER_SIZE)
            if len(header) < HEADER_SIZE:
                raise LogtError(
                    f"{path}: file too short ({len(header)} bytes) to contain "
                    f"a {HEADER_SIZE}-byte header"
                )
            magic, n_positions, vocab_size = struct.unpack(HEADER_STRUCT, header)
            if magic != MAGIC:
                raise LogtError(
                    f"{path}: bad magic 0x{magic & 0xFFFFFFFF:08X}, "
                    f"expected 0x{MAGIC:08X} ('LOGT')"
                )
            if n_positions <= 0 or vocab_size <= 0:
                raise LogtError(
                    f"{path}: invalid header n_positions={n_positions} "
                    f"vocab_size={vocab_size} (must be positive)"
                )

            expected_floats = n_positions * vocab_size
            expected_bytes = expected_floats * 4
            data = f.read()

            if len(data) < expected_bytes:
                raise LogtError(
                    f"{path}: truncated -- header declares "
                    f"{n_positions} x {vocab_size} = {expected_floats} floats "
                    f"({expected_bytes} bytes), but only {len(data)} bytes of "
                    f"logit data are present"
                )

            arr = np.frombuffer(data[:expected_bytes], dtype="<f4",
                                 count=expected_floats)
            logits = arr.reshape(n_positions, vocab_size).astype(np.float64)
    except OSError as e:
        raise LogtError(f"{path}: cannot open/read ({e})") from e

    return n_positions, vocab_size, logits


def softmax(logits):
    """Numerically stable row-wise softmax. logits: (N, V) -> probs (N, V)."""
    row_max = logits.max(axis=1, keepdims=True)
    shifted = logits - row_max
    exp = np.exp(shifted)
    return exp / exp.sum(axis=1, keepdims=True)


def kl_per_position(p, q, epsilon):
    """Row-wise KL(P||Q) in nats. p, q: (N, V) probability rows."""
    q_clamped = np.clip(q, epsilon, 1.0)
    # 0 * log(0/anything) is defined as 0 (standard KL convention); mask
    # out terms where P==0 so we never touch log(0) or produce NaN.
    with np.errstate(divide="ignore", invalid="ignore"):
        log_ratio = np.where(p > 0.0, np.log(p / q_clamped), 0.0)
    return np.sum(p * log_ratio, axis=1)


def top5_overlap(p, q):
    """Mean size of the intersection of each row's top-5 index sets."""
    top5_p = np.argsort(-p, axis=1)[:, :5]
    top5_q = np.argsort(-q, axis=1)[:, :5]
    overlaps = [
        len(set(top5_p[i].tolist()) & set(top5_q[i].tolist()))
        for i in range(p.shape[0])
    ]
    return float(np.mean(overlaps))


def compare(fp32_path, quant_path, min_positions=DEFAULT_MIN_POSITIONS,
            epsilon=EPSILON):
    n_p, vocab_p, logits_p = read_logt(fp32_path)
    n_q, vocab_q, logits_q = read_logt(quant_path)

    if vocab_p != vocab_q:
        raise LogtError(
            f"vocab_size mismatch: {fp32_path} has {vocab_p}, "
            f"{quant_path} has {vocab_q} -- these are not comparable runs"
        )

    n = min(n_p, n_q)
    if n < min_positions:
        raise LogtError(
            f"not enough matched positions: {fp32_path} has {n_p}, "
            f"{quant_path} has {n_q}, only {n} in common, but at least "
            f"{min_positions} are required"
        )

    logits_p = logits_p[:n]
    logits_q = logits_q[:n]

    p = softmax(logits_p)
    q = softmax(logits_q)

    kl = kl_per_position(p, q, epsilon)

    argmax_p = p.argmax(axis=1)
    argmax_q = q.argmax(axis=1)
    top1_agreement = float(np.mean(argmax_p == argmax_q))

    result = {
        "positions_compared": int(n),
        "vocab_size": int(vocab_p),
        "kl_mean_nats": float(np.mean(kl)),
        "kl_median_nats": float(np.median(kl)),
        "kl_p99_nats": float(np.percentile(kl, 99)),
        "kl_max_nats": float(np.max(kl)),
        "top1_agreement": top1_agreement,
        "top5_overlap_mean": top5_overlap(p, q),
        "thresholds": {
            "kl_mean_nats": KL_THRESHOLD_NATS,
            "top1_agreement": TOP1_THRESHOLD,
        },
    }
    result["kl_pass"] = result["kl_mean_nats"] < KL_THRESHOLD_NATS
    result["top1_pass"] = result["top1_agreement"] > TOP1_THRESHOLD
    result["verdict"] = (
        "PASS" if (result["kl_pass"] and result["top1_pass"]) else "FAIL"
    )
    result["caveat"] = CAVEAT
    return result


def print_report(r):
    print(f"Positions compared: {r['positions_compared']}")
    print(f"Vocab size:         {r['vocab_size']}")
    print()
    print("KL divergence D(P_fp32 || Q_quant), nats:")
    print(f"  mean   = {r['kl_mean_nats']:.6f}")
    print(f"  median = {r['kl_median_nats']:.6f}")
    print(f"  p99    = {r['kl_p99_nats']:.6f}")
    print(f"  max    = {r['kl_max_nats']:.6f}")
    print()
    print(f"Top-1 agreement:  {r['top1_agreement'] * 100:.2f}%")
    print(f"Top-5 overlap:    {r['top5_overlap_mean']:.3f} / 5 (mean intersection size)")
    print()
    print(f"SC-002 threshold check: mean KL < {KL_THRESHOLD_NATS} nats "
          f"AND top-1 agreement > {TOP1_THRESHOLD * 100:.0f}%")
    kl_margin = KL_THRESHOLD_NATS - r["kl_mean_nats"]
    top1_margin = (r["top1_agreement"] - TOP1_THRESHOLD) * 100
    print(f"  mean KL:         {r['kl_mean_nats']:.6f} nats  "
          f"(threshold {KL_THRESHOLD_NATS})  margin={kl_margin:+.6f}  "
          f"{'OK' if r['kl_pass'] else 'FAIL'}")
    print(f"  top-1 agreement: {r['top1_agreement'] * 100:.2f}%       "
          f"(threshold {TOP1_THRESHOLD * 100:.0f}%)  margin={top1_margin:+.2f}pp  "
          f"{'OK' if r['top1_pass'] else 'FAIL'}")
    print()
    print(f"VERDICT: {r['verdict']}")
    print()
    print(CAVEAT)


def main():
    ap = argparse.ArgumentParser(
        description="Compare fp32 vs quantized model logits via KL divergence "
                    "(SC-002 gate for feature 004-int8-matmul-accel)."
    )
    ap.add_argument("fp32_file", help="path to .logt dump from the fp32 host reference")
    ap.add_argument("quant_file", help="path to .logt dump from the quantized model")
    ap.add_argument("--json", action="store_true",
                     help="emit machine-readable JSON instead of the text report")
    ap.add_argument("--min-positions", type=int, default=DEFAULT_MIN_POSITIONS,
                     help=f"minimum matched positions required (default {DEFAULT_MIN_POSITIONS})")
    ap.add_argument("--epsilon", type=float, default=EPSILON,
                     help=f"floor applied to Q before dividing/logging (default {EPSILON})")
    args = ap.parse_args()

    try:
        result = compare(args.fp32_file, args.quant_file,
                          min_positions=args.min_positions,
                          epsilon=args.epsilon)
    except LogtError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_report(result)

    sys.exit(0 if result["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
