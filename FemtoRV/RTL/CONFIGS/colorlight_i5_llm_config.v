// Minimal femtosoc configuration file for COLORLIGHT_I5_LLM board profile
//
// This is a stripped-down profile for running a small language model on
// FemtoRV. It keeps only the CPU + SDRAM + UART + SD card + LEDs + timer,
// freeing the FPGA capacity normally spent on the GPU, audio synth, PS2
// keyboard, interrupt controller and other peripherals.
//
// The full-featured profile (GPU, audio, PS2, interrupts, etc.) lives in
// colorlight_i5_config.v -- use this file instead when building for the
// minimal SoC target.

/************************* Devices **********************************************************************************/

`define NRV_IO_LEDS        // Mapped IO, LEDs D1,D2,D3,D4 (D5 is used to display errors)
`define NRV_IO_UART        // Mapped IO, virtual UART (USB)
`define NRV_IO_SDCARD      // Mapped IO, SPI SDCARD
`define NRV_IO_TIMER
`define NRV_IO_SDRAM       // SDRAM (main RAM, via muchtoremember controller)
// Suppressed by -DNRV_NO_ACCEL, which builds this same profile WITHOUT the
// accelerator. That variant is feature 003's minimal SoC and is what Session A
// runs: the Q8_0 software path is the golden reference every later hardware
// result is compared against, and it should not be measured on a build whose
// timing margin is thin (research R27/R31). Guard rather than a separate config
// file, because the two differ in exactly one define and a forked copy would
// drift.
`ifndef NRV_NO_ACCEL
`define NRV_IO_ACCEL       // int8 matmul accelerator (feature 004). Occupies the burst-port
                           // instantiation site video_fetch_engine would otherwise use in this
                           // profile (DESIGN.md sec 9a, research R10) -- mutually exclusive with
                           // NRV_IO_GPU/NRV_IO_SYNTH, which this profile does not define anyway,
                           // since it reuses their IO_ACC_IDX_bit/IO_ACC_DAT_bit slots
                           // (HardwareConfig_bits.v). Sets muchtoremember_burst's CPU_PRIORITY=1
                           // for this profile only -- the display profile's default (0,
                           // burst-first) is unchanged.
`endif

/************************* Frequency ********************************************************************************/

`define NRV_FREQ 25          // Frequency in MHz. Using 25 MHz (no PLL) for stability

`define NRV_FEMTORV32_PETITBATEAU // RV32IMFC -- hardware floating point needed for the model
`define NRV_RESET_ADDR 0       // The address the processor jumps to on reset

/************************* RAM (in bytes, needs to be a multiple of 4)***********************************************/

`define NRV_RAM 32768 // 32KB BRAM boot ROM (main RAM is SDRAM at 0x800000)

/************************* Advanced processor configuration *********************************************************/

`define NRV_IO_HARDWARE_CONFIG // Comment-out to disable hardware config registers mapped in IO-Space
                               // (only if you use your own firmware, libfemtorv32 depends on it)

/********************************************************************************************************************/

`define NRV_CONFIGURED
