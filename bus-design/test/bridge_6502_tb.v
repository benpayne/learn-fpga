// ----------------------------------------------------------------------------
// bridge_6502_tb.v — top-level Verilog wrapper for cocotb simulation.
// Instantiates the bridge and a fake bus target, exposes both sides as
// ports so the Python testbench can drive the 6502 interface.
// ----------------------------------------------------------------------------
`default_nettype none

module bridge_6502_tb (
    // 6502-side signals (driven from cocotb)
    input  wire        cpu_phi2,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_rw,
    input  wire [7:0]  cpu_data_drive,       // write data from the simulated 6502
    input  wire        cpu_data_drive_oe,    // 1 = 6502 drives cpu_data
    output wire [7:0]  cpu_data_observe,     // what the bridge is presenting to the 6502
    output wire        cpu_irq_n,
    input  wire        bus_irq,

    // Bus clock / reset (driven from cocotb)
    input  wire        bus_clk,
    input  wire        bus_reset_n
);
    // Shared 6502-side data lines.  Cocotb drives only when
    // cpu_data_drive_oe is high (writes); the bridge drives during reads.
    wire [7:0] cpu_data;
    assign cpu_data = cpu_data_drive_oe ? cpu_data_drive : 8'bzzzzzzzz;
    assign cpu_data_observe = cpu_data;

    // Bus-side shared nets
    wire [23:0] bus_addr;
    wire [3:0]  bus_wstrb;
    wire        bus_rstrb;
    wire [31:0] bus_data;
    wire        bus_ready;

    bridge_6502 u_bridge (
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

    // Wave dumping for debug.
    initial begin
        $dumpfile("bridge_6502_tb.vcd");
        $dumpvars(0, bridge_6502_tb);
    end
endmodule

`default_nettype wire
