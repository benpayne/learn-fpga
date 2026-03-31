# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **learn-fpga** by Bruno Levy - an educational repository for learning FPGA design, Yosys/nextpnr toolchain, and RISC-V processor design. The centerpiece is **FemtoRV**, a minimalistic RISC-V CPU designed for teaching and embedded applications.

**Your Custom Work (2024-2026):**
- Added PS2 keyboard controller with interrupt support and scan code decoder
- Created custom interrupt controller for FemtoRV (32 sources, edge-triggered)
- HDMI display GPU with per-character 16-color text mode + bitmap graphics
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

Located in `FemtoRV/lib/ps2-controller-lib/` (git submodule):
- PS2 decoder core, debounce, FIFO sub-modules

Located in `FemtoRV/lib/hdmi-display-lib/` (shared with retrocpu):
- `rtl/core/` - TMDS encoder, DVI transmitter, VGA timing generator
- `rtl/character/` - Character GPU: buffer, renderer, font ROM, registers
- `rtl/graphics/` - Graphics GPU: VRAM, palette, pixel renderer (1/2/4 BPP)
- `rtl/gpu_top.v` - Top-level GPU with char+graphics mux
- `wrappers/fpga/gpu_femtorv_wrapper.v` - FemtoRV 32-bit bus adapter
- `clock/gpu_pll.v` - ECP5 PLL for 25MHz pixel + 125MHz TMDS
- `data/font_data.hex` - 8x16 VGA font bitmap

Located in `FemtoRV/FIRMWARE/`:
- `LIBFEMTORV32/ps2_keymap.h` - PS2 scan code to ASCII decoder with modifiers
- `gpu_text/` - HDMI text demo (16 colors, keyboard echo, scrolling)
- `blinky/` - Interrupt-driven PS2 keyboard + timer demo

Located in `FemtoRV/TEST/`:
- `ps2dec_tb.py` - Cocotb testbench for PS2 decoder

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
                        │  │  (intermissum+)    │  │
                        │  └────────┬───────────┘  │
                        │           │              │
                        │  ┌────────┴───────────┐  │
                        │  │ Your Peripherals:  │  │
                        │  │ • PS2 Keyboard     │  │
                        │  │ • Interrupt Ctrl   │  │
                        │  │ • Graphics (TBD)   │  │
                        │  │ • Audio (TBD)      │  │
                        │  │ • SPI Flash        │  │
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
- **Last build**: March 2026 (Colorlight i5)
- **Working features**:
  - FemtoRV petitbateau (RV32IMFC) at 25 MHz, 64KB BRAM
  - PS2 keyboard with interrupt-driven scan code decoder + keymap
  - HDMI display: 40/80-col text with per-character 16-color CGA palette
  - HDMI display: bitmap graphics modes (1/2/4 BPP, 32KB VRAM, 16-entry RGB444 palette)
  - Edge-triggered interrupt controller (32 sources)
  - Timer with countdown and interrupt
  - UART, LEDs (active-low), 7-segment display
  - Cocotb testbenches for PS2, interrupt controller, timer
- **Resource usage**: LUTs 33%, Block RAM 92% (52/56), PLLs 2/2
- **Remote**: https://github.com/benpayne/learn-fpga.git (branch: colorlight_i5_support)

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

# Build firmware (e.g., gpu_text demo)
(cd FIRMWARE && make libs)                           # rebuild libs if changed
(cd FIRMWARE/gpu_text && make clean gpu_text.hex)     # build and copy to firmware.hex

# Synthesize bitstream (includes firmware in BRAM)
make colorlight_i5.synth                              # yosys + nextpnr + ecppack

# Program FPGA (volatile - lost on power cycle)
sudo openFPGALoader -c cmsisdap -v --file-type bin femtosoc.bit

# Program FPGA (permanent - survives power cycle)
sudo openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin femtosoc.bit
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
cd TEST

# Run PS2 decoder testbench (your test)
pytest ps2dec_tb.py

# View waveforms
gtkwave sim_build/ps2_decoder_device.fst
```

### Building Firmware

```bash
cd FIRMWARE/EXAMPLES

# Build a demo program
make hello.hex

# Program to FPGA (loads into BRAM)
make hello.prog
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

FemtoRV uses memory-mapped I/O. Typical memory map:

```
0x00000000 - 0x00001FFF : RAM (8KB typical)
0x00002000 - 0x00003FFF : ROM/Flash
0x80000000 - 0x8FFFFFFF : I/O devices
  0x80000000 : UART
  0x80000004 : LEDs
  0x80000008 : Switches
  ...
  [YOUR DEVICES]
  0x80000xxx : PS2 Decoder
  0x80000yyy : Interrupt Controller
```

