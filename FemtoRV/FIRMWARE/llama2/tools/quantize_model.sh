#!/usr/bin/env bash
#
# quantize_model.sh - convert the fp32 legacy llama2.c checkpoint (model.bin)
# into a Q8_0 quantized checkpoint (model.q8.bin), matching the on-disk
# layout of upstream llama2.c's export.py --version 2 / runq.c EXACTLY --
# see FemtoRV/FIRMWARE/llama2/q8_format.h, the single shared definition of
# that format read by both the host tools and the RISC-V firmware.
#
# The "clean" upstream conversion path (export.py's version2_export) starts
# from a live PyTorch model. Here the input is already a raw fp32 .bin
# checkpoint (tools/fetch_model.sh's output, legacy format), so there is no
# PyTorch model to hand to it. Instead this script ports the same math
# (export.py's quantize_q80(), verified in
# specs/004-int8-matmul-accel/research.md R1-R5) directly in Python/numpy,
# reading the legacy checkpoint's arrays and re-quantizing them into the
# version-2 Q8_0 layout by hand.
#
# Usage: ./quantize_model.sh [model.bin] [model.q8.bin] [group_size]
#   model.bin      input,  legacy fp32 checkpoint   (default: model.bin)
#   model.q8.bin   output, Q8_0 quantized checkpoint (default: model.q8.bin)
#   group_size     requested GS                      (default: 64)
#
# Group size backoff: starts at the requested value (default 64) and halves
# while ANY quantized tensor's element count is not evenly divisible by it
# (upstream export.py only backs off against `dim`, but every quantized
# tensor must divide evenly -- it asserts this right before quantizing --
# so checking all of them is the correct general rule; research R3).
#
# freq_cis tables: the legacy input carries precomputed
# freq_cis_real/freq_cis_imag RoPE tables after rms_final_weight (see
# model_load.c's weight_bytes() comment -- that's what makes the legacy
# file's size come out to exactly 1,056,512 weight bytes for stories260K).
# The version-2 Q8_0 format does NOT store them: runq.c recomputes RoPE
# with powf/sinf/cosf at runtime instead of a table lookup. This script
# reads past them and DROPS them -- that is intentional (research R1), and
# it prints a note saying so.
#
# RMSNorm weights (rms_att_weight, rms_ffn_weight, rms_final_weight) are
# NOT quantized -- upstream runq.c keeps them fp32 (research R1's
# memory_map_weights() reads them straight as floats before any
# QuantizedTensor). Only the big matmul matrices and the token embedding
# table are quantized.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_IN="${1:-$SCRIPT_DIR/model.bin}"
MODEL_OUT="${2:-$SCRIPT_DIR/model.q8.bin}"
GROUP_SIZE="${3:-64}"

if [ ! -f "$MODEL_IN" ]; then
    echo "ERROR: input checkpoint not found: $MODEL_IN" >&2
    echo "       (run ./fetch_model.sh first, or pass an explicit path)" >&2
    exit 1
fi

python3 - "$MODEL_IN" "$MODEL_OUT" "$GROUP_SIZE" <<'PYEOF'
import sys
import os
import struct
import hashlib

import numpy as np

MODEL_IN, MODEL_OUT, REQUESTED_GS = sys.argv[1], sys.argv[2], int(sys.argv[3])

Q8_MAGIC = 0x616b3432
Q8_VERSION = 2
HEADER_BYTES = 256

