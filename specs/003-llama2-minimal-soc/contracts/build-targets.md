# Contract: Build Targets

**Branch**: `003-llama2-minimal-soc`

The host-side interface. Everything here is verifiable without the board, and is what
SC-001 and SC-011 are checked against.

---

## Device image

```
make colorlight_i5_llm.synth
```

**Preconditions**: clean checkout; RISC-V toolchain and synthesis tools on PATH.

**Postconditions**
- `femtosoc.bit` exists and is programmable.
- A resource report is emitted naming logic, memory-block, multiplier, and PLL utilisation.
- Completes in under 10 minutes (SC-001).

**Must not**: require editing any file to select the profile, or require the font data file
that the full profile copies in — that is a GPU dependency and must not appear here.

---

## Regression: the existing profile still works

```
make colorlight_i5.synth
```

**Postconditions**: succeeds, and its output is unchanged from before this feature (SC-011).
This is the guard on FR-002 and should be run at least once after the dispatcher in
`femtosoc_config.v` is edited, since that file is shared by both profiles.

---

## Programs

```
(cd FIRMWARE && make libs)
(cd FIRMWARE/monitor && make clean monitor.hex)
(cd FIRMWARE/llama2 && make llama2.bin)
```

**Postconditions**: `monitor.hex` is embedded in the device image at synthesis; `llama2.bin`
is a raw binary linked at `0x800000`, suitable for XMODEM upload.

**Note**: the firmware build reads `FIRMWARE/config.mk`, which is generated from whichever
profile was last configured. Building programs for this profile requires that the profile's
config has been generated first, or the architecture flags and RAM size will be wrong.

---

## Host-side artifact preparation

```
(cd FIRMWARE/llama2/tools && ./fetch_model.sh)
```

**Postconditions**: produces `model.bin` and `tokenizer.bin` for copying to the card, and
prints the byte length and a checksum of each so the on-board verification in FR-011 has
something to compare against.

**Must**: fetch the reduced-vocabulary tokenizer matching the model, not the default one
shipped for larger models (data-model entity 4).
