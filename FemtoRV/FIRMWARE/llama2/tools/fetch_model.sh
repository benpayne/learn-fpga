#!/usr/bin/env bash
#
# fetch_model.sh - download the smallest pre-trained llama2.c model
# (karpathy's "stories260K", ~260K parameters) and its MATCHING tokenizer.
#
# IMPORTANT: stories260K was trained with a reduced, custom 512-token
# vocabulary. It must be paired with tok512.bin, NOT the default
# tokenizer.bin shipped for stories15M/42M/110M (32000 tokens). Pairing the
# wrong model/tokenizer produces fluent-looking but WRONG text with no
# error message - see specs/003-llama2-minimal-soc/data-model.md, entity 4.
#
# Source: https://huggingface.co/karpathy/tinyllamas/tree/main/stories260K
#   stories260K.bin  -- the model weights (raw llama2.c export format)
#   tok512.bin       -- the matching tokenizer, in llama2.c's binary format
#                       (tok512.model is the raw sentencepiece model, NOT
#                       what this board's loader reads - do not use it)
# The pairing is confirmed by stories260K/readme.md on that repo:
#   ./run stories260K/stories260K.bin -z stories260K/tok512.bin -t 0.0
#
# Downloads into the current directory as model.bin and tokenizer.bin.
# Idempotent: if a file already exists and its sha256 matches the known-good
# checksum below, the download is skipped.

set -euo pipefail

MODEL_URL="https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin"
TOKENIZER_URL="https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin"

MODEL_FILE="model.bin"
TOKENIZER_FILE="tokenizer.bin"

# Known-good checksums, recorded from a verified download (see README / task
# T012 report). Used only to short-circuit re-downloading; if a file is
# missing or its checksum doesn't match, it is (re)fetched from source.
MODEL_SHA256="b0a507e7ad0f626624f17112325e66691f9076d622e1d3274d103d00299f2696"
TOKENIZER_SHA256="037cb335abb25d1fa9e8ecae30ed2a3a8ace9302862ebcdc05d51a6bbb10c312"

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

# download <url> <dest> <expected_sha256>
download() {
    local url="$1" dest="$2" expected="$3"

    if [ -f "$dest" ]; then
        local actual
        actual="$(sha256_of "$dest")"
        if [ "$actual" = "$expected" ]; then
            echo "==> $dest already present and checksum matches, skipping download"
            return 0
        else
            echo "==> $dest exists but checksum does not match ($actual != $expected), re-downloading"
        fi
    fi

    echo "==> Downloading $url -> $dest"
    curl -fL --progress-bar -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
}

report_file() {
    local label="$1" file="$2"
    local size sha
    size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")"
    sha="$(sha256_of "$file")"
    echo "$label: $file"
    echo "  size:   $size bytes"
    echo "  sha256: $sha"
}

# Parse the 7 int32 LE header fields (dim, hidden_dim, n_layers, n_heads,
# n_kv_heads, vocab_size, seq_len) and check the file length implied by the
# header against the actual file length. See data-model.md entity 3.
check_model_header() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import struct
import sys
import os

path = sys.argv[1]
with open(path, "rb") as f:
    header = f.read(4 * 7)
if len(header) != 28:
    print("ERROR: %s is too short to contain a model header (%d bytes)" % (path, len(header)))
    sys.exit(1)

dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len = struct.unpack("<7i", header)

print("Model header (%s):" % path)
print("  dim         = %d" % dim)
print("  hidden_dim  = %d" % hidden_dim)
print("  n_layers    = %d" % n_layers)
print("  n_heads     = %d" % n_heads)
print("  n_kv_heads  = %d" % n_kv_heads)
print("  vocab_size  = %d (raw)  %d (abs)%s" % (
    vocab_size, abs(vocab_size),
    "  -- NEGATIVE: unshared classifier" if vocab_size < 0 else ""))
print("  seq_len     = %d" % seq_len)

fields = [dim, hidden_dim, n_layers, n_heads, n_kv_heads, abs(vocab_size), seq_len]
if any(v <= 0 for v in fields):
    print("ERROR: header field <= 0 after taking abs(vocab_size); header looks garbage")
    sys.exit(1)
SANE_MAX = 1 << 20
if any(v > SANE_MAX for v in fields):
    print("ERROR: header field > %d; header looks garbage" % SANE_MAX)
    sys.exit(1)

# Implied weight bytes, following llama2.c's checkpoint layout:
#   token_embedding_table:      vocab_size * dim
#   rms_att_weight:              n_layers * dim
#   wq:                          n_layers * dim * (n_heads * head_size)
#   wk:                          n_layers * dim * (n_kv_heads * head_size)
#   wv:                          n_layers * dim * (n_kv_heads * head_size)
#   wo:                          n_layers * (n_heads * head_size) * dim
#   rms_ffn_weight:              n_layers * dim
#   w1:                          n_layers * dim * hidden_dim
#   w2:                          n_layers * hidden_dim * dim
#   w3:                          n_layers * dim * hidden_dim
#   rms_final_weight:            dim
#   freq_cis_real:                seq_len * head_size / 2
#   freq_cis_imag:                seq_len * head_size / 2
#   (+ token_embedding_table again if vocab_size < 0, unshared classifier)
head_size = dim // n_heads
abs_vocab = abs(vocab_size)

n_params = 0
n_params += abs_vocab * dim                                   # token embedding
n_params += n_layers * dim                                    # rms_att_weight
n_params += n_layers * dim * (n_heads * head_size)             # wq
n_params += n_layers * dim * (n_kv_heads * head_size)          # wk
n_params += n_layers * dim * (n_kv_heads * head_size)          # wv
n_params += n_layers * (n_heads * head_size) * dim              # wo
n_params += n_layers * dim                                    # rms_ffn_weight
n_params += n_layers * dim * hidden_dim                        # w1
n_params += n_layers * hidden_dim * dim                        # w2
n_params += n_layers * dim * hidden_dim                        # w3
n_params += dim                                               # rms_final_weight
n_params += seq_len * head_size // 2                            # freq_cis_real
n_params += seq_len * head_size // 2                            # freq_cis_imag
if vocab_size < 0:
    n_params += abs_vocab * dim                                # unshared classifier

implied_bytes = 28 + n_params * 4  # header + fp32 weights
actual_bytes = os.path.getsize(path)

print("  implied file size = %d bytes (header + weights)" % implied_bytes)
print("  actual file size  = %d bytes" % actual_bytes)

if implied_bytes != actual_bytes:
    print("ERROR: file length does not match header-implied length "
          "(implied %d, actual %d) - file is likely truncated or corrupt"
          % (implied_bytes, actual_bytes))
    sys.exit(1)

print("  OK: file length matches header-implied length")
PYEOF
}

download "$MODEL_URL" "$MODEL_FILE" "$MODEL_SHA256"
download "$TOKENIZER_URL" "$TOKENIZER_FILE" "$TOKENIZER_SHA256"

echo
report_file "Model" "$MODEL_FILE"
echo
report_file "Tokenizer" "$TOKENIZER_FILE"
echo
check_model_header "$MODEL_FILE"

echo
echo "==> Done. $MODEL_FILE and $TOKENIZER_FILE are a matched stories260K pair."
