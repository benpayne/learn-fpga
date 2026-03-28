// gpu_pll.v - GPU Clock Generation using ECP5 PLL
//
// This module generates the clock signals required for HDMI video output:
// - 25 MHz pixel clock (VGA 640x480@60Hz standard)
// - 125 MHz TMDS clock (5x pixel clock for DDR serialization)
//
// Reference: /tmp/my_hdmi_device/ecp5pll.sv (EMARD's parametric ECP5 PLL)
// License: BSD
//
// DESIGN RATIONALE:
// -----------------
// The VGA 640x480@60Hz standard calls for 25.175 MHz pixel clock, but we use
// exactly 25 MHz for simplicity and compatibility. The difference is minimal:
//   Standard: 25.175 MHz (actual VGA specification)
//   Our impl: 25.000 MHz (0.7% slower, within monitor tolerance)
//
// This conservative choice simplifies PLL configuration and provides clean
// integer relationships between clocks, improving timing closure.
//
// CLOCK GENERATION STRATEGY:
// --------------------------
// Input:  25 MHz system clock
// Output: 25 MHz pixel clock (1x input)
// Output: 125 MHz TMDS clock (5x input)
//
// PLL Configuration:
//   VCO frequency: 500 MHz (middle of 400-800 MHz range, optimal)
//   Input divider (CLKI_DIV): 1
//   Feedback divider (CLKFB_DIV): 20  -> VCO = 25 * 20 / 1 = 500 MHz
//   Primary output (CLKOP): 500 / 20 = 25 MHz (pixel clock)
//   Secondary output (CLKOS): 500 / 4 = 125 MHz (TMDS clock)
//
// ECP5 PLL CONSTRAINTS:
//   VCO range: 400-800 MHz (optimal near 600 MHz)
//   PFD range: 3.125-400 MHz
//   Input divider: 1-128
//   Feedback divider: 1-80
//   Output divider: 1-128
//
// VERIFICATION:
//   fvco = fin * CLKFB_DIV / CLKI_DIV = 25 * 20 / 1 = 500 MHz ✓
//   fpixel = fvco / CLKOP_DIV = 500 / 20 = 25 MHz ✓
//   ftmds = fvco / CLKOS_DIV = 500 / 4 = 125 MHz ✓

