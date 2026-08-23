// ----------------------------------------------------------------------------
// fake_bus_target.v — minimal bus target for bridge validation.
// 64 KB byte-addressable memory on bus DATA[7:0].  One bus clk from strobe
// to READY, drives read data on the *same* cycle READY is asserted.
// ----------------------------------------------------------------------------
`default_nettype none

// 64 KB byte-addressable memory sitting on the bus.  Only the low 16 bits
// of bus_addr are decoded (matches the 6502-bridge's 16-bit address span).
// No initial-loop memory wipe: the tristate-control registers are now
// initialised at declaration (below) so there's no X-propagation at t=0
// and tests always write before they read.
module fake_bus_target #(
    parameter integer ADDR_BITS = 16
)(
    input  wire        bus_clk,
    input  wire        bus_reset_n,
    input  wire        slot_sel_n,    // active-low chip select from backplane
    input  wire [23:0] bus_addr,
    input  wire [3:0]  bus_wstrb,
    input  wire        bus_rstrb,
    inout  wire [31:0] bus_data,
    output wire        bus_ready
);
    localparam integer N = (1 << ADDR_BITS);

    reg [7:0] mem [0:N-1];
    reg [7:0] read_byte    = 8'h00;
    reg       drive_read   = 1'b0;
    reg       drive_read_d = 1'b0;
    reg       ready_q      = 1'b0;

    wire selected = ~slot_sel_n;
    wire [3:0]  gated_wstrb = selected ? bus_wstrb : 4'h0;
    wire        gated_rstrb = selected & bus_rstrb;

    wire [ADDR_BITS-1:0] idx = bus_addr[ADDR_BITS-1:0];

    always @(posedge bus_clk or negedge bus_reset_n) begin
        if (!bus_reset_n) begin
            ready_q      <= 1'b0;
            drive_read   <= 1'b0;
            drive_read_d <= 1'b0;
        end else begin
            ready_q      <= 1'b0;
            drive_read_d <= drive_read;
            drive_read   <= 1'b0;
            if (gated_wstrb[0]) begin
                mem[idx]  <= bus_data[7:0];
                ready_q   <= 1'b1;
            end else if (gated_rstrb) begin
                read_byte  <= mem[idx];
                drive_read <= 1'b1;
                ready_q    <= 1'b1;
            end
        end
    end

    // bus_ready: drive 1 only when this card is selected AND
    // acknowledging.  In multi-card setups the wrapper ORs the
    // bus_ready outputs of every card; this signal contributes 0
    // unless we own the cycle.  In single-card tests slot_sel_n=0,
    // so this collapses to plain ready_q.
    assign bus_ready = selected & ready_q;

    // Drive read data for two cycles so the master's bridge has valid
    // data through its DONE / data-hold state.  Tri-state when we don't
    // own the cycle.
    wire driving = drive_read | drive_read_d;
    assign bus_data[7:0] = driving ? read_byte : 8'bzzzzzzzz;
endmodule

`default_nettype wire
