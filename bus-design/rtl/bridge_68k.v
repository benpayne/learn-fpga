// ----------------------------------------------------------------------------
// bridge_68k.v — MC68000 host bridge onto the Retro-Active common bus
//
// Built structurally from 7400-series primitives.  BOM:
//   U1/U2/U3  74LS244  (address buffers: A1-A8, A9-A16, A17-A23)
//   U4        74LS245  (high-byte data: 68k D8-D15 <-> bus DATA[7:0])
//   U5        74LS245  (low-byte data:  68k D0-D7  <-> bus DATA[15:8])
//   U6        74LS74   (/AS synchroniser: 2 FFs into bus_clk domain)
//   U7        74LS74   (state machine: S1, S0 encode IDLE / ACTIVE / DONE)
//   U8        74LS00   (glue: strobe decoding, /DTACK, IPL inverter)
//
// Why the address buses look swapped across U4/U5
// -----------------------------------------------
// The 68000 is big-endian on the bus.  An access to an EVEN byte address
// uses /UDS and the data appears on D8-D15 (68k's "high byte").  An access
// to an ODD byte address uses /LDS and data appears on D0-D7.  The
// Retro-Active bus is byte-lane indexed by address offset: WSTRB[0] is the
// byte at ADDR+0, WSTRB[1] is ADDR+1, and so on.  So to line up the
// conventions we swap the 68k's halves when we cross the bridge:
//
//   bus DATA[7:0]   <->  68k D[15:8]   (UDS, even byte, WSTRB[0])
//   bus DATA[15:8]  <->  68k D[7:0]    (LDS, odd byte,  WSTRB[1])
//
// The cross-wiring lives in the instantiations of U4 / U5 below.
//
// State machine (bus_clk)
// -----------------------
//   IDLE  (00) -> ACTIVE (01)  when /AS is sync'd low
//   ACTIVE(01) -> DONE   (11)  when bus_ready asserts
//   ACTIVE(01) -> IDLE   (00)  if /AS goes high early (aborted cycle)
//   DONE  (11) -> IDLE   (00)  when /AS is sync'd high
//
// /DTACK is asserted low combinationally in the DONE state.  Once the
// 68000 sees /DTACK it samples (or completes) its cycle and deasserts
// /AS, which brings us back to IDLE.
// ----------------------------------------------------------------------------
`default_nettype none

module bridge_68k (
    // --- 68000 side ---
    input  wire        cpu_as_n,       // Address Strobe (active low)
    input  wire        cpu_uds_n,      // Upper Data Strobe (active low, byte at even addr)
    input  wire        cpu_lds_n,      // Lower Data Strobe (active low, byte at odd  addr)
    input  wire        cpu_rw,         // 1 = read, 0 = write
    input  wire [22:0] cpu_addr,       // A1..A23 (A0 is implicit in UDS/LDS)
    inout  wire [15:0] cpu_data,       // D0..D15
    output wire        cpu_dtack_n,    // Data Transfer Acknowledge (active low, back to CPU)
    output wire        cpu_ipl0_n,     // Interrupt priority lines (active low)
    output wire        cpu_ipl1_n,     // (we tie all three together for a single IRQ level)
    output wire        cpu_ipl2_n,
    input  wire        bus_irq,

    // --- Retro-Active bus side ---
    input  wire        bus_clk,
    input  wire        bus_reset_n,
    output wire [23:0] bus_addr,
    output wire [3:0]  bus_wstrb,
    output wire        bus_rstrb,
    inout  wire [31:0] bus_data,
    input  wire        bus_ready
);

    // ------------------------------------------------------------------
    // U6  74LS74  — /AS synchroniser (two FFs into bus_clk domain)
    // ------------------------------------------------------------------
    wire as_n_sync0, as_n_sync1;
    wire as_n_sync0_n, as_n_sync1_n;

    SN74LS74 U6 (
        .CLK1(bus_clk), .D1(cpu_as_n),
        .PRE1_n(1'b1), .CLR1_n(bus_reset_n),
        .Q1(as_n_sync0), .Q1_n(as_n_sync0_n),
        .CLK2(bus_clk), .D2(as_n_sync0),
        .PRE2_n(1'b1), .CLR2_n(bus_reset_n),
        .Q2(as_n_sync1), .Q2_n(as_n_sync1_n)
    );

    // as_active: true while the synchronised /AS is low (the CPU is driving
    // a valid cycle at us).  Using the synchroniser's second stage keeps
    // metastability off the FSM.
    wire as_active   =  as_n_sync1_n;     // /AS is low → CPU has a cycle going
    wire as_released =  as_n_sync1;       // /AS is high → CPU has ended it

    // ------------------------------------------------------------------
    // U7  74LS74  — state machine (S1, S0)
    //
    //   00 IDLE    : waiting for /AS low
    //   01 ACTIVE  : driving bus, waiting for bus_ready
    //   11 DONE    : /DTACK asserted back to CPU, waiting for /AS high
    //   (10 is unreachable)
    //
    // On a real board the next-state logic collapses into one PAL/GAL or
    // a second 74-series package; here we express the terms long-hand.
    // ------------------------------------------------------------------
    wire S1, S0;
    wire S1_n, S0_n;

    wire S1_next =
          (~S1 &  S0 & bus_ready)           // ACTIVE + ready  → DONE
        | ( S1 &  S0 & as_active);          // DONE + /AS low  → stay in DONE

    wire S0_next =
          (~S1 & ~S0 & as_active)           // IDLE  + /AS low → ACTIVE
        | (~S1 &  S0 & as_active)           // ACTIVE while /AS still low: stay or advance (S0 holds)
        | ( S1 &  S0 & as_active);          // DONE + /AS low  → stay

    SN74LS74 U7 (
        .CLK1(bus_clk), .D1(S1_next),
        .PRE1_n(1'b1), .CLR1_n(bus_reset_n),
        .Q1(S1), .Q1_n(S1_n),

        .CLK2(bus_clk), .D2(S0_next),
        .PRE2_n(1'b1), .CLR2_n(bus_reset_n),
        .Q2(S0), .Q2_n(S0_n)
    );

    // cycle_active: any state past IDLE — used to enable address + data
    // buffers for the full cycle (including the DONE hold period so the
    // 68000 has valid data when it samples on /DTACK).
    wire cycle_active = S0;          // high in ACTIVE (01) and DONE (11)
    wire in_done      = S1 & S0;     // high only in DONE

    // ------------------------------------------------------------------
    // U8  74LS00  — glue: /DTACK generation + IPL inverter
    //
    // Two NAND gates here; the remaining two are either unused or fold
    // into the strobe-decode logic on a real board's PAL/GAL.
    // ------------------------------------------------------------------
    wire [3:0] u8_a, u8_b, u8_y;

    // Gate 0: /DTACK  = ~in_done  = NAND(S1, S0)
    assign u8_a[0] = S1;
    assign u8_b[0] = S0;

    // Gate 1: IRQ inverter → /IPL (single level; all three IPL pins tied
    // together is the minimum viable 68k interrupt path).
    assign u8_a[1] = bus_irq;
    assign u8_b[1] = bus_irq;

    // Unused gates are tied low so iverilog doesn't see floating inputs.
    assign u8_a[2] = 1'b0;
    assign u8_b[2] = 1'b0;
    assign u8_a[3] = 1'b0;
    assign u8_b[3] = 1'b0;

    SN74LS00 U8 (.A(u8_a), .B(u8_b), .Y(u8_y));

    assign cpu_dtack_n = u8_y[0];
    wire   ipl_active  = ~u8_y[1];   // bus_irq inverted → CPU's IPL lines
    assign cpu_ipl0_n  = u8_y[1];
    assign cpu_ipl1_n  = u8_y[1];
    assign cpu_ipl2_n  = u8_y[1];

    // ------------------------------------------------------------------
    // U1 / U2 / U3  74LS244  — address buffers A1..A23 → bus ADDR[23:1]
    //   bus ADDR[0] is always 0 (68k has no A0 pin; byte select is via
    //   UDS/LDS).  OE tied to !cycle_active so the bridge stops driving
    //   the bus the instant the cycle ends.
    // ------------------------------------------------------------------
    wire oe_n_addr = ~cycle_active;

    SN74LS244 U1 (
        .OE1_n(oe_n_addr), .A1(cpu_addr[3:0]),  .Y1(bus_addr[4:1]),
        .OE2_n(oe_n_addr), .A2(cpu_addr[7:4]),  .Y2(bus_addr[8:5])
    );

    SN74LS244 U2 (
        .OE1_n(oe_n_addr), .A1(cpu_addr[11:8]),  .Y1(bus_addr[12:9]),
        .OE2_n(oe_n_addr), .A2(cpu_addr[15:12]), .Y2(bus_addr[16:13])
    );

    // U3 bank 1 covers bus_addr[20:17]; bank 2 covers bus_addr[23:21]
    // with one of its four lines dangled.  An earlier sketch wired
    // bank 2 to bus_addr[23:20], which silently double-drove bus_addr[20]
    // — single-card tests hid the issue because every test address
    // happened to set cpu_addr[20]==cpu_addr[19].  Multi-slot tests
    // (e.g. 0x430010) exposed it.
    wire u3_y2_lsb_unused;
    SN74LS244 U3 (
        .OE1_n(oe_n_addr), .A1(cpu_addr[19:16]),       .Y1(bus_addr[20:17]),
        .OE2_n(oe_n_addr), .A2({cpu_addr[22:20], 1'b0}), .Y2({bus_addr[23:21], u3_y2_lsb_unused})
    );

    // Bus ADDR[0] is always zero from the 68k's perspective.
    assign bus_addr[0] = 1'b0;

    // ------------------------------------------------------------------
    // U4 / U5  74LS245  — bidirectional 16-bit data path with 68k's
    //                     big-endian byte alignment baked into the
    //                     cross-wiring.  See the header comment.
    //
    //   U4: 68k D[15:8] (UDS byte, even address) ↔ bus DATA[7:0]
    //   U5: 68k D[ 7:0] (LDS byte, odd  address) ↔ bus DATA[15:8]
    //
    // Each 245 is OE'd only while its own strobe is active so the bridge
    // doesn't interfere with the other byte lane.  Direction follows R/W.
    // ------------------------------------------------------------------
    wire dir_write   = ~cpu_rw;               // write → A→B
    wire u4_oe_n     = ~(cycle_active & ~cpu_uds_n);
    wire u5_oe_n     = ~(cycle_active & ~cpu_lds_n);

    SN74LS245 U4 (
        .DIR(dir_write), .OE_n(u4_oe_n),
        .A(cpu_data[15:8]), .B(bus_data[7:0])
    );

    SN74LS245 U5 (
        .DIR(dir_write), .OE_n(u5_oe_n),
        .A(cpu_data[7:0]),  .B(bus_data[15:8])
    );

    // Bus DATA[31:16] is left tri-state; this is a 16-bit host.
    assign bus_data[31:16] = {16{1'bz}};

    // ------------------------------------------------------------------
    // Strobe decoding
    //
    //   WSTRB[0] = cycle_active & /UDS asserted & write   (even byte)
    //   WSTRB[1] = cycle_active & /LDS asserted & write   (odd  byte)
    //   WSTRB[3:2] = 0                                    (only 2 lanes)
    //   RSTRB    = cycle_active & read & (/UDS or /LDS asserted)
    //
    //   RSTRB stays asserted through DONE so the target keeps driving read
    //   data until the 68k samples it on /DTACK.  WSTRB does NOT extend
    //   through DONE — same rationale as the 6502 bridge: re-asserting a
    //   write strobe would corrupt FIFOs / write-to-clear registers.
    //
    // These equations live on the PAL/GAL alongside U8 on a real board.
    // ------------------------------------------------------------------
    wire in_active = S0 & ~S1;    // ACTIVE state only (writes strobe here)

    assign bus_wstrb[0]   = in_active & ~cpu_rw & ~cpu_uds_n;
    assign bus_wstrb[1]   = in_active & ~cpu_rw & ~cpu_lds_n;
    assign bus_wstrb[3:2] = 2'b00;
    assign bus_rstrb      = cycle_active &  cpu_rw & (~cpu_uds_n | ~cpu_lds_n);

    // Keep lint quiet about genuinely unused signals.
    wire _unused = &{1'b0, as_n_sync0_n, ipl_active, S1_n, S0_n, 1'b0};

endmodule

`default_nettype wire
