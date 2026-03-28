// hdmi_test_top.v - Minimal HDMI test pattern for Colorlight i5
//
// Generates a simple color bar pattern over HDMI without any CPU.
// Use this to verify HDMI output works at the hardware level.
//
// Build: yosys -p "read_verilog hdmi_test_top.v; synth_ecp5 -abc9 -top hdmi_test -json hdmi_test.json"
//        nextpnr-ecp5 --force --timing-allow-fail --json hdmi_test.json --lpf ../BOARDS/colorlight_i5.lpf --textcfg hdmi_test_out.config --25k --freq 25 --package CABGA381
//        ecppack --compress hdmi_test_out.config hdmi_test.bit

`default_nettype none

module hdmi_test(
    input  pclk,
    input  RESET,
    output [3:0] gpdi_dp
);

    //==========================================================================
    // PLL: 25 MHz -> 25 MHz pixel + 125 MHz TMDS
    //==========================================================================
    wire clk_pixel;
    wire clk_tmds;
    wire pll_locked;

    wire CLKOP_internal;

    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .CLKI_DIV(1),
        .CLKFB_DIV(1),              // VCO = 25MHz * 1 * 20 / 1 = 500MHz
        .FEEDBK_PATH("CLKOP"),
        .OUTDIVIDER_MUXA("DIVA"),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(20),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0),
        .OUTDIVIDER_MUXB("DIVB"),
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_DIV(4),
        .CLKOS_CPHASE(0),
        .CLKOS_FPHASE(0),
        .OUTDIVIDER_MUXC("DIVC"),
        .CLKOS2_ENABLE("DISABLED"),
        .CLKOS2_DIV(1),
        .CLKOS2_CPHASE(0),
        .CLKOS2_FPHASE(0),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKOS3_ENABLE("DISABLED"),
        .CLKOS3_DIV(1),
        .CLKOS3_CPHASE(0),
        .CLKOS3_FPHASE(0),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .PLLRST_ENA("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .PLL_LOCK_MODE(0)
    ) pll_inst (
        .CLKI(pclk),
        .CLKOP(CLKOP_internal),
        .CLKOS(clk_tmds),
        .CLKOS2(),
        .CLKOS3(),
        .CLKFB(CLKOP_internal),
        .CLKINTFB(),
        .RST(1'b0),
        .STDBY(1'b0),
        .PHASESEL1(1'b0),
        .PHASESEL0(1'b0),
        .PHASEDIR(1'b0),
        .PHASESTEP(1'b0),
        .PHASELOADREG(1'b0),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .ENCLKOS(1'b0),
        .ENCLKOS2(1'b0),
        .ENCLKOS3(1'b0),
        .LOCK(pll_locked)
    );

    assign clk_pixel = CLKOP_internal;

    //==========================================================================
    // VGA Timing: 640x480@60Hz (most compatible with monitors)
    //==========================================================================
    localparam H_VISIBLE = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48;
    localparam H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK; // 800
    localparam V_VISIBLE = 480, V_FRONT = 10, V_SYNC = 2, V_BACK = 33;
    localparam V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK; // 525

    reg [9:0] h_count = 0;
    reg [9:0] v_count = 0;

    always @(posedge clk_pixel) begin
        if (h_count == H_TOTAL - 1) begin
            h_count <= 0;
            if (v_count == V_TOTAL - 1)
                v_count <= 0;
            else
                v_count <= v_count + 1;
        end else begin
            h_count <= h_count + 1;
        end
    end

    wire hsync = ~((h_count >= H_VISIBLE + H_FRONT) && (h_count < H_VISIBLE + H_FRONT + H_SYNC));
    wire vsync = ~((v_count >= V_VISIBLE + V_FRONT) && (v_count < V_VISIBLE + V_FRONT + V_SYNC));
    wire video_active = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);
    wire blank = ~video_active;

    //==========================================================================
    // Test Pattern: 8 vertical color bars
    //==========================================================================
    wire [2:0] bar = h_count[9:7]; // 8 bars across 640 pixels (80px each)

    wire [7:0] red   = video_active ? (bar[2] ? 8'hFF : 8'h00) : 8'h00;
    wire [7:0] green = video_active ? (bar[1] ? 8'hFF : 8'h00) : 8'h00;
    wire [7:0] blue  = video_active ? (bar[0] ? 8'hFF : 8'h00) : 8'h00;

    //==========================================================================
    // TMDS Encoding (inline, minimal)
    //==========================================================================
    wire [9:0] tmds_red, tmds_green, tmds_blue;

    tmds_enc enc_r(.clk(clk_pixel), .DE(video_active), .D(red),   .C1(1'b0),    .C0(1'b0),    .q_out(tmds_red));
    tmds_enc enc_g(.clk(clk_pixel), .DE(video_active), .D(green), .C1(1'b0),    .C0(1'b0),    .q_out(tmds_green));
    tmds_enc enc_b(.clk(clk_pixel), .DE(video_active), .D(blue),  .C1(vsync),   .C0(hsync),   .q_out(tmds_blue));

    //==========================================================================
    // 10:1 DDR Serialization
    //==========================================================================
    reg [3:0] tmds_mod = 0;
    reg       tmds_load = 0;
    reg [9:0] sr_r = 0, sr_g = 0, sr_b = 0, sr_c = 0;

    localparam [9:0] CLK_PATTERN = 10'b00000_11111;

    always @(posedge clk_tmds) begin
        tmds_mod  <= (tmds_mod == 4) ? 0 : tmds_mod + 1;
        tmds_load <= (tmds_mod == 4);
    end

    always @(posedge clk_tmds) begin
        if (tmds_load) begin
            sr_r <= tmds_red;
            sr_g <= tmds_green;
            sr_b <= tmds_blue;
            sr_c <= CLK_PATTERN;
        end else begin
            sr_r <= {2'b00, sr_r[9:2]};
            sr_g <= {2'b00, sr_g[9:2]};
            sr_b <= {2'b00, sr_b[9:2]};
            sr_c <= {2'b00, sr_c[9:2]};
        end
    end

    //==========================================================================
    // DDR Output Primitives
    //==========================================================================
    ODDRX1F ddr_clk  (.D0(sr_c[0]), .D1(sr_c[1]), .Q(gpdi_dp[3]), .SCLK(clk_tmds), .RST(1'b0));
    ODDRX1F ddr_red  (.D0(sr_r[0]), .D1(sr_r[1]), .Q(gpdi_dp[2]), .SCLK(clk_tmds), .RST(1'b0));
    ODDRX1F ddr_green(.D0(sr_g[0]), .D1(sr_g[1]), .Q(gpdi_dp[1]), .SCLK(clk_tmds), .RST(1'b0));
    ODDRX1F ddr_blue (.D0(sr_b[0]), .D1(sr_b[1]), .Q(gpdi_dp[0]), .SCLK(clk_tmds), .RST(1'b0));

endmodule

//==========================================================================
// Minimal TMDS encoder (DVI 1.0 spec, page 29)
//==========================================================================
module tmds_enc(
    input clk,
    input DE,
    input [7:0] D,
    input C1, C0,
    output reg [9:0] q_out = 0
);

function [3:0] popcount;
    input [7:0] d;
    integer i;
    begin
        popcount = 0;
        for (i = 0; i < 8; i = i + 1) popcount = popcount + d[i];
    end
endfunction

reg signed [7:0] cnt = 0;
reg [8:0] q_m;

always @(*) begin
    if (popcount(D) > 4 || (popcount(D) == 4 && D[0] == 0)) begin
        q_m[0] = D[0];
        q_m[1] = q_m[0] ~^ D[1]; q_m[2] = q_m[1] ~^ D[2];
        q_m[3] = q_m[2] ~^ D[3]; q_m[4] = q_m[3] ~^ D[4];
        q_m[5] = q_m[4] ~^ D[5]; q_m[6] = q_m[5] ~^ D[6];
        q_m[7] = q_m[6] ~^ D[7]; q_m[8] = 1'b0;
    end else begin
        q_m[0] = D[0];
        q_m[1] = q_m[0] ^ D[1]; q_m[2] = q_m[1] ^ D[2];
        q_m[3] = q_m[2] ^ D[3]; q_m[4] = q_m[3] ^ D[4];
        q_m[5] = q_m[4] ^ D[5]; q_m[6] = q_m[5] ^ D[6];
        q_m[7] = q_m[6] ^ D[7]; q_m[8] = 1'b1;
    end
end

wire [3:0] n1 = popcount(q_m[7:0]);
wire [3:0] n0 = 8 - n1;

always @(posedge clk) begin
    if (DE) begin
        if (cnt == 0 || n1 == n0) begin
            q_out[9]   <= ~q_m[8];
            q_out[8]   <=  q_m[8];
            q_out[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];
            cnt <= q_m[8] ? cnt + (n1 - n0) : cnt + (n0 - n1);
        end else if ((cnt > 0 && n1 > n0) || (cnt < 0 && n0 > n1)) begin
            q_out <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt <= cnt + {q_m[8], 1'b0} + (n0 - n1);
        end else begin
            q_out <= {1'b0, q_m[8], q_m[7:0]};
            cnt <= cnt - {~q_m[8], 1'b0} + (n1 - n0);
        end
    end else begin
        cnt <= 0;
        case ({C1, C0})
            2'b00: q_out <= 10'b1101010100;
            2'b01: q_out <= 10'b0010101011;
            2'b10: q_out <= 10'b0101010100;
            2'b11: q_out <= 10'b1010101011;
        endcase
    end
end
endmodule
