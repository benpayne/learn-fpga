# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **learn-fpga** by Bruno Levy - an educational repository for learning FPGA design, Yosys/nextpnr toolchain, and RISC-V processor design. The centerpiece is **FemtoRV**, a minimalistic RISC-V CPU designed for teaching and embedded applications.

**Your Custom Work (2024-2026):**
- Added PS2 keyboard controller with interrupt support and scan code decoder
- Created custom interrupt controller for FemtoRV (32 sources, edge-triggered)
- HDMI display GPU with per-character 16-color text mode + bitmap graphics + SDRAM framebuffer
- 4-voice 4-operator FM synthesizer with I2S output + sampled audio ring buffer
- SDRAM controller with burst reads, write-through cache, and video scanline fetch
- BIOS monitor with SD card boot and XMODEM upload
- RetroKernel: Unix-style shell with FAT32 filesystem, program loader
- Modified FemtoRV processors to integrate interrupts
- Target: Colorlight i5 board (ECP5 FPGA)
- **Use Case**: Retro computing co-processor - providing modern peripherals (PS2 keyboard, graphics, audio) to vintage CPUs (68k, 6502, 8086/286, Z80)

## Repository Structure

### Core Directories

- **FemtoRV/** - The main RISC-V CPU project
  - `RTL/PROCESSOR/` - CPU core variants (quark, electron, intermissum, gracilis, petitbateau)
  - `RTL/DEVICES/` - Peripheral devices (UART, LED, SPI, **YOUR PS2 controller**)
  - `RTL/femtosoc.v` - Complete SoC wrapper
  - `FIRMWARE/` - Example bare-metal programs, libraries
  - `TUTORIALS/` - Step-by-step CPU design tutorials
  - `BOARDS/` - Board-specific pin definitions
  - `TEST/` - Cocotb testbenches

- **Basic/** - Simple FPGA examples (blinker, UART, LED matrix, OLED)
- **LiteX/** - LiteX integration examples
- **Tools/** - Utility scripts
- **Notes/** - Development notes

### Your Custom Files

Located in `FemtoRV/RTL/DEVICES/`:
- `PS2Decoder.v` - PS2 keyboard controller (with interrupts)
- `InterruptController.v` - 32-source interrupt controller
- `Interrupt_bits.v` - Interrupt bit definitions
- `HardwareConfig_bits.v` - IO address bit assignments
- `cache.v` - 64-entry direct-mapped write-through SDRAM cache with RMW
- `synth/` - FM synthesizer (4-voice 4-op TDM, I2S, sine ROM, registers)
- `synth/audio_ringbuf.v` - 1024x16-bit sampled audio ring buffer (48kHz)

Located in `FemtoRV/RTL/SDRAM/`:
- `muchtoremember_burst.v` - Unified SDRAM controller (single-word + burst reads, row-crossing)
- `video_fetch_engine.v` - Scanline burst reader for framebuffer mode
- `video_line_buffer.v` - Ping-pong double line buffer (320 words × 2)

Located in `FemtoRV/lib/ps2-controller-lib/` (git submodule):
- PS2 decoder core, debounce, FIFO sub-modules

Located in `FemtoRV/lib/hdmi-display-lib/` (shared with retrocpu):
- `rtl/core/` - TMDS encoder, DVI transmitter, VGA timing generator
- `rtl/character/` - Character GPU: buffer, renderer, font ROM, registers
- `rtl/graphics/` - Graphics GPU: VRAM, palette, pixel renderer (1/2/4 BPP)
- `rtl/gpu_top.v` - Top-level GPU with char+graphics+framebuffer mux
- `wrappers/fpga/gpu_femtorv_wrapper.v` - FemtoRV 32-bit bus adapter
- `clock/gpu_pll.v` - ECP5 PLL for 25MHz pixel + 125MHz TMDS
- `data/font_data.hex` - 8x16 VGA font bitmap

Located in `FemtoRV/FIRMWARE/`:
- `monitor/` - BIOS monitor (SD boot, XMODEM upload, memory commands)
- `retrokernel/` - RetroKernel v0.1 (Unix shell, FAT32, program loader)
- `examples/` - User programs (bench, fbtest, showimg, play, sndtest, edit, etc.)
- `LIBFEMTORV32/ps2_keymap.h` - PS2 scan code to ASCII decoder with modifiers
- `gpu_text/` - HDMI text demo (16 colors, keyboard echo, scrolling)
- `blinky/` - Interrupt-driven PS2 keyboard + timer demo

Located in `FemtoRV/TOOLS/`:
- `xmodem_upload.py` - XMODEM binary uploader for BIOS monitor
- `kernel_upload.py` - File uploader for RetroKernel (load command)

Located in `FemtoRV/TEST/`:
- `ps2dec_tb.py` - Cocotb testbench for PS2 decoder
- `ic_tb.py` - Cocotb testbench for interrupt controller
- `timer_tb.py` - Cocotb testbench for timer
- `sdram_burst_tb.py` - Cocotb testbench for SDRAM controller (single, burst, row-crossing)
- `gpu_fb_tb.py` - Cocotb testbench for GPU framebuffer
- `line_buffer_tb.py` - Cocotb testbench for video line buffer
- `video_fetch_tb.py` - Cocotb testbench for video fetch engine

## FemtoRV CPU Variants

FemtoRV comes in multiple variants, each adding more features:

| Variant | ISA | Features | LUTs | Use Case |
|---------|-----|----------|------|----------|
| **quark** | RV32I | Base integer | ~1000 | Minimal, ASIC-friendly |
| **tachyon** | RV32I | Higher frequency | ~1000 | Speed-optimized |
| **electron** | RV32IM | + Multiply/Divide | ~1200 | Math operations |
| **intermissum** | RV32IM | + Interrupts + CSR | ~1300 | Event-driven systems |
| **gracilis** | RV32IMC | + Compressed | ~1500 | Code density |
| **petitbateau** | RV32IMFC | + Floating point | ~2000 | DSP, graphics |

**Your work:** Modified intermissum/gracilis/petitbateau variants to integrate custom interrupt controller.

## Retro Computing Co-Processor Architecture

### Vision
```
┌─────────────┐         ┌──────────────────────────┐
│  Retro CPU  │◄───────►│   FemtoRV Co-Processor   │
│ 68k/6502/   │  Bus    │                          │
│ 8086/Z80    │         │  ┌────────────────────┐  │
└─────────────┘         │  │  FemtoRV Core      │  │
                        │  │  (petitbateau)     │  │
                        │  └────────┬───────────┘  │
                        │           │              │
                        │  ┌────────┴───────────┐  │
                        │  │ Peripherals:       │  │
                        │  │ • PS2 Keyboard     │  │
                        │  │ • Interrupt Ctrl   │  │
                        │  │ • HDMI GPU (3mode) │  │
                        │  │ • FM Synth + PCM   │  │
                        │  │ • SD Card (FAT32)  │  │
                        │  │ • 8MB SDRAM        │  │
                        │  │ • SDRAM Cache      │  │
                        │  │ • Timer            │  │
                        │  └────────────────────┘  │
                        └──────────────────────────┘
```

### Benefits
- **Updatable firmware**: Add new features without hardware changes
- **Modern peripherals**: PS2/USB keyboards, VGA/HDMI, SD cards
- **Offload processing**: Graphics, audio synthesis, protocol handling
- **Small footprint**: <2000 LUTs, perfect for ASIC co-processor

## Development Status

### Upstream (Bruno Levy's learn-fpga)
- **Status**: Mature, stable, maintenance mode
- **Last core update**: May 2023 (Vivado compatibility fix)
- **Your version**: May 2024 (8 commits behind, but only documentation/board support)
- **Active development**: Moved to TordBoyau (pipelined core without MMU)

### Your Fork Status
- **Last build**: April 2026 (Colorlight i5)
- **Working features**:
  - FemtoRV petitbateau (RV32IMFC) at 25 MHz
  - 32KB BRAM (BIOS ROM) + 8MB SDRAM (main RAM, cached)
  - 64-entry direct-mapped write-through SDRAM cache with RMW
  - PS2 keyboard with interrupt-driven scan code decoder + keymap
  - HDMI GPU: 3 display modes (text, bitmap, SDRAM framebuffer)
  - FM synthesizer: 4-voice 4-op TDM, I2S + PWM output
  - Sampled audio: 1024-sample ring buffer at 48kHz, mixed with FM
  - SD card: SPI bit-bang, FAT32 read, BIOS auto-boot
  - BIOS monitor: memory commands, XMODEM upload, SD boot
  - RetroKernel v0.1: Unix shell, FAT32 dir/cat/cp/rm/mkdir, program loader
  - Edge-triggered interrupt controller (32 sources)
  - Timer with countdown and interrupt
  - UART (256-byte RX FIFO, TX holding register), LEDs, 7-segment
  - Cocotb testbenches for PS2, interrupt controller, timer, SDRAM, video
- **Performance**: 4.7 MIPS, 4.38 DMIPS (0.175 DMIPS/MHz), 952 KFLOPS, 3034 KB/sec memcpy
- **Resource usage**: LUTs 57% (13,937/24,288), Block RAM 71% (40/56), Multipliers 53% (15/28), PLLs 100% (2/2)
- **Timing margin**: Max 32.6 MHz (30% margin at 25 MHz target)
- **Remote**: https://github.com/benpayne/learn-fpga.git (branch: colorlight_i5_support)

### Branch Layout

Everything below `87ad9c1` (BRAM-friendly line buffer) is the shared, known-good base:
petitbateau + SDRAM + cache + GPU + synth + BIOS monitor + RetroKernel, all working.

- `001-pico-rom-emulator` — Pico W ROM emulator + virtual disk. **Parked, incomplete, never
  verified on hardware.** Commit `f1e70b1` documents two known defects in its message: the
  boot stub polls the mailbox status field at the wrong offset (0x000 is the opcode field,
  status is 0x004), and `boot_manager.c` puts a 7936-byte buffer on core1's 4KB stack.
- `002-retro-web` — checked out in a separate worktree.
- `003-llama2-minimal-soc` — current work. Branched from `87ad9c1`, **not** from the Pico
  branch, so none of the unfinished Pico changes (4KB `NRV_RAM`, shared BRAM, SPI loader)
  are present here.

Build profiles are selected by a `-D<BOARD>` define, dispatched in `RTL/femtosoc_config.v`
to a file in `RTL/CONFIGS/`. New profiles are added alongside existing ones rather than by
editing them, so `colorlight_i5` and any new profile coexist in one checkout.

### Upstream Changes Since Your Work
```bash
# You are 8 commits behind, changes are:
- Tang Nano 9K board support (Nov 2024)
- GOWIN FPGA examples
- Documentation updates on interrupts
- NO processor core changes
```

## Building and Testing

### Build for Colorlight i5 (Your Target Board)

```bash
cd FemtoRV

# Build firmware
(cd FIRMWARE && make libs)                             # rebuild libs if changed
(cd FIRMWARE/monitor && make clean monitor.hex)        # build BIOS monitor
(cd FIRMWARE/retrokernel && make retrokernel.bin)       # build kernel (uploaded to SD)
(cd FIRMWARE/examples && make clean all)               # build user programs

# Copy font data (required for GPU)
cp -f lib/hdmi-display-lib/data/font_data.hex font_data.hex

# Synthesize bitstream (includes BIOS in BRAM)
make colorlight_i5.synth                              # yosys + nextpnr + ecppack

# Program FPGA (volatile - lost on power cycle)
openFPGALoader -c cmsisdap -v --file-type bin femtosoc.bit

# Program FPGA (permanent - survives power cycle)
openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin femtosoc.bit

# Upload files to RetroKernel's SD card
python3 TOOLS/kernel_upload.py FIRMWARE/retrokernel/retrokernel.bin /dev/ttyACM0 /kernel.bin
python3 TOOLS/kernel_upload.py FIRMWARE/examples/bench.bin /dev/ttyACM0 /bench.bin
```

### Programming the FPGA

```bash
# Using openFPGALoader
openFPGALoader -b colorlight_i5 femtosoc.bit

# Or using your load script
make BOARD=colorlight_i5 load
```

### Running Tests

```bash
cd FemtoRV/TEST

# Run all testbenches
pytest ps2dec_tb.py          # PS2 decoder
pytest ic_tb.py              # Interrupt controller
pytest timer_tb.py           # Timer
pytest sdram_burst_tb.py     # SDRAM controller (single, burst, row-crossing)
pytest line_buffer_tb.py     # Video line buffer
pytest video_fetch_tb.py     # Video fetch engine

# View waveforms
gtkwave sim_build/ps2_decoder_device.fst
```

## Your Custom Hardware Architecture

### PS2 Controller (`PS2Decoder.v`)

**Interface:**
```verilog
module ps2_decoder_device (
    input  wire        reset,
    input  wire        clk,
    input  wire        rstrb,       // CPU read strobe
    output wire [31:0] rdata,       // Data to CPU
    input  wire        sel,         // Chip select
    output wire        interrupt,   // Pulse on key received
    output wire        data_ready,  // Data available flag
    input  wire        ps2_clk,     // PS2 clock input
    input  wire        ps2_data     // PS2 data input
);
```

**Features:**
- Dual-port FIFO for buffering keypresses
- Debouncing on PS2 clock line
- Edge detection for interrupt generation
- Status bits: key pressed, key released
- State machine: IDLE → DELAY → READ → DELAY2

**Memory Map:**
- Read returns: `{22'b0, status[1:0], scancode[7:0]}`
- Interrupt pulses for one clock when new key available

### Interrupt Controller (`InterruptController.v`)

**Interface:**
```verilog
module InterruptController(
    input wire         rst,
    input wire         clk,
    input wire         wstrb,             // Write strobe
    input wire         rstrb,             // Read strobe
    input wire         sel,               // Chip select
    input wire  [31:0] wdata,             // Data from CPU
    output wire [31:0] rdata,             // Data to CPU
    input wire  [31:0] interrupts,        // Device interrupt inputs
    output reg         interrupt_request  // To CPU
);
```

**Features:**
- 32 interrupt sources
- Edge-triggered interrupt detection
- Read: Returns current interrupt status register
- Write: Clear interrupts by writing 1s to corresponding bits
- Interrupt request asserts when any interrupt bit set

**Usage Pattern:**
1. Device raises interrupt line (pulse)
2. Controller latches it in status register
3. Raises `interrupt_request` to CPU
4. CPU reads status register (identifies source)
5. CPU services interrupt
6. CPU writes to status register to clear bits

## Memory-Mapped I/O

FemtoRV uses memory-mapped I/O. Your Colorlight i5 memory map:

```
0x000000-0x007FFF   32KB BRAM (BIOS ROM with SD boot loader)
0x400000+           IO devices (one-hot addressing):
                      UART, LEDs, 7-seg, Timer, PS2 Keyboard,
                      GPU, FM Synth, SD Card, Interrupt Controller,
                      Hardware Config
0x800000-0x80FFFF   64KB kernel space (RetroKernel, loaded from SD)
0x810000-0x9FFFFF   ~2MB program space
0xA00000-0xA7CFFF   512KB framebuffer (640x400x16bpp, stride=2KB)
0xA7D000-0xEFFFFF   ~4.5MB free
0xF00000-0xFFFFF0   1MB stack (SDRAM, grows down)
```

SDRAM addresses (0x800000+) go through a 64-entry write-through cache.
Device addresses configured in `colorlight_i5_config.v` and `HardwareConfig_bits.v`

## Toolchain and Environment

### FPGA Synthesis Tools (Open Source)

```bash
# Yosys - Verilog synthesis
yosys --version

# nextpnr - Place and route
nextpnr-ecp5 --version  # For Colorlight i5

# OpenFPGALoader - Programming
openFPGALoader --version
```

### RISC-V Compiler

```bash
# Check installed toolchain
riscv32-unknown-elf-gcc --version
# OR
riscv64-unknown-elf-gcc --version

# For FemtoRV variants:
# - quark/tachyon: -march=rv32i -mabi=ilp32
# - electron/intermissum: -march=rv32im -mabi=ilp32
# - gracilis: -march=rv32imc -mabi=ilp32
# - petitbateau: -march=rv32imfc -mabi=ilp32f
```

### Simulation Tools

```bash
# Icarus Verilog - HDL simulator
iverilog --version

# Verilator - Fast simulator
verilator --version

# Cocotb - Python testbenches
pip3 show cocotb

# GTKWave - Waveform viewer
gtkwave --version
```

## Next Steps - Cleaning Up Your Fork

### 1. Commit Your Changes

```bash
cd ~/wip/learn-fpga

# Review your modifications
git status
git diff

# Create a feature branch
git checkout -b retro-coprocessor-2024

# Commit your PS2 controller
git add FemtoRV/RTL/DEVICES/PS2Decoder.v
git add FemtoRV/RTL/DEVICES/InterruptController.v
git add FemtoRV/RTL/DEVICES/Interrupt_bits.v
git add FemtoRV/RTL/DEVICES/ps2_controller/
git commit -m "Add PS2 keyboard controller with interrupt support

- PS2 decoder with dual-port FIFO buffering
- Edge-triggered interrupt controller (32 sources)
- Debouncing and state machine for PS2 protocol
- Cocotb testbench for verification
- Target: Retro computing co-processor applications"

# Commit processor modifications
git add FemtoRV/RTL/PROCESSOR/*.v
git commit -m "Integrate interrupt controller into FemtoRV variants"

# Commit tests
git add FemtoRV/TEST/ps2dec_tb.py
git commit -m "Add Cocotb testbench for PS2 decoder"
```

### 2. Create Your Fork on GitHub

```bash
# Fork BrunoLevy/learn-fpga on GitHub web interface
# Then update your remote:

git remote rename origin upstream
git remote add origin git@github.com:YOUR_USERNAME/learn-fpga.git
git push -u origin retro-coprocessor-2024
```

### 3. Merge Upstream Updates (Optional)

```bash
# Update from Bruno's repo
git fetch upstream
git merge upstream/master

# Resolve any conflicts (unlikely, as core hasn't changed)
```

## ASIC Flow for FemtoRV

FemtoRV is an excellent candidate for ASIC implementation via open-source tools.

### Why FemtoRV for ASIC?

- ✅ **Small**: <1000 LUTs for quark, <1500 for intermissum
- ✅ **Clean Verilog**: No FPGA-specific primitives
- ✅ **Synthesizable**: Designed for Yosys
- ✅ **Educational**: Easy to verify and understand
- ✅ **Proven**: Used in teaching, multiple implementations
- ✅ **Perfect for co-processor**: Small area, updatable firmware

### OpenLane/Sky130 Flow

```bash
# Install OpenLane (Docker recommended)
# See: https://openlane.readthedocs.io/

# Create OpenLane config for FemtoRV
mkdir -p openlane/femtorv_quark
cd openlane/femtorv_quark

# Create config.json for your design
# Start with minimal variant (quark) for first tapeout
```

**Estimated area on Sky130:**
- FemtoRV quark: ~0.01 mm²
- With PS2 + interrupts: ~0.015 mm²
- Plenty of room for audio/graphics peripherals

### ASIC Tapeout Options

1. **TinyTapeout** (Easiest)
   - Website: https://tinytapeout.com/
   - Submit window: Every ~6 months
   - Cost: ~$100-300
   - Size: 160x100 µm (tiny!)
   - Good for: Simple FemtoRV + 1-2 peripherals

2. **ChipIgnite / Efabless MPW** (Larger)
   - Website: https://efabless.com/chipignite
   - Size: Up to 10mm²
   - Good for: Full retro co-processor with multiple peripherals

3. **Zero to ASIC Course**
   - Website: https://zerotoasiccourse.com/
   - Includes TinyTapeout submission
   - Great for learning ASIC design

## Important Notes

### FemtoRV Limitations (By Design)

- ❌ **No MMU**: Cannot run Linux (only bare-metal/RTOS)
- ❌ **No Supervisor mode**: Machine mode only
- ❌ **No out-of-order**: Simple in-order pipeline
- ✅ **This is intentional**: Optimized for small size, educational clarity
- ℹ️ **Custom cache added**: 64-entry write-through cache for SDRAM (your addition, not upstream)

### For Linux, Consider:

- **kianRiscV**: RV32IMA with MMU, runs Linux, ~3000 LUTs
  - Already taped out on TinyTapeout TT06
  - GitHub: https://github.com/splinedrive/kianRiscV
- **VexRiscv**: Higher performance, used in LiteX
  - Larger, more complex, but very capable

### Your Retro Co-Processor Doesn't Need Linux!

For your use case (peripheral controller for retro computers):
- FemtoRV is perfect - small, simple, updatable firmware
- Bare-metal code or lightweight RTOS (FreeRTOS, Zephyr)
- Focus on peripheral drivers, not OS complexity

## Reference Documentation

### FemtoRV Tutorials

- **FROM_BLINKER_TO_RISCV**: Step-by-step CPU design (start here!)
  - Location: `FemtoRV/TUTORIALS/FROM_BLINKER_TO_RISCV/README.md`
  - Builds a RISC-V CPU from scratch in ~20 steps

- **DESIGN**: CPU architecture documentation
  - Location: `FemtoRV/TUTORIALS/DESIGN/`

- **Board tutorials**: IceStick, IceBreaker, ULX3S, ECP5, FOMU, Arty

### External Resources

- **Bruno Levy's page**: https://brunolevy.github.io/
- **RISC-V spec**: https://riscv.org/technical/specifications/
- **Yosys/nextpnr**: https://yosyshq.net/
- **Learn FPGA resources**: Listed in main README.md

## Common Development Commands

### Quick Build and Test

```bash
cd FemtoRV

# Full rebuild
(cd FIRMWARE && make libs)
(cd FIRMWARE/monitor && make clean monitor.hex)
cp -f lib/hdmi-display-lib/data/font_data.hex font_data.hex
make colorlight_i5.synth

# Program FPGA
openFPGALoader -c cmsisdap -v --file-type bin femtosoc.bit

# Upload files to SD card via RetroKernel
python3 TOOLS/kernel_upload.py FIRMWARE/examples/bench.bin /dev/ttyACM0 /bench.bin

# Connect serial terminal (115200 8N1, CMSIS-DAP USB)
screen /dev/ttyACM0 115200
# Or use: minicom -D /dev/ttyACM0 -b 115200
```

### Modifying Hardware

After changing Verilog files:
```bash
cd FemtoRV
make colorlight_i5.synth          # ~2-3 min (yosys + nextpnr + ecppack)
openFPGALoader -c cmsisdap -v --file-type bin femtosoc.bit
```

### Adding New Peripherals

1. Create device module in `RTL/DEVICES/your_device.v`
2. Add to `femtosoc.v` (instantiate and wire up)
3. Update `femtosoc_config.v` (add address mapping)
4. Write firmware driver in `FIRMWARE/`
5. Test and iterate

## Git Workflow Recommendations

### For Clean Development

```bash
# Create feature branches for each peripheral
git checkout -b feature/ps2-keyboard
git checkout -b feature/vga-controller
git checkout -b feature/audio-synth

# Keep main branch clean
git checkout main
git merge feature/ps2-keyboard

# Regularly sync with upstream (for updates)
git fetch upstream
git rebase upstream/master
```

### Before Committing

- Run synthesis to verify no errors
- Test on hardware if possible
- Update documentation
- Clean up generated files (don't commit .bit, .json)

## Project Vision: Retro Computing Co-Processor

Your goal is to create a modern peripheral controller for vintage computers using FemtoRV as the updatable firmware engine.

### Hardware Status

- ✅ **PS2 Keyboard** - Working (interrupt-driven, scan code decoder, modifier tracking)
- ✅ **Interrupt Controller** - Working (32 sources, edge-triggered, clear-by-writing-1s)
- ✅ **Timer** - Working (countdown with completion interrupt)
- ✅ **HDMI Character Display** - Working (40/80-col, per-char 16-color CGA palette)
- ✅ **HDMI Graphics Modes** - Working (1/2/4 BPP bitmap, 32KB VRAM, 16-entry RGB444 palette, VBlank sync)
- ✅ **HDMI Framebuffer** - Working (640x400 16bpp RGB565 from SDRAM, burst scanline fetch, ping-pong line buffer)
- ✅ **SD Card Interface** - Working (SPI bit-bang, FAT32, Digilent PMOD SD on P2: CS=P17, MOSI=R18, MISO=C18, SCK=U16)
- ✅ **SDRAM** - Working (EM638325 8MB, 32-bit, unified controller with burst + row-crossing)
- ✅ **SDRAM Cache** - Working (64-entry direct-mapped, write-through, RMW for byte/halfword stores)
- ✅ **FM Synthesizer** - Working (4-voice 4-op TDM, 8 presets, I2S + PWM, integrated into SoC)
- ✅ **Sampled Audio** - Working (1024x16-bit ring buffer at 48kHz, mixed with FM synth, play.c)
- ✅ **UART** - Working (115200 8N1, 256-byte RX FIFO, TX holding register)
- ✅ **BIOS Monitor** - Working (H/D/E/S/L/G/C/M, XMODEM upload, SD auto-boot, F5 40/80 toggle)
- ✅ **RetroKernel v0.1** - Working (Unix shell, FAT32 ls/cat/cp/rm/mkdir, program loader, SD boot)
- ✅ **Benchmarks** - 4.7 MIPS, 4.38 DMIPS (0.175 DMIPS/MHz), 952 KFLOPS, 3034 KB/sec memcpy
- 🔲 **USB Host** - Modern keyboards/mice
- 🔲 **Retro Bus Interface** - Connection to vintage CPUs

### Resource Usage
- LUTs: 57% (13,937/24,288)
- Block RAM: 71% (40/56 DP16KD)
- Multipliers: 53% (15/28)
- PLLs: 100% (2/2)
- Timing: Max 32.6 MHz (30% margin at 25 MHz)

### Memory Architecture
```
0x000000-0x007FFF   32KB BRAM (BIOS ROM with SD boot loader)
0x400000+           IO devices (GPU, Synth, UART, Timer, PS2, SD)
0x800000-0x80FFFF   64KB kernel space (RetroKernel)
0x810000-0x9FFFFF   ~2MB program space
0xA00000-0xA7CFFF   512KB framebuffer (640x400x16bpp, stride=2KB)
0xA7D000-0xEFFFFF   ~4.5MB free
0xF00000-0xFFFFF0   1MB stack (SDRAM, grows down)
```

### Development Roadmap

1. ~~**Monitor/Loader firmware**~~ ✅ Done
2. ~~**SD Card support**~~ ✅ Done (FAT32 read working)
3. ~~**SDRAM controller**~~ ✅ Done (8MB, cached, burst, row-crossing, code execution)
4. ~~**Audio synthesizer**~~ ✅ Done (4-voice FM + sampled PCM, I2S, integrated)
5. ~~**Sampled audio playback**~~ ✅ Done (ring buffer, 48kHz, play.c)
6. ~~**SDRAM framebuffer**~~ ✅ Done (640x400 16bpp, burst scanline fetch)
7. ~~**RetroKernel Phase 2**~~ ✅ Done (cat/cp/rm/mkdir, program loader)
8. ~~**RetroKernel Phase 3**~~ ✅ Done (SD boot, program execution from SD)
9. ~~**CPU benchmarks**~~ ✅ Done (Dhrystone 2.1, custom bench)
10. **Smart terminal mode** — VT100/ANSI escape code support in GPU
11. **FM synth improvements** — Operator feedback, LFO
12. **Cache upgrade** — 64 entries is limited; 256 entries exceeds timing margin at 25 MHz
13. **Retro bus interface** — Physical connection to vintage CPUs

### Use Cases

1. **Commodore 64** - Modern graphics, PS2 keyboard, SD storage
2. **Apple II** - VGA output, audio synthesis
3. **Z80 systems** - Fast math co-processor, modern I/O
4. **68k Macs** - Peripheral expansion

### GPU Architecture Notes

The HDMI display uses a tri-mode GPU (character + bitmap graphics + SDRAM framebuffer) with DVI/TMDS output:
- **Mode 0 (Text)**: 16-bit cells {bg[3:0], fg[3:0], char[7:0]}, 4-bit IRGB CGA palette, 40/80 column
- **Mode 1 (Bitmap)**: 1/2/4 BPP bitmap, 32KB VRAM in BRAM, 16-entry RGB444 CLUT, page flipping
- **Mode 2 (Framebuffer)**: 640x400 16bpp RGB565 from SDRAM, burst scanline fetch, ping-pong line buffer
- **GPU access**: Single 1-hot IO address, register index packed in wdata[12:8], value in wdata[7:0]
  - `GPU_WRITE(reg, val)` expands to `IO_OUT(IO_GPU, (reg << 8) | val)`
- **PLL**: gpu_pll.v generates 25MHz pixel + 125MHz TMDS from board clock (CLKFB_DIV=1, CLKOP_DIV=20)
- **DDR output**: ODDRX1F primitives in femtosoc.v for TMDS serialization
- **Framebuffer fetch**: video_fetch_engine.v issues 320-word bursts per scanline, row-crossing handled by SDRAM controller
- **Line buffer**: Ping-pong double buffer (2x320 words), hsync-driven swap, RGB565->RGB888 unpacking

### SDRAM Cache Architecture

- **64 entries x 1 word** (256 bytes), direct-mapped, register-based (combinatorial reads)
- **Write-through**: all writes go to SDRAM; cache updated simultaneously
- **Read-modify-write**: byte/halfword stores merge with cached data or fetch from SDRAM
- **Zero-stall read hits**: combinatorial data path, no added latency
- **Timing constraint**: 256 entries with distributed RAM (LUT-based) exceeds timing margin at 25 MHz (28.4 MHz vs 25 MHz); 64 entries gives 32.6 MHz (30% margin)
- **Cache upgrade findings**: ECP5 BRAM cannot provide zero-latency reads (always 1 clock cycle); distributed RAM works but 256:1 mux is too deep for 25 MHz

## Minimal LLM Profile (colorlight_i5_llm, 2026-08)

A second build profile alongside the full retro-computing one. Strips the GPU, audio synth,
PS2, 7-segment and interrupt controller, keeping CPU + SDRAM + UART + SD card + LEDs + timer.
Built to run llama2.c and to free capacity for a future MatMul accelerator.

### Build and run

```bash
cd FemtoRV
make colorlight_i5_llm.firmware_config       # generates FIRMWARE/config.mk for this profile
(cd FIRMWARE/monitor && make clean monitor.hex)
make colorlight_i5_llm.synth                 # -> femtosoc.bit
cp femtosoc.bit femtosoc_llm.bit             # both profiles write the same filename!
openFPGALoader -c cmsisdap -v --file-type bin femtosoc_llm.bit

(cd FIRMWARE/llama2/tools && ./fetch_model.sh)   # model.bin + tokenizer.bin -> FAT SD card
cd FIRMWARE/llama2 && make upload                # upload over XMODEM, run, stream output
```

`make upload` / `make upload_sd_bench` / `make upload_sdram_memtest` each upload, run, and
stream program output, exiting after an idle period. Override the port with `PORT=...`.

### Measured on hardware

| | Full profile | Minimal profile |
|---|---|---|
| LUT4 | 57% (13,937) | **34%** (8,391) |
| Block RAM | 71% (40/56) | **28%** (16/56) |
| Multipliers | 53% (15/28) | 28% (8/28) |
| PLL | 2/2 | **1/2** |
| Max frequency | 32.6 MHz | **40.76 MHz** |

- SDRAM: 6 MB verified, 0 errors, 4,897 KB/s (5.1 MB/s) CPU write+read
- SD card read: ~56.5 KB/s, flat across 512 B-32 KB chunks (software SPI is the bottleneck)
- Model load (1,056,512 B from card): 17.9 s
- llama2.c stories260K: **1.38 tok/s**, output byte-identical to the same model on a desktop

### Per-token profile (the accelerator brief)

```
matmul 61.3% | attention 27.4% | sample 4.0% | other 6.6% | rmsnorm 0.4% | rope 0.2%
```

matmul + attention = **88.7%**, both matrix-multiply shaped. At 50x acceleration: matmul
alone gives ~2.5x end-to-end, matmul + attention gives ~7.6x. **An accelerator must cover
attention as well as the weight matrices**; they differ only in streaming the KV cache versus
weights, so one datapath serves both.

### Traps worth knowing

- **`.bss` is not zeroed by the C runtime.** `CRT/crt0_baremetal.S` has a long-standing TODO.
  BRAM programs got away with it because the FPGA zeroes block RAM from the bitstream; SDRAM
  programs do not. `FIRMWARE/examples/sdramstart.S` now does it for anything linked with
  `upload_sdram.ld` or `llama2.ld`.
- **`_end` used to sit inside `.text`**, before `.bss`, so `_sbrk()`'s heap overlapped `.bss`.
  Fixed in both linker scripts.
- **The system `riscv64-unknown-elf-gcc` is unusable here** — no newlib for `rv32imafc`/
  `ilp32f`, fails on `stdint.h`. Only the in-tree 8.3.0 toolchain works, which is what `make`
  uses.
- **`femtosoc.v` includes `PS2Decoder.v` unguarded**, so `-Ilib/ps2-controller-lib` is still
  required even with PS2 disabled.
- **Never run two serial readers at once.** Two `--follow` processes split the byte stream and
  produce dropped characters that look exactly like a UART fault.

## Active Technologies
- C (RISC-V bare metal, rv32imafc/ilp32f) + Verilog-2001 RTL + Yosys/nextpnr-ecp5/ecppack + riscv64-unknown-elf-gcc 8.3.0 (003-llama2-minimal-soc)
- FAT-formatted SD card for model/vocabulary artifacts; 8 MB external SDRAM at runtime (003-llama2-minimal-soc)
- Verilog-2001 RTL + C bare-metal (rv32imafc/ilp32f) + cocotb/Icarus + upstream runq.c as the Q8_0 reference (004-int8-matmul-accel)

- Verilog (FPGA RTL) + Yosys/nextpnr-ecp5 (FPGA synthesis) + Cocotb (testbenches)
- C (RISC-V firmware, rv32imfc) + RISC-V GCC toolchain
- Python (upload tools, testbenches)
- Target: Colorlight i5 (ECP5 LFE5U-25F), 25 MHz

### Sub-project: 004-int8-matmul-accel (current branch)
- Hardware matrix-multiply accelerator, 8-bit integer weights (Q8_0)
- Targets matmul (61.3%) + attention (27.4%) = 88.7% of per-token time
- Memory-bound by design: 1 x 32-bit SDRAM port = 4 int8 weights/cycle = 4 MAC lanes.
  More lanes need more bandwidth, not more multipliers.
- int8 chosen for CAPACITY (~5.3M params vs ~1.5M), not speed — the scalar
  remainder dominates, so int8 vs fp32 is only ~11% end-to-end.
- Design rationale: `FemtoRV/RTL/ACCEL/DESIGN.md`; spec in `specs/004-int8-matmul-accel/`

### Sub-project: 003-llama2-minimal-soc
- Minimal SoC profile: CPU + SDRAM + UART only, all other peripherals stripped
- Goal: run llama2.c (stories260K, ~1MB fp32) from SDRAM, output over serial
- Purpose: free FPGA capacity and establish a measured baseline for a future
  MatMul accelerator. See `specs/003-llama2-minimal-soc/spec.md`.

## Recent Changes
- 004-int8-matmul-accel: int8 MatMul accelerator — spec, plan and design.
  See `FemtoRV/RTL/ACCEL/DESIGN.md` for the architecture rationale.
- 003-llama2-minimal-soc: minimal SoC profile (CPU + SDRAM + UART + SD), llama2.c bring-up,
  and a per-token timing baseline for future accelerator work. Plan and research in
  `specs/003-llama2-minimal-soc/`.
