// ----------------------------------------------------------------------------
// fake_bus_target_16.v — 64 KB byte-addressable memory that speaks the
// Retro-Active bus with two active byte lanes (0 and 1).  Used to verify
// 16-bit hosts like the 68k.
//
// Write: on posedge bus_clk, if WSTRB[n] is high, latch bus_data[n*8+7:n*8]
// into mem[bus_addr | n].  Asserts bus_ready the same cycle.
//
// Read: on posedge bus_clk, if RSTRB is high, latch mem[bus_addr..bus_addr+1]
// into the read register and enable the tristate drivers.  As with the
// 6502 target, the drivers hold one extra cycle so the master's bridge
// has valid data in its DONE state.
// ----------------------------------------------------------------------------
`default_nettype none

module fake_bus_target_16 (
    input  wire        bus_clk,
    input  wire        bus_reset_n,
    input  wire        slot_sel_n,    // active-low chip select from backplane
    input  wire [23:0] bus_addr,
    input  wire [3:0]  bus_wstrb,
    input  wire        bus_rstrb,
    inout  wire [31:0] bus_data,
    output wire        bus_ready
);
    reg [7:0] mem [0:65535];

    reg [7:0] read_byte0     = 8'h00;
    reg [7:0] read_byte1     = 8'h00;
    reg       drive_read     = 1'b0;
    reg       drive_read_d   = 1'b0;
    reg       ready_q        = 1'b0;

    wire selected = ~slot_sel_n;
    wire [3:0]  gated_wstrb = selected ? bus_wstrb : 4'h0;
    wire        gated_rstrb = selected & bus_rstrb;

    wire [15:0] idx0 = bus_addr[15:0];
    wire [15:0] idx1 = idx0 + 16'd1;

    always @(posedge bus_clk or negedge bus_reset_n) begin
        if (!bus_reset_n) begin
            ready_q      <= 1'b0;
            drive_read   <= 1'b0;
            drive_read_d <= 1'b0;
        end else begin
            ready_q      <= 1'b0;
            drive_read_d <= drive_read;
            drive_read   <= 1'b0;

            if (gated_wstrb[0] || gated_wstrb[1]) begin
                if (gated_wstrb[0]) mem[idx0] <= bus_data[7:0];
                if (gated_wstrb[1]) mem[idx1] <= bus_data[15:8];
                ready_q <= 1'b1;
            end else if (gated_rstrb) begin
                read_byte0 <= mem[idx0];
                read_byte1 <= mem[idx1];
                drive_read <= 1'b1;
                ready_q    <= 1'b1;
            end
        end
    end

    // bus_ready contributes 1 only when we're selected AND
    // acknowledging.  Multi-card wrappers OR every card's ready
    // together; single-card tests collapse this to ready_q.
    assign bus_ready = selected & ready_q;

    wire drive_any = drive_read | drive_read_d;
    assign bus_data[7:0]   = drive_any ? read_byte0 : 8'bzzzzzzzz;
    assign bus_data[15:8]  = drive_any ? read_byte1 : 8'bzzzzzzzz;
    assign bus_data[31:16] = {16{1'bz}};

    // Keep unused strobes quiet.
    wire _unused = &{1'b0, bus_wstrb[3:2], 1'b0};
endmodule

`default_nettype wire
