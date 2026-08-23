// ----------------------------------------------------------------------------
// bridge_6502.v — 6502 host bridge onto the Retro-Active common bus
//
// Implemented structurally from 7400-series primitives.  BOM:
//   U1  74LS245  (data transceiver: 6502 D0-D7 <-> bus DATA[7:0])
//   U2  74LS244  (address buffer:   6502 A0-A7  -> bus ADDR[7:0])
//   U3  74LS244  (address buffer:   6502 A8-A15 -> bus ADDR[15:8])
//   U4  74LS74   (PHI2 synchroniser: 2 D-FFs into bus_clk domain)
//   U5  74LS74   (state machine:    2 D-FFs encode S1/S0)
//   U6  74LS00   (glue logic:       next-state, RSTRB/WSTRB, inverter)
//
// State machine (bus_clk):
//     IDLE(00) -> DRIVE(01)  on PHI2 rising edge
//     DRIVE(01)-> WAIT(11)   unconditionally
//     WAIT(11) -> DONE(10)   when bus_ready
//     DONE(10) -> IDLE(00)   when PHI2 low again
//
// Scope: 8-bit-only host.  Upper 24 bits of DATA are left un-driven on
// writes; WSTRB[3:1] tied low; ADDR[23:16] tied low.  Cards that want to
// be 6502-friendly expose 8-bit registers on byte lane 0.
// ----------------------------------------------------------------------------
`default_nettype none

module bridge_6502 #(
    // Upper 8 bits of the bus address driven by this 6502.  Defaults to
    // 0x00 so existing single-card tests (which place their fake target
    // at 0x000000-0x00FFFF) keep working.  For a multi-slot deployment,
    // set this to 0x40 + (slot << 0) so the 6502's 64 KB window maps to
    // that slot's per-card register space — e.g. 0x40 = slot 0,
    // 0x41 = slot 1, … 0x4F = slot 15.  In a real board the high byte
    // would be jumpered or come from a small bank register.
    parameter [7:0] BUS_ADDR_BANK = 8'h00
) (
    // --- 6502 side ---
    input  wire        cpu_phi2,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,        // 1 = read, 0 = write
    inout  wire [7:0]  cpu_data,
    input  wire        bus_irq,       // card-side IRQ, active high on bus
    output wire        cpu_irq_n,     // to 6502 IRQB (active low)

    // --- Retro-Active bus side ---
    input  wire        bus_clk,       // 25 MHz reference
    input  wire        bus_reset_n,
    output wire [23:0] bus_addr,
    output wire [3:0]  bus_wstrb,
    output wire        bus_rstrb,
    inout  wire [31:0] bus_data,
    input  wire        bus_ready
);

    // ------------------------------------------------------------------
    // U4  74LS74  — PHI2 synchroniser (two FFs into bus_clk domain)
    // ------------------------------------------------------------------
    wire phi2_sync0, phi2_sync1;
    wire phi2_sync0_n, phi2_sync1_n;

    SN74LS74 U4 (
        // Channel A: first stage
        .CLK1(bus_clk), .D1(cpu_phi2),
        .PRE1_n(1'b1), .CLR1_n(bus_reset_n),
        .Q1(phi2_sync0), .Q1_n(phi2_sync0_n),
        // Channel B: second stage
        .CLK2(bus_clk), .D2(phi2_sync0),
        .PRE2_n(1'b1), .CLR2_n(bus_reset_n),
        .Q2(phi2_sync1), .Q2_n(phi2_sync1_n)
    );

    // ------------------------------------------------------------------
    // U6  74LS00  — NAND quad used for all glue logic
    //
    // On a real board the next-state logic + strobe gating collapse into
    // one small PAL/GAL or a second 74LS00 + 74LS32.  To keep the chip
    // count honest we express the remaining combinational terms in
    // Verilog alongside this single NAND quad; a builder substituting a
    // PAL/GAL here is doing exactly what a 1980s designer would do.
    //
    // Gate A: !phi2_rising = NAND(phi2_sync0, phi2_sync1_n)
    // Gate B: IRQ inverter  cpu_irq_n = !bus_irq = NAND(bus_irq, bus_irq)
    // Gates C/D: reserved for PAL/GAL replacement (see bus_rstrb below).
    // ------------------------------------------------------------------
    wire [3:0] u6_a, u6_b, u6_y;

    // Gate A (y[0]): !phi2_rising — NAND(phi2_sync0, phi2_sync1_n)
    assign u6_a[0] = phi2_sync0;
    assign u6_b[0] = phi2_sync1_n;

    // Gate B (y[1]): IRQ inverter — NAND(bus_irq, bus_irq) = !bus_irq
    assign u6_a[1] = bus_irq;
    assign u6_b[1] = bus_irq;

    // Gates C / D: unused in this minimal build; tied to safe values so
    // iverilog doesn't see floating inputs.
    assign u6_a[2] = 1'b0;
    assign u6_b[2] = 1'b0;
    assign u6_a[3] = 1'b0;
    assign u6_b[3] = 1'b0;

    SN74LS00 U6 (.A(u6_a), .B(u6_b), .Y(u6_y));

    wire phi2_rising  = ~u6_y[0];
    assign cpu_irq_n  =  u6_y[1];

    // Forward-declared wire for the state-machine output.
    wire cycle_active;

    // ------------------------------------------------------------------
    // U5  74LS74  — state machine (S1, S0)
    //
    // State encoding (Gray-ish so only one bit flips per transition):
    //     00 IDLE
    //     01 DRIVE
    //     11 WAIT
    //     10 DONE
    //
    // Next-state equations derived from the transition table:
    //     S1_next = (DRIVE) | (WAIT) | (DONE & phi2_sync1)
    //             = (!S1 & S0) | (S1 & S0) | (S1 & !S0 & phi2_sync1)
    //     S0_next = (IDLE & phi2_rising) | (DRIVE & 1) | (WAIT & !ready)
    //             = (!S1 & !S0 & phi2_rising)
    //             | (!S1 &  S0)
    //             | ( S1 &  S0 & !bus_ready)
    //
    // On real hardware this next-state logic would be a small PAL/GAL or
    // a handful of 74LS00/08/32 gates sharing the package with U6.  For
    // clarity in this model we express it as combinational Verilog — the
    // gate-level equivalent is documented next to each term.
    // ------------------------------------------------------------------
    wire S1, S0;
    wire S1_n, S0_n;

    // Combinational next-state (logically gate-level; see comment above).
    wire S1_next =
          ( ~S1 &  S0)                    // DRIVE  -> S1'=1
        | (  S1 &  S0)                    // WAIT   -> S1'=1 (holds)
        | (  S1 & ~S0 & phi2_sync1);      // DONE   -> S1'=1 while PHI2 still high

    wire S0_next =
          (~S1 & ~S0 & phi2_rising)       // IDLE  + rising edge -> enter DRIVE
        | (~S1 &  S0)                     // DRIVE -> WAIT (S0 stays 1)
        | ( S1 &  S0 & ~bus_ready);       // WAIT  -> WAIT while !ready

    SN74LS74 U5 (
        .CLK1(bus_clk), .D1(S1_next),
        .PRE1_n(1'b1), .CLR1_n(bus_reset_n),
        .Q1(S1), .Q1_n(S1_n),

        .CLK2(bus_clk), .D2(S0_next),
        .PRE2_n(1'b1), .CLR2_n(bus_reset_n),
        .Q2(S0), .Q2_n(S0_n)
    );

    // cycle_active drives bus signals (ADDR, WSTRB/RSTRB).  Active in
    // DRIVE (01) and WAIT (11) — exactly S0.
    assign cycle_active = S0;

    // data_hot extends the data-path enable through the DONE state so the
    // 74LS245 keeps presenting the last valid byte on cpu_data until the
    // 6502 has sampled it (i.e., until PHI2 falls and the FSM returns to
    // IDLE).  Active in DRIVE (01), WAIT (11), and DONE (10).
    wire data_hot = S0 | S1;

    // Write active in DRIVE and WAIT with RW low (write).
    wire write_active = cycle_active & ~cpu_rw;

    // ------------------------------------------------------------------
    // U2  74LS244  — low address buffer: 6502 A0-A7 -> bus ADDR[7:0]
    // U3  74LS244  — high address buffer: 6502 A8-A15 -> bus ADDR[15:8]
    //   OE_n tied to !data_hot so the bridge drives the address across
    //   DRIVE/WAIT/DONE.  The address must stay valid in DONE because
    //   RSTRB is also extended through DONE (for read-data hold); the
    //   target would otherwise see a floating address and latch X.
    // ------------------------------------------------------------------
    wire oe_n_addr = ~data_hot;

    wire [3:0] addr_lo_hi, addr_hi_hi;

    SN74LS244 U2 (
        .OE1_n(oe_n_addr), .A1(cpu_addr[3:0]),  .Y1(bus_addr[3:0]),
        .OE2_n(oe_n_addr), .A2(cpu_addr[7:4]),  .Y2(bus_addr[7:4])
    );

    SN74LS244 U3 (
        .OE1_n(oe_n_addr), .A1(cpu_addr[11:8]), .Y1(bus_addr[11:8]),
        .OE2_n(oe_n_addr), .A2(cpu_addr[15:12]),.Y2(bus_addr[15:12])
    );

    // Upper 8 bits of ADDR driven from the BUS_ADDR_BANK parameter.
    // Default 0x00 keeps single-card tests working at the bottom of the
    // bus space; in a multi-slot deployment this should be 0x40+slot.
    assign bus_addr[23:16] = BUS_ADDR_BANK;

    // ------------------------------------------------------------------
    // U1  74LS245  — bidirectional data transceiver
    //   DIR=1 (A->B): 6502 drives write data onto bus DATA[7:0]
    //   DIR=0 (B->A): bus drives read data back to the 6502
    //   OE_n=1: tri-state both sides (off-cycle)
    // ------------------------------------------------------------------
    wire u1_dir   = ~cpu_rw;          // write -> A->B
    wire u1_oe_n  = ~data_hot;        // enabled in DRIVE | WAIT | DONE

    SN74LS245 U1 (
        .DIR(u1_dir), .OE_n(u1_oe_n),
        .A(cpu_data), .B(bus_data[7:0])
    );

    // The bridge only uses byte lane 0; DATA[31:8] is never driven here.
    assign bus_data[31:8] = {24{1'bz}};

    // ------------------------------------------------------------------
    // Strobe generation
    //
    //   WSTRB[0] asserts ONLY during DRIVE/WAIT (cycle_active) when
    //   cpu_rw is low.  It does NOT extend into DONE — extending a
    //   write strobe would cause the target to latch the same byte
    //   twice, corrupting write-to-clear registers and FIFOs.
    //
    //   RSTRB asserts during DRIVE/WAIT *and* DONE when cpu_rw is
    //   high.  Extending through DONE keeps the target driving
    //   bus_data[7:0] until the 6502 has sampled it at the falling
    //   edge of PHI2.  Reads are idempotent so re-asserting the
    //   strobe is safe.
    //
    // On a real board these two terms live on the PAL/GAL mentioned at
    // U6 above, alongside the next-state logic.
    // ------------------------------------------------------------------
    assign bus_wstrb[0]   = cycle_active & ~cpu_rw;   // DRIVE | WAIT only
    assign bus_wstrb[3:1] = 3'b000;
    assign bus_rstrb      = data_hot     &  cpu_rw;   // DRIVE | WAIT | DONE

endmodule

`default_nettype wire