with open(MODEL_IN, "rb") as f:
    header = f.read(4 * 7)
    if len(header) != 28:
        print("ERROR: input file too short to contain the 28-byte legacy header", file=sys.stderr)
        sys.exit(1)
    dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_raw, seq_len = struct.unpack("<7i", header)

    shared_classifier = 1 if vocab_raw > 0 else 0
    vocab_size = abs(vocab_raw)
    head_size = dim // n_heads
    kv_dim = n_kv_heads * head_size

    print("Legacy fp32 checkpoint header (%s):" % MODEL_IN)
    print("  dim=%d hidden_dim=%d n_layers=%d n_heads=%d n_kv_heads=%d "
          "vocab_size=%d seq_len=%d shared_classifier=%d"
          % (dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len, shared_classifier))

    def rd(n):
        arr = np.fromfile(f, dtype="<f4", count=n)
        if arr.size != n:
            print("ERROR: short read from %s: expected %d floats, got %d"
                  % (MODEL_IN, n, arr.size), file=sys.stderr)
            sys.exit(1)
        return arr

    # Legacy layout order, matching model_load.c's weight_bytes() and
    # upstream legacy_export()/checkpoint_init_weights(): every field
    # across ALL layers before moving to the next field (not interleaved
    # by layer).
    tok_emb   = rd(vocab_size * dim)
    rms_att   = rd(n_layers * dim)
    wq        = [rd(dim * dim) for _ in range(n_layers)]
    wk        = [rd(dim * kv_dim) for _ in range(n_layers)]
    wv        = [rd(dim * kv_dim) for _ in range(n_layers)]
    wo        = [rd(dim * dim) for _ in range(n_layers)]
    rms_ffn   = rd(n_layers * dim)
    w1        = [rd(dim * hidden_dim) for _ in range(n_layers)]
    w2        = [rd(hidden_dim * dim) for _ in range(n_layers)]
    w3        = [rd(dim * hidden_dim) for _ in range(n_layers)]
    rms_final = rd(dim)
    freq_real = rd(seq_len * (head_size // 2))
    freq_imag = rd(seq_len * (head_size // 2))
    wcls = None
    if not shared_classifier:
        wcls = rd(vocab_size * dim)

    leftover = f.read()
    if leftover:
        print("WARNING: %d unexpected trailing bytes in %s beyond the layout implied "
              "by its own header -- ignored" % (len(leftover), MODEL_IN), file=sys.stderr)

print()
print("Dropping freq_cis_real/freq_cis_imag RoPE tables (%d + %d floats, %d bytes): "
      "NOT part of the Q8_0 (version 2) format -- runq.c recomputes RoPE from powf/sinf/cosf "
      "at runtime instead of a table lookup. This is intentional, not data loss."
      % (freq_real.size, freq_imag.size, (freq_real.size + freq_imag.size) * 4))

# Matrices that get quantized, in the SAME order runq.c's memory_map_weights()
# expects them to appear on disk (research R1 / q8_format.h):
#   q_tokens(1), wq(n_layers), wk(n_layers), wv(n_layers), wo(n_layers),
#   w1(n_layers), w2(n_layers), w3(n_layers), [wcls(1) iff not shared]
quant_matrices = [tok_emb] + wq + wk + wv + wo + w1 + w2 + w3
if wcls is not None:
    quant_matrices.append(wcls)

# ---- group size: back off (halve) while any tensor doesn't divide evenly ----
def gs_divides_all(gs):
    return all(m.size % gs == 0 for m in quant_matrices)

gs = REQUESTED_GS
backoff_occurred = False
while gs > 1 and not gs_divides_all(gs):
    gs //= 2
    backoff_occurred = True
    print("BACKOFF: reducing group size to %d (a tensor size was not a multiple of the "
          "previous group size)" % gs, file=sys.stderr)
if not gs_divides_all(gs):
    print("ERROR: no group size >= 1 evenly divides every quantized tensor", file=sys.stderr)
    sys.exit(1)

# ---- Q8_0 symmetric quantization, matching export.py's quantize_q80() ----
def quantize_q80(flat, group_size):
    assert flat.size % group_size == 0
    groups = flat.astype(np.float32).reshape(-1, group_size)
    wmax = np.abs(groups).max(axis=1).astype(np.float32)
    # Defensive only: upstream would produce scale=0 -> 0/0 for an
    # all-zero group (never observed in practice for a trained model).
    # Guarding it avoids a NaN without changing the result for any real
    # group -- a zero group quantizes to all-zero either way.
    scale_safe = np.where(wmax == 0, np.float32(1.0), wmax / np.float32(127.0))
    quant = groups / scale_safe[:, None]
    # round-half-to-even (numpy's default, matches torch.round -- both are
    # IEEE-754 "round to nearest, ties to even" -- used by export.py)
    rounded = np.round(quant)
    q = np.clip(rounded, -127, 127).astype(np.int8).reshape(-1)
    s = np.where(wmax == 0, np.float32(0.0), wmax / np.float32(127.0))
    return q, s

with open(MODEL_OUT, "wb") as out:
    # ---- 256-byte header (q8_format.h Q8Header) ----
    out.write(struct.pack("<I", Q8_MAGIC))
    out.write(struct.pack("<i", Q8_VERSION))
    out.write(struct.pack("<7i", dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len))
    out.write(struct.pack("<B", shared_classifier))
    out.write(struct.pack("<i", gs))
    pad = HEADER_BYTES - out.tell()
    assert pad >= 0, "header fields overflow the 256-byte budget"
    out.write(b"\0" * pad)
    assert out.tell() == HEADER_BYTES

    # ---- fp32, NOT quantized (research R1) ----
    rms_att.astype("<f4").tofile(out)
    rms_ffn.astype("<f4").tofile(out)
    rms_final.astype("<f4").tofile(out)

    # ---- quantized tensors: each owns its own [q block][s block] pair ----
    max_group_err = 0.0
    for m in quant_matrices:
        q, s = quantize_q80(m, gs)
        q.tofile(out)
        s.astype("<f4").tofile(out)
        deq = (q.astype(np.float32).reshape(-1, gs) * s[:, None]).reshape(-1)
        err = float(np.abs(deq - m).max())
        if err > max_group_err:
            max_group_err = err

out_size = os.path.getsize(MODEL_OUT)
in_size = os.path.getsize(MODEL_IN)

sha = hashlib.sha256()
with open(MODEL_OUT, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        sha.update(chunk)

quant_param_count = sum(m.size for m in quant_matrices)
quant_byte_count = sum(m.size + (m.size // gs) * 4 for m in quant_matrices)
bytes_per_param = quant_byte_count / quant_param_count
total_param_count = quant_param_count + rms_att.size + rms_ffn.size + rms_final.size

print()
print("Wrote %s" % MODEL_OUT)
print("  output size:              %d bytes" % out_size)
print("  sha256:                   %s" % sha.hexdigest())
if backoff_occurred:
    print("  group size used:         %d  *** BACKED OFF from requested %d ***" % (gs, REQUESTED_GS))
    print("  *** WARNING: group size is NOT 64 -- every storage/lane-framing figure")
    print("  *** in the spec that assumes GS=64 needs revisiting. ***")
else:
    print("  group size used:         %d (no backoff, as expected)" % gs)
print("  bytes/parameter (quant):  %.4f  (%.4f = 1 + 4/GS expected at GS=%d)"
      % (bytes_per_param, 1.0 + 4.0 / gs, gs))
print("  total parameters:         %d  (%d quantized + %d fp32 rmsnorm)"
      % (total_param_count, quant_param_count, total_param_count - quant_param_count))
print("  fp32 original size:       %d bytes" % in_size)
print("  size ratio (q8/fp32):     %.4f  (%.1f%% of fp32 size)" % (out_size / in_size, 100.0 * out_size / in_size))
print("  max quantization error across all groups: %.6g" % max_group_err)
PYEOF
