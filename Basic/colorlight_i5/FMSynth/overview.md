# FM Synthesis Module for Colorlight i5

## What This Is

A standalone 2-operator FM synthesizer implemented in Verilog, targeting the **Colorlight i5 v7.0** board with its carrier board. Press one of 4 buttons to play notes from a C major chord (C4, E4, G4, C5). Audio output is a PWM signal on a GPIO pin.

## Architecture

```
fm_synth_top.v          Board top-level: buttons, PWM DAC, LED
├── fm_synth.v          FM synthesis core: sample clock, wiring, mixing
│   ├── fm_operator.v   Modulator: phase accumulator + sine table
│   ├── fm_operator.v   Carrier: phase accumulator + sine table + FM input
│   ├── fm_envelope.v   Modulator ADSR envelope
│   └── fm_envelope.v   Carrier ADSR envelope
└── sine_table.hex      Quarter-wave sine ROM (256 x 16-bit)
```

### Signal Flow (FM Algorithm)

```
midi_note -> phase_inc * mod_ratio -> [Mod Phase Acc] -> [Sine] -> (* mod_envelope * mod_depth)
                                                                         |
                                                                         v  (phase modulation)
midi_note -> phase_inc -----------> [Car Phase Acc + FM] -> [Sine] -> (* car_envelope) -> PCM out -> PWM
```

### Key Parameters (hard-coded in fm_synth_top.v)

| Parameter | Value | Meaning |
|-----------|-------|---------|
| MOD_RATIO | 2.0 (8.8 fixed-point) | Modulator freq = 2x carrier |
| MOD_DEPTH | 2048 | Moderate FM index (~β 1.4) |
| Sample Rate | 48 kHz | Standard audio rate |
| PWM bits | 8 | ~97.6 kHz PWM frequency |
| CAR_ATTACK | ~5ms | Fast note onset |
| CAR_SUSTAIN | 80% | Loud sustained tone |
| MOD_DECAY | ~500ms | Timbre mellows over time |
| MOD_SUSTAIN | 40% | Less FM in sustained portion |

## Hardware Setup (Colorlight i5 + Carrier Board)

### FPGA Details
- **Chip**: LFE5U-25F-6BG381C (ECP5 25K)
- **Clock**: 25 MHz on pin P3
- **Package**: CABGA381
- **nextpnr flags**: `--25k --package CABGA381 --speed 6`

### Pin Assignments (edit `colorlight_i5.lpf` to match your wiring)

| Signal | Default Pin | Carrier Header | Function |
|--------|-------------|----------------|----------|
| clk_i | P3 | (on-module) | 25 MHz clock |
| led_o | U16 | (on-module) | Active-low LED, lights when note playing |
| btn[0] | K18 | P2_3 | Button -> C4 (261.6 Hz) |
| btn[1] | T18 | P2_4 | Button -> E4 (329.6 Hz) |
| btn[2] | R17 | P2_5 | Button -> G4 (392.0 Hz) |
| btn[3] | M17 | P2_6 | Button -> C5 (523.3 Hz) |
| audio_out | U18 | P2_7 | PWM audio output |

### Button Wiring

Buttons are configured with internal pull-down resistors (PULLMODE=DOWN). Wire each button between the GPIO pin and 3.3V. When pressed, the pin goes high.

```
3.3V ----[button]---- P2_3 (GPIO pin)
                       |
                   (internal pull-down to GND)
```

### Audio Output

Connect a speaker or amplifier between the `audio_out` pin (P2_7 = U18) and GND. For a passive speaker, use a series resistor (100-330 ohm). For an amplifier module, connect directly.

```
P2_7 ---[330Ω]---[speaker]--- GND
```

## Build & Program

Requires: `yosys`, `nextpnr-ecp5`, `ecppack`, `ecpdap`

```bash
cd Basic/colorlight_i5/FMSynth
make              # synthesize + place & route + bitstream
make prog         # program via ecpdap (JTAG)
make prog_flash   # program to flash (persistent)
```

## Testing

### Simulation Tests (requires `iverilog`)

```bash
sudo apt-get install iverilog   # install simulator
make test                        # run all tests
make test_operator               # test sine oscillator only
make test_envelope               # test ADSR envelope only
make test_synth                  # integration test
```

Tests produce VCD waveform files in `tests/` viewable with GTKWave.

### Test Coverage

| Test | File | What It Verifies |
|------|------|-----------------|
| tb_fm_operator | tests/tb_fm_operator.v | Sine output range, oscillation, phase reset, frequency scaling |
| tb_fm_envelope | tests/tb_fm_envelope.v | ADSR state machine: attack/decay/sustain/release, re-trigger |
| tb_fm_synth | tests/tb_fm_synth.v | Sample rate, silence when off, sound when on, FM harmonics, note change, release fade |

### Hardware Testing Checklist

1. Program the board with `make prog`
2. Verify LED turns ON (active low) when any button is pressed
3. Press FIRE1 -> hear C4 tone through speaker
4. Press UP -> hear E4 (higher pitch)
5. Press DOWN -> hear G4 (higher still)
6. Press LEFT -> hear C5 (octave above C4)
7. Release button -> tone fades out (~100ms release)
8. If no sound: check audio_out pin with oscilloscope, should show PWM signal

## File Listing

```
Basic/colorlight_i5/FMSynth/
├── fm_synth_top.v       # Board top-level (buttons, PWM, LED)
├── fm_synth.v           # FM synthesis core
├── fm_operator.v        # Phase accumulator + sine lookup
├── fm_envelope.v        # ADSR envelope generator
├── sine_table.hex       # Quarter-wave sine ROM data (256 entries)
├── colorlight_i5.lpf    # Pin constraints (edit for your wiring)
├── Makefile             # Build + test targets
├── overview.md          # This file
└── tests/
    ├── tb_fm_operator.v # Operator unit test
    ├── tb_fm_envelope.v # Envelope unit test
    └── tb_fm_synth.v    # Integration test
```

## Future Work

- I2S DAC output (higher audio quality than PWM)
- MIDI input via UART (31.25 kbaud)
- Polyphony (multiple simultaneous notes)
- Configurable FM parameters via buttons/UART
- Additional waveforms (saw, square, triangle)
- Integration with FemtoRV SoC as a memory-mapped peripheral
