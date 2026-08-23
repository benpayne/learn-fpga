// Cocotb top wrapper for the PAL/GAL 68000 bridge.
// Same external interface as bridge_68k_tb.v EXCEPT that the PAL bridge
// has no /IPL pins (the host-side interrupt controller now owns that
// path).  The Python test that checks /IPL is skipped in PAL mode.
`default_nettype none

module bridge_68k_pal_tb (
    input  wire        cpu_as_n,
    input  wire        cpu_uds_n,
    input  wire        cpu_lds_n,
    input  wire        cpu_rw,
    input  wire [22:0] cpu_addr,

    input  wire [15:0] cpu_data_drive,
    input  wire        cpu_data_drive_oe,
    output wire [15:0] cpu_data_observe,

    output wire        cpu_dtack_n,
    // /IPL pins kept as constant-high stubs so the Python test can
    // still reference them as DUT signals (PAL bridge has no IRQ logic).
    output wire        cpu_ipl0_n,
    output wire        cpu_ipl1_n,
    output wire        cpu_ipl2_n,
    input  wire        bus_irq,

    input  wire        bus_clk,
    input  wire        bus_reset_n
);
    wire [15:0] cpu_data;
    assign cpu_data = cpu_data_drive_oe ? cpu_data_drive : 16'bzzzzzzzzzzzzzzzz;
    assign cpu_data_observe = cpu_data;

    wire [23:0] bus_addr;
    wire [3:0]  bus_wstrb;
    wire        bus_rstrb;
    wire [31:0] bus_data;
    wire        bus_ready;

    // PAL bridge has no IRQ inputs/outputs.  For test parity, expose
    // /IPL pins driven high (no interrupt) so test_irq_passthrough can
    // still query them — that test will fail-fast and be skipped at the
    // Python level for PAL-target runs.
    assign cpu_ipl0_n = 1'b1;
    assign cpu_ipl1_n = 1'b1;
    assign cpu_ipl2_n = 1'b1;
    wire _unused_irq = &{1'b0, bus_irq, 1'b0};

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

    fake_bus_target_16 u_target (
        .bus_clk     (bus_clk),
        .bus_reset_n (bus_reset_n),
        .slot_sel_n  (1'b0),         // always selected (single-card test)
        .bus_addr    (bus_addr),
        .bus_wstrb   (bus_wstrb),
        .bus_rstrb   (bus_rstrb),
        .bus_data    (bus_data),
        .bus_ready   (bus_ready)
    );

    initial begin
        $dumpfile("bridge_68k_pal_tb.vcd");
        $dumpvars(0, bridge_68k_pal_tb);
    end
endmodule

`default_nettype wire
