// ----------------------------------------------------------------------------
// bridge_68k_multislot_tb.v — multi-card test top.
//
// One 68k bridge → one backplane decoder → two fake_bus_target_16 cards
// living at different slots.  This exercises the full multi-slot model
// from the Architecture page: address-decoded SLOT_SEL_n, per-card
// bus_ready, slot isolation.
//
// Slot assignments:
//   - Card A at slot 3  (bus address 0x430000-0x43FFFF)
//   - Card B at slot 7  (bus address 0x470000-0x47FFFF)
//
// The CPU address space is 1:1 with the bus address space (the 68k
// bridge passes addresses through unmodified), so the CPU writes to
// 0x430000+offset to hit card A and 0x470000+offset to hit card B.
// ----------------------------------------------------------------------------
`default_nettype none

module bridge_68k_multislot_tb (
    // 68000 side
    input  wire        cpu_as_n,
    input  wire        cpu_uds_n,
    input  wire        cpu_lds_n,
    input  wire        cpu_rw,
    input  wire [22:0] cpu_addr,

    input  wire [15:0] cpu_data_drive,
    input  wire        cpu_data_drive_oe,
    output wire [15:0] cpu_data_observe,

    output wire        cpu_dtack_n,

    // Stub for compatibility with the shared reset() helper.  The PAL
    // bridge has no IRQ logic — interrupt aggregation lives in the
    // host-side interrupt controller — so this input is unused.
    input  wire        bus_irq,

    // Bus side
    input  wire        bus_clk,
    input  wire        bus_reset_n
);
    wire _unused_irq = &{1'b0, bus_irq, 1'b0};
    wire [15:0] cpu_data;
    assign cpu_data = cpu_data_drive_oe ? cpu_data_drive : 16'bzzzzzzzzzzzzzzzz;
    assign cpu_data_observe = cpu_data;

    // Shared bus signals
    wire [23:0] bus_addr;
    wire [3:0]  bus_wstrb;
    wire        bus_rstrb;
    wire [31:0] bus_data;

    // Each card drives its own ready output, ORed together to form
    // the bus's READY line.  Real hardware does this with open-drain
    // ready lines and a pull-up on the backplane; the OR-of-defined
    // levels here is functionally equivalent for simulation.
    wire        ready_a;
    wire        ready_b;
    wire        bus_ready = ready_a | ready_b;

    // Slot selects from the backplane decoder
    wire [15:0] slot_sel_n;

    // The PAL bridge is the cleaner choice for the multislot demo —
    // fewer chips, same behaviour as the pure-74 build.
    bridge_68k_pal u_bridge (
        .cpu_as_n    (cpu_as_n),
        .cpu_uds_n   (cpu_uds_n),
        .cpu_lds_n   (cpu_lds_n),
        .cpu_rw      (cpu_rw),
        .cpu_addr    (cpu_addr),
        .cpu_data    (cpu_data),
        .cpu_dtack_n (cpu_dtack_n),
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (bus_ready)
    );

    // Backplane: one 74LS154 + comparator + strobe-OR.
    backplane_decoder u_decoder (
        .bus_addr   (bus_addr),
        .bus_wstrb  (bus_wstrb),
        .bus_rstrb  (bus_rstrb),
        .slot_sel_n (slot_sel_n)
    );

    // Card A at slot 3
    fake_bus_target_16 u_card_a (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .slot_sel_n  (slot_sel_n[3]),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (ready_a)
    );

    // Card B at slot 7
    fake_bus_target_16 u_card_b (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .slot_sel_n  (slot_sel_n[7]),
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (ready_b)
    );

    initial begin
        $dumpfile("bridge_68k_multislot_tb.vcd");
        $dumpvars(0, bridge_68k_multislot_tb);
    end
endmodule

`default_nettype wire
