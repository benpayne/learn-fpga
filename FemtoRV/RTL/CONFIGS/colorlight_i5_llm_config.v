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
