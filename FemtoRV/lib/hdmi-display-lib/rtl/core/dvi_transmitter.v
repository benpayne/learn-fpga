/*
DVI Transmitter for retrocpu Character Display GPU

Based on my_hdmi_device by Hirosh Dabui <hirosh@dabui.de>
Adapted for retrocpu project 2025-12-28
Validated on Colorlight i5 v7.0

This module:
1. Instantiates three TMDS encoders (Red, Green, Blue channels)
2. Serializes 10-bit TMDS data to differential TMDS output pins
3. Uses DDR (Double Data Rate) output primitives for ECP5 FPGA
4. Supports 640x480@60Hz with 25 MHz pixel clock, 125 MHz TMDS clock

License: ISC (same as original my_hdmi_device)
*/

module dvi_transmitter(
    input pclk,             // Pixel clock (25 MHz for 640x480@60Hz)
    input tmds_clk,         // TMDS clock (125 MHz, 5x pixel clock for DDR)

    input [7:0] in_red,     // 8-bit red pixel data
    input [7:0] in_green,   // 8-bit green pixel data
    input [7:0] in_blue,    // 8-bit blue pixel data

    input in_blank,         // Blanking signal (1=blanking, 0=active video)
    input in_vsync,         // Vertical sync
    input in_hsync,         // Horizontal sync

    output [1:0] out_tmds_red,    // TMDS red output (DDR, 2 bits)
    output [1:0] out_tmds_green,  // TMDS green output (DDR, 2 bits)
    output [1:0] out_tmds_blue,   // TMDS blue output (DDR, 2 bits)
    output [1:0] out_tmds_clk     // TMDS clock output (DDR, 2 bits)
);

//=============================================================================
// TMDS Encoders (3 channels: Red, Green, Blue)
//=============================================================================

wire [9:0] tmds_red;
wire [9:0] tmds_green;
wire [9:0] tmds_blue;

// Red channel: data only (no control signals)
tmds_encoder tmds_encoder_red(
    .clk(pclk),
    .DE(~in_blank),
    .D(in_red),
    .C1(1'b0),
    .C0(1'b0),
    .q_out(tmds_red)
);

// Green channel: data only (no control signals)
tmds_encoder tmds_encoder_green(
    .clk(pclk),
    .DE(~in_blank),
    .D(in_green),
    .C1(1'b0),
    .C0(1'b0),
    .q_out(tmds_green)
);

// Blue channel: includes HSYNC and VSYNC during blanking
tmds_encoder tmds_encoder_blue(
    .clk(pclk),
    .DE(~in_blank),
    .D(in_blue),
    .C1(in_vsync),
    .C0(in_hsync),
    .q_out(tmds_blue)
);

//=============================================================================
// 10:1 Serialization with DDR Output (5 shifts of 2 bits each)
//=============================================================================

// Serialization control
reg       tmds_shift_load   = 0;
reg [3:0] tmds_modulo       = 0;
reg [9:0] tmds_shift_red    = 0;
reg [9:0] tmds_shift_green  = 0;
reg [9:0] tmds_shift_blue   = 0;
reg [9:0] tmds_shift_clk    = 0;

// TMDS clock pattern: 5 transitions (0b00000_11111)
localparam [9:0] tmds_pixel_clk = 10'b00000_11111;

// Shift counter: 0-4 for DDR (5 shifts of 2 bits = 10 bits total)
wire max_shifts_reached = (tmds_modulo == 4);

always @(posedge tmds_clk) begin
    tmds_modulo      <= max_shifts_reached ? 0 : tmds_modulo + 1;
    tmds_shift_load  <= max_shifts_reached;
end

// Shift registers: load new 10-bit data or shift out 2 bits
always @(posedge tmds_clk) begin
    if (tmds_shift_load) begin
        // Load new 10-bit data from TMDS encoders
        tmds_shift_red   <= tmds_red;
        tmds_shift_green <= tmds_green;
        tmds_shift_blue  <= tmds_blue;
        tmds_shift_clk   <= tmds_pixel_clk;
    end else begin
        // Shift out 2 bits (DDR mode)
        tmds_shift_red   <= {2'b00, tmds_shift_red  [9:2]};
        tmds_shift_green <= {2'b00, tmds_shift_green[9:2]};
        tmds_shift_blue  <= {2'b00, tmds_shift_blue [9:2]};
        tmds_shift_clk   <= {2'b00, tmds_shift_clk  [9:2]};
    end
end

// Output the lower 2 bits (for DDR output)
assign out_tmds_clk   = tmds_shift_clk   [1:0];
assign out_tmds_red   = tmds_shift_red   [1:0];
assign out_tmds_green = tmds_shift_green [1:0];
assign out_tmds_blue  = tmds_shift_blue  [1:0];

endmodule
