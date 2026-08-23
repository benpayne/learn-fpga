// ----------------------------------------------------------------------------
// bridge_6502_pal.v — Compact 6502 bridge using one 22V10 PAL/GAL.
//
// Same behaviour as bridge_6502.v (the pure-74-series build), but with all
// of the FSM, PHI2 synchroniser, strobe gating, IRQ inverter, and
// output-enable logic absorbed into a single 22V10.  The 74LS245 and the
// two 74LS244s remain as physical chips because the 22V10 only has 10
// I/O pins — not enough to drive a 16-bit address bus directly.
//
//                              BOM: 4 chips
//   U1  74LS245   (data D[7:0] transceiver)
//   U2  74LS244   (address A[7:0] buffer)
//   U3  74LS244   (address A[15:8] buffer)
//   U4  22V10     (FSM + sync + strobes + OEs + IRQ inv)
//
// Compared with the pure-74 build (9 chips), the PAL absorbs U4-U9:
// the two 74LS74 dual flip-flops, the 74LS00 NAND quad, both 74LS08
// AND quads, and the 74LS32 OR quad.
//
// 22V10 macrocell allocation (8 of 10 used, 2 spare):
//   M1  phi2_sync0   registered  (D = cpu_phi2,        clk = bus_clk)
//   M2  phi2_sync1   registered  (D = phi2_sync0,      clk = bus_clk)
//   M3  S0           registered  (D = S0_next,         clk = bus_clk)
//   M4  S1           registered  (D = S1_next,         clk = bus_clk)
//   M5  oe_n         combinational  (= ~(S0 | S1)  — drives U1, U2, U3 OE_n)
//   M6  bus_wstrb_0  combinational  (= S0 & ~cpu_rw)
//   M7  bus_rstrb    combinational  (= (S0 | S1) & cpu_rw)
//   M8  cpu_irq_n    combinational  (= ~bus_irq)
//
// All four FFs share bus_reset_n on their async-clear input.
// ----------------------------------------------------------------------------
`default_nettype none

// 22V10 contents — written behaviourally so it maps cleanly to JEDEC equations.
module pal_22v10_6502 (
    input  wire bus_clk,
    input  wire bus_reset_n,
    input  wire cpu_phi2,
    input  wire cpu_rw,
    input  wire bus_ready,
    input  wire bus_irq,
    output wire oe_n,        // shared OE_n for U1/U2/U3 (active low when bridge owns the bus)
    output wire bus_wstrb_0,
    output wire bus_rstrb,
    output wire cpu_irq_n
);
    // Registered macrocells
    reg phi2_sync0 = 1'b0;
    reg phi2_sync1 = 1'b0;
    reg S0         = 1'b0;
    reg S1         = 1'b0;

    // Edge detect from the synchroniser pair
    wire phi2_rising = phi2_sync0 & ~phi2_sync1;

    // State machine equations (same as bridge_6502.v's pure-74 version,
    // simplified to two productive terms each)
    wire S1_next = S0 | (S1 & phi2_sync1);
    wire S0_next = (~S1 & (S0 | phi2_rising))
                 | ( S1 &  S0 & ~bus_ready);

    always @(posedge bus_clk or negedge bus_reset_n) begin
        if (!bus_reset_n) begin
            phi2_sync0 <= 1'b0;
            phi2_sync1 <= 1'b0;
            S0         <= 1'b0;
            S1         <= 1'b0;
        end else begin
            phi2_sync0 <= cpu_phi2;
            phi2_sync1 <= phi2_sync0;
            S0         <= S0_next;
            S1         <= S1_next;
        end
    end

    // Combinational outputs
    wire data_hot = S0 | S1;            // active in DRIVE / WAIT / DONE
    assign oe_n        = ~data_hot;
    assign bus_wstrb_0 = S0 & ~cpu_rw;
    assign bus_rstrb   = data_hot & cpu_rw;
    assign cpu_irq_n   = ~bus_irq;
endmodule


// Top-level bridge: 1 PAL + 2 LS244 + 1 LS245 = 4 chips.
module bridge_6502_pal #(
    // Upper 8 bits of the bus address (slot bank).  See bridge_6502.v
    // header for full discussion.  Default 0x00 preserves single-card
    // test compatibility; 0x40+N maps the 6502 to slot N in the IO
    // region.
    parameter [7:0] BUS_ADDR_BANK = 8'h00
) (
    // 6502 side
    input  wire        cpu_phi2,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    inout  wire [7:0]  cpu_data,
    input  wire        bus_irq,
    output wire        cpu_irq_n,

    // Bus side
    input  wire        bus_clk,
    input  wire        bus_reset_n,
    output wire [23:0] bus_addr,
    output wire [3:0]  bus_wstrb,
    output wire        bus_rstrb,
    inout  wire [31:0] bus_data,
    input  wire        bus_ready
);
    // U4 — single 22V10 PAL/GAL holds all the glue logic.
    wire oe_n;
    wire bus_wstrb_0;

    pal_22v10_6502 U4 (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .cpu_phi2    (cpu_phi2),
        .cpu_rw      (cpu_rw),
        .bus_ready   (bus_ready),
        .bus_irq     (bus_irq),
        .oe_n        (oe_n),
        .bus_wstrb_0 (bus_wstrb_0),
        .bus_rstrb   (bus_rstrb),
        .cpu_irq_n   (cpu_irq_n)
    );

    // Address buffers (U2, U3) — driven only when oe_n is low.
    SN74LS244 U2 (
        .OE1_n(oe_n), .A1(cpu_addr[3:0]),  .Y1(bus_addr[3:0]),
        .OE2_n(oe_n), .A2(cpu_addr[7:4]),  .Y2(bus_addr[7:4])
    );

    SN74LS244 U3 (
        .OE1_n(oe_n), .A1(cpu_addr[11:8]),  .Y1(bus_addr[11:8]),
        .OE2_n(oe_n), .A2(cpu_addr[15:12]), .Y2(bus_addr[15:12])
    );

    assign bus_addr[23:16] = BUS_ADDR_BANK;

    // Data transceiver (U1) — direction follows R/W, OE follows oe_n.
    SN74LS245 U1 (
        .DIR(~cpu_rw), .OE_n(oe_n),
        .A(cpu_data), .B(bus_data[7:0])
    );

    assign bus_data[31:8] = {24{1'bz}};

    // WSTRB[3:1] tied low (8-bit byte-lane-zero host).
    assign bus_wstrb[0]   = bus_wstrb_0;
    assign bus_wstrb[3:1] = 3'b000;
endmodule

`default_nettype wire
