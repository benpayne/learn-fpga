# Contract: Build and Verification

**Branch**: `004-int8-matmul-accel`

---

## Host-side: quantization

```
(cd FIRMWARE/llama2/tools && ./quantize_model.sh)
```

**Postconditions**: produces a Q8_0 checkpoint with magic `0x616b3432`, version 2, and a
256-byte header; prints its size, checksum, group size, and the resulting bytes-per-parameter.

**MUST**: report the size ratio against the fp32 original, since SC-003 is stated as a ratio.

---

## Host-side: the golden reference

```
(cd FIRMWARE/llama2/tools && ./runq_host <model.q8> <tokenizer> --seed N --steps M)
```

**Postconditions**: generates text and, on request, dumps intermediate dot-product results for a
given layer and matrix.

**This is the definition of correct** for stages 2, 4, 5 and 6. Its output must be reproducible
from a fixed seed.

---

## Simulation

```
(cd TEST && make MODULE=acc_mac_tb    SIM=icarus)   # stage 0
(cd TEST && make MODULE=acc_unit_tb   SIM=icarus)   # stage 1
(cd TEST && make MODULE=acc_arb_tb    SIM=icarus)   # stage 2
```

**Exit criteria**
- `acc_mac_tb`: bit-identical to the host reference over >= 1000 randomised cases (SC-005).
- `acc_unit_tb`: bit-identical for the model's real matrix shapes; FIFO never underruns.
- `acc_arb_tb`: reports accelerator words/cycle and CPU worst-case latency at several synthetic
  CPU load levels and several burst lengths.

**Note**: `TEST/Makefile` selects sources per `MODULE`; new testbenches need an entry there,
following the existing `sdram_burst_tb` pattern.

---

## Build

```
cd FemtoRV
make colorlight_i5_llm.firmware_config
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth
cp femtosoc.bit femtosoc_llm.bit
```

**Postconditions**: resource report shows >= 25% logic free (SC-013) and timing met at the
target frequency.

**Regression, required (SC-014, FR-021)**:

```
make colorlight_i5.synth      # full profile must still build and behave as before
```

This matters more than in feature 003, because this feature **changes shared RTL** — the
memory-controller arbitration. The full profile depends on the old priority. Either parameterise
it or gate it on the profile, and run this check after any arbitration change.