Device addresses configured in `femtosoc_config.v`

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
- ❌ **No cache**: Direct memory access
- ❌ **No out-of-order**: Simple in-order pipeline
- ✅ **This is intentional**: Optimized for small size, educational clarity

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
# Build for Colorlight i5
cd FemtoRV
make BOARD=colorlight_i5 build

# Load to FPGA
make BOARD=colorlight_i5 load

# Build and run firmware
cd FIRMWARE/EXAMPLES
make hello.prog

# Connect serial terminal (115200 8N1)
screen /dev/ttyUSB0 115200
```

### Modifying Hardware

After changing Verilog files:
```bash
# Rebuild synthesis
make clean
make BOARD=colorlight_i5 build

# Reload to FPGA
make BOARD=colorlight_i5 load
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
- ✅ **SD Card Interface** - Working (SPI bit-bang, FAT32, Digilent PMOD SD on P2: CS=P17, MOSI=R18, MISO=C18, SCK=U16)
- ✅ **SDRAM** - Working (EM638325 8MB, 32-bit, cached with RMW, code execution verified)
- ✅ **FM Synthesizer** - Working (4-voice 4-op TDM, 8 presets, I2S + PWM, integrated into SoC)
- ✅ **BIOS Monitor** - Working (H/D/E/S/L/G/C/M, XMODEM upload, F5 40/80 toggle)
- ✅ **RetroKernel v0.1** - Working (Unix shell, FAT32 dir listing, program loader framework)
- 🔲 **USB Host** - Modern keyboards/mice
- 🔲 **Retro Bus Interface** - Connection to vintage CPUs

### Resource Usage
- LUTs: 55% (13,582/24,288)
- Block RAM: 51% (29/56 DP16KD) — reduced from 94% by moving RAM to SDRAM
- Multipliers: 53% (15/28)
- PLLs: 100% (2/2)

### Memory Architecture
```
0x000000-0x003FFF   16KB BRAM (BIOS ROM, monitor)
0x400000+           IO devices (GPU, Synth, UART, Timer, PS2, SD)
0x800000-0x80FFFF   64KB kernel space (RetroKernel)
0x810000-0xEFFFFF   ~7MB program space
0xF00000-0xFFFFF0   1MB stack (grows down)
```

### Development Roadmap

1. ~~**Monitor/Loader firmware**~~ ✅ Done
2. ~~**SD Card support**~~ ✅ Done (FAT32 read working)
3. ~~**SDRAM controller**~~ ✅ Done (8MB, cached, RMW, code execution)
4. ~~**Audio synthesizer**~~ ✅ Done (4-voice FM, I2S, integrated)
5. **RetroKernel Phase 2** — File I/O syscalls, cat/cp/rm commands, SD card write
6. **RetroKernel Phase 3** — Memory allocator, program arguments, boot from SD
7. **Smart terminal mode** — VT100/ANSI escape code support in GPU
8. **FM synth improvements** — Operator feedback, LFO, audio FIFO
9. **Retro bus interface** — Physical connection to vintage CPUs

### Use Cases

1. **Commodore 64** - Modern graphics, PS2 keyboard, SD storage
2. **Apple II** - VGA output, audio synthesis
3. **Z80 systems** - Fast math co-processor, modern I/O
4. **68k Macs** - Peripheral expansion

### GPU Architecture Notes

The HDMI display uses a dual-mode GPU (character + bitmap graphics) with DVI/TMDS output:
- **Character GPU**: 16-bit cells {bg[3:0], fg[3:0], char[7:0]}, 4-bit IRGB CGA palette
- **Graphics GPU**: 1/2/4 BPP bitmap, 32KB VRAM, 16-entry RGB444 CLUT, page flipping
- **GPU access**: Single 1-hot IO address, register index packed in wdata[12:8], value in wdata[7:0]
  - `GPU_WRITE(reg, val)` expands to `IO_OUT(IO_GPU, (reg << 8) | val)`
- **PLL**: gpu_pll.v generates 25MHz pixel + 125MHz TMDS from board clock (CLKFB_DIV=1, CLKOP_DIV=20)
- **DDR output**: ODDRX1F primitives in femtosoc.v for TMDS serialization
- **Block RAM budget**: 92% (52/56 DP16KD) — VRAM is 32KB, char buffer is 4.8KB

This is an exciting project with clear ASIC potential! FemtoRV is the perfect foundation.
