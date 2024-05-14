// femtorv32, a minimalistic RISC-V RV32I core
//       Bruno Levy, 2020-2021
//
// This file: driver for LEDs (does nearly nothing !)
//

module SevenSegment 
(
    input wire 	       clk, // system clock
    input wire 	       wstrb, // write strobe
    input wire 	       sel, // select (read/write ignored if low)
    input wire [31:0]  wdata, // data to be written
    output wire [6:0]  segments, // LED pins
    output wire        seg_select
);

  // Function to convert 4-bit binary to 7-segment code
  function [6:0] bin_to_7seg;
    input [3:0] binary;
    begin
      case(binary)
        4'h0: bin_to_7seg = 7'b0111111;
        4'h1: bin_to_7seg = 7'b0000110;
        4'h2: bin_to_7seg = 7'b1011011;
        4'h3: bin_to_7seg = 7'b1001111;
        4'h4: bin_to_7seg = 7'b1100110;
        4'h5: bin_to_7seg = 7'b1101101;
        4'h6: bin_to_7seg = 7'b1111101;
        4'h7: bin_to_7seg = 7'b0000111;
        4'h8: bin_to_7seg = 7'b1111111;
        4'h9: bin_to_7seg = 7'b1101111;
        4'hA: bin_to_7seg = 7'b1110111;
        4'hB: bin_to_7seg = 7'b1111100;
        4'hC: bin_to_7seg = 7'b0111001;
        4'hD: bin_to_7seg = 7'b1011110;
        4'hE: bin_to_7seg = 7'b1111001;
        4'hF: bin_to_7seg = 7'b1110001;
        default: bin_to_7seg = 7'b0000000;  // Turn off all segments if input is invalid
      endcase
    end
  endfunction

  reg [7:0]  display_reg = 8'b00000000;
  reg [6:0]  segments_state = 7'b0000000;
  reg        seg_select_state = 0;
  reg [23:0] counter = 0;

  assign segments = ~segments_state;
  assign seg_select = seg_select_state;
  
  always @(posedge clk) begin
    if(sel && wstrb) begin
       display_reg <= wdata[7:0];	 
`ifdef BENCH
       $display("****************** Segment = %b", wdata[7:0]);
`endif	 
    end
  end

  parameter PAGE_CYCLES = `NRV_FREQ * 1000000 / 2 / 1000;

  always @(posedge clk) begin
    if (counter == PAGE_CYCLES) begin
      counter <= 0;
    end else begin
      counter <= counter + 1;
    end
  end

  always @(posedge clk) begin
    if (counter == PAGE_CYCLES) begin
      seg_select_state <= ~seg_select_state;
      if (seg_select_state == 0) begin
        segments_state <= bin_to_7seg(display_reg[3:0]);
      end else begin
        segments_state <= bin_to_7seg(display_reg[7:4]);
      end
    end
  end
endmodule
