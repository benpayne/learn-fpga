// ----------------------------------------------------------------------------
// backplane_decoder.v — 16-slot SLOT_SEL_n generator.
//
// Models the small piece of logic that lives on the backplane (not on
// any card or any host bridge) and is shared by every slot:
//
//   1. A 4-bit comparator checks whether ADDR[23:20] == 0x4 (the IO tag).
//   2. A strobe-OR gates the decoder enable so SLOT_SEL_n only goes low
//      while a card cycle is actually in progress.
//   3. A 74LS154-style 4-to-16 decoder turns ADDR[19:16] into 16
//      active-low slot selects.
//
// Real backplane BOM:
//   - 1× 74LS154   4-to-16 line decoder, active-low outputs
//   - 1× 74LS85    4-bit magnitude comparator (ADDR[23:20] vs 4'h4)
//   - 1× 74LS32    Quad OR (WSTRB[3:0] OR RSTRB → cycle-active enable)
//   ≈ 3 chips on the backplane, amortised over every slot in the system.
// ----------------------------------------------------------------------------
`default_nettype none

module backplane_decoder (
    input  wire [23:0] bus_addr,
    input  wire [3:0]  bus_wstrb,
    input  wire        bus_rstrb,
    output wire [15:0] slot_sel_n
);
    // 1. IO-region check
    wire io_match = (bus_addr[23:20] == 4'h4);

    // 2. Cycle-active: any strobe asserted
    wire cycle_active = bus_rstrb | bus_wstrb[0] | bus_wstrb[1]
                                  | bus_wstrb[2] | bus_wstrb[3];

    // 3. Decoder enable (active-high)
    wire enable = io_match & cycle_active;

    // 4. 4-to-16 decoder, active-low outputs.  When `enable` is low,
    //    every output is high (no slot selected).
    wire [3:0] slot = bus_addr[19:16];

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : decode_loop
            assign slot_sel_n[i] = ~(enable & (slot == i[3:0]));
        end
    endgenerate
endmodule

`default_nettype wire
