// Cocotb top wrapper for the PAL/GAL 6502 bridge.
// Same external interface as bridge_6502_tb.v so the existing Python
// test suite (bridge_6502_tb.py) runs against either implementation.
`default_nettype none

module bridge_6502_pal_tb (
    input  wire        cpu_phi2,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_data_drive,
    input  wire        cpu_data_drive_oe,
    output wire [7:0]  cpu_data_observe,
    output wire        cpu_irq_n,
    input  wire        bus_irq,
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
    wire        bus_ready;

    bridge_6502_pal u_bridge (
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

    fake_bus_target u_target (
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
        $dumpfile("bridge_6502_pal_tb.vcd");
        $dumpvars(0, bridge_6502_pal_tb);
    end
endmodule

`default_nettype wire
