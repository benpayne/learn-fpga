// ----------------------------------------------------------------------------
// bridge_6502_multislot_tb.v — multi-card test for the 6502 bridge.
//
// The 6502 has only 16 address bits, so its 64 KB window is mapped onto
// a single slot (slot 0) by tying BUS_ADDR_BANK = 0x40.  A second card
// is parked at slot 5 (bus address 0x450000-0x45FFFF) — the 6502 cannot
// reach it, so its writes/reads must NEVER affect the slot-5 card.
//
// This is the realistic deployment shape for a 6502 in a Retro-Active
// system: one slot via the bridge, the rest of the slots populated and
// driven by other hosts (e.g. a 68k on its own bridge), or unused.
//
// The test uses the PAL bridge for the host side (4 chips); the
// pure-74 bridge would behave identically.
// ----------------------------------------------------------------------------
`default_nettype none

module bridge_6502_multislot_tb (
    // 6502 side
    input  wire        cpu_phi2,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_data_drive,
    input  wire        cpu_data_drive_oe,
    output wire [7:0]  cpu_data_observe,
    output wire        cpu_irq_n,
    input  wire        bus_irq,

    // Bus side
    input  wire        bus_clk,
    input  wire        bus_reset_n
);
    wire [7:0] cpu_data;
    assign cpu_data = cpu_data_drive_oe ? cpu_data_drive : 8'bzzzzzzzz;
    assign cpu_data_observe = cpu_data;

    wire [23:0] bus_addr;
    wire [3:0]  bus_wstrb;
    wire        bus_rstrb;
    wire [31:0] bus_data;
    wire        ready_a;
    wire        ready_b;
    wire        bus_ready = ready_a | ready_b;
    wire [15:0] slot_sel_n;

    // Bridge: 6502 mapped to slot 0 in the IO region (ADDR[23:16]=0x40).
    bridge_6502_pal #(.BUS_ADDR_BANK(8'h40)) u_bridge (
        .cpu_phi2    (cpu_phi2),
        .cpu_addr    (cpu_addr),
        .cpu_rw      (cpu_rw),
        .cpu_data    (cpu_data),
        .bus_irq     (bus_irq),
        .cpu_irq_n   (cpu_irq_n),
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (bus_ready)
    );

    // Backplane decoder: one 74LS154 + comparator.
    backplane_decoder u_decoder (
        .bus_addr   (bus_addr),
        .bus_wstrb  (bus_wstrb),
        .bus_rstrb  (bus_rstrb),
        .slot_sel_n (slot_sel_n)
    );

    // Card A at slot 0 — the slot the 6502 talks to.
    fake_bus_target u_card_a (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .slot_sel_n  (slot_sel_n[0]),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (ready_a)
    );

    // Card B at slot 5 — must stay quiet under all 6502-driven cycles.
    // The 6502 has no addresses that decode to slot 5 (its bridge bank
    // is hard-wired to 0x40), so this card should never be selected.
    fake_bus_target u_card_b (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .slot_sel_n  (slot_sel_n[5]),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (ready_b)
    );

    initial begin
        $dumpfile("bridge_6502_multislot_tb.vcd");
        $dumpvars(0, bridge_6502_multislot_tb);
    end
endmodule

`default_nettype wire