module gpu_pll (
    input  wire clk_25mhz,    // 25 MHz input clock from system
    output wire clk_pixel,    // 25 MHz pixel clock output
    output wire clk_tmds,     // 125 MHz TMDS clock output (5x pixel)
    output wire locked        // PLL lock indicator (1 = locked and stable)
);

    // Internal signal for primary clock output
    wire CLKOP_internal;

    // ECP5 EHXPLLL primitive instantiation
    // This is the hardware PLL block in Lattice ECP5 FPGAs
    //
    // Key parameters explained:
    //   CLKI_DIV: Input clock divider (1 = no division)
    //   CLKFB_DIV: Feedback divider (20 -> VCO = 500 MHz)
    //   FEEDBK_PATH: Use primary output (CLKOP) for feedback
    //   CLKOP_DIV: Primary output divider (20 -> 25 MHz)
    //   CLKOS_DIV: Secondary output divider (4 -> 125 MHz)
    //
    // Phase settings (CPHASE/FPHASE) are set to 0 for no phase shift
    // since we don't need precise phase relationships between outputs.

    (* ICP_CURRENT="12" *)           // Charge pump current setting
    (* LPF_RESISTOR="8" *)           // Loop filter resistor value
    (* MFG_ENABLE_FILTEROPAMP="1" *) // Enable filter op-amp for stability
    (* MFG_GMCREF_SEL="2" *)         // GM reference current selection
    EHXPLLL #(
        // Input and feedback configuration
        .CLKI_DIV(1),                 // Input divider: 25 MHz / 1 = 25 MHz
        .CLKFB_DIV(1),                // Feedback divider: VCO = 25 * 1 * 20 / 1 = 500 MHz
        .FEEDBK_PATH("CLKOP"),        // Use primary output for feedback

        // Primary output (CLKOP) - 25 MHz pixel clock
        .OUTDIVIDER_MUXA("DIVA"),     // Use divider A for CLKOP
        .CLKOP_ENABLE("ENABLED"),     // Enable primary output
        .CLKOP_DIV(20),               // Output divider: 500 MHz / 20 = 25 MHz
        .CLKOP_CPHASE(0),             // Coarse phase: 0 (no shift)
        .CLKOP_FPHASE(0),             // Fine phase: 0 (no shift)

        // Secondary output (CLKOS) - 125 MHz TMDS clock
        .OUTDIVIDER_MUXB("DIVB"),     // Use divider B for CLKOS
        .CLKOS_ENABLE("ENABLED"),     // Enable secondary output
        .CLKOS_DIV(4),                // Output divider: 500 MHz / 4 = 125 MHz
        .CLKOS_CPHASE(0),             // Coarse phase: 0 (no shift)
        .CLKOS_FPHASE(0),             // Fine phase: 0 (no shift)

        // Unused secondary outputs (CLKOS2, CLKOS3)
        .OUTDIVIDER_MUXC("DIVC"),     // Divider C configuration
        .CLKOS2_ENABLE("DISABLED"),   // Disable CLKOS2
        .CLKOS2_DIV(1),               // Default divider value
        .CLKOS2_CPHASE(0),
        .CLKOS2_FPHASE(0),

        .OUTDIVIDER_MUXD("DIVD"),     // Divider D configuration
        .CLKOS3_ENABLE("DISABLED"),   // Disable CLKOS3
        .CLKOS3_DIV(1),               // Default divider value
        .CLKOS3_CPHASE(0),
        .CLKOS3_FPHASE(0),

        // Control and status
        .INTFB_WAKE("DISABLED"),      // Internal feedback wake disabled
        .STDBY_ENABLE("DISABLED"),    // Standby mode disabled
        .PLLRST_ENA("DISABLED"),      // PLL reset disabled (always running)
        .DPHASE_SOURCE("DISABLED"),   // Dynamic phase shift disabled
        .PLL_LOCK_MODE(0)             // Lock mode: standard
    )
    pll_inst (
        // Clock inputs and outputs
        .CLKI(clk_25mhz),             // Input: 25 MHz system clock
        .CLKOP(CLKOP_internal),       // Primary output: 25 MHz (internal)
        .CLKOS(clk_tmds),             // Secondary output 1: 125 MHz TMDS
        .CLKOS2(),                    // Secondary output 2: unused
        .CLKOS3(),                    // Secondary output 3: unused

        // Feedback path
        .CLKFB(CLKOP_internal),       // Feedback from primary output
        .CLKINTFB(),                  // Internal feedback (unused)

        // Control signals (all disabled)
        .RST(1'b0),                   // Reset: not used
        .STDBY(1'b0),                 // Standby: not used
        .PHASESEL1(1'b0),             // Phase select bit 1: not used
        .PHASESEL0(1'b0),             // Phase select bit 0: not used
        .PHASEDIR(1'b0),              // Phase direction: not used
        .PHASESTEP(1'b0),             // Phase step: not used
        .PHASELOADREG(1'b0),          // Phase load register: not used
        .PLLWAKESYNC(1'b0),           // PLL wake sync: not used

        // Output enable signals (unused, clocks are always enabled)
        .ENCLKOP(1'b0),               // Enable CLKOP: not used
        .ENCLKOS(1'b0),               // Enable CLKOS: not used
        .ENCLKOS2(1'b0),              // Enable CLKOS2: not used
        .ENCLKOS3(1'b0),              // Enable CLKOS3: not used

        // Status output
        .LOCK(locked)                 // PLL lock indicator
    );

    // Connect internal primary output to external pixel clock
    assign clk_pixel = CLKOP_internal;

endmodule

// USAGE NOTES:
// ------------
// 1. Wait for 'locked' signal to go high before using generated clocks
// 2. The locked signal typically asserts within 100-200 microseconds
// 3. All clock outputs maintain fixed phase relationships
// 4. The 5:1 ratio between TMDS and pixel clocks is critical for HDMI
//    DDR serialization (2 bits per edge * 5x clock = 10 bits per pixel period)
// 5. No reset required - PLL starts automatically on power-up
//
// FUTURE ENHANCEMENTS:
// --------------------
// - Add support for 25.175 MHz if exact VGA timing is required
// - Add 720p support (74.25 MHz pixel, 371.25 MHz TMDS)
// - Add 1080p support (148.5 MHz pixel, 742.5 MHz TMDS)
// - Add dynamic resolution switching via runtime reconfiguration
// - Add PLL reset input for controlled restart scenarios
