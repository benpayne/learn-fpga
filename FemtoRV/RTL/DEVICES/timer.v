// Timer for FemtoRV, not implimenting the official RISC-V timer spec
//  timer.v
//
// Ben Payne, 2024

module ClockTimer(
    input wire 	       clk, // system clock
    input wire 	       wstrb, // write strobe
    input wire 	       rstrb, // read strobe
    input wire 	       sel, // select (read/write ignored if low)
    input wire [31:0]  wdata, // data to be written
    output wire [31:0] rdata, // data to be read
    output wire        complete, // timer has expired
    output wire        running // timer has expired
);

  reg [31:0]  timer_reg = 32'b0;
  reg [31:0]  counter = 32'b0;
  reg        complete_reg = 0;
  reg        running_reg = 0;

  assign complete = complete_reg;
  assign rdata = (sel && rstrb ? counter : 32'b0);
  assign running = running_reg;

  initial begin
    timer_reg = 32'b0;
    counter = 32'b0;
    complete_reg = 0;
    running_reg = 0;
  end

  always @(posedge clk) begin
    if (sel && wstrb) begin
        timer_reg <= wdata[31:0];
        counter <= 0;
        running_reg <= 1;
        complete_reg <= 0;
`ifdef BENCH
        $display("****************** Timer Value = %b", wdata[31:0]);
`endif	 
    end else if (running_reg) begin
        if (counter == timer_reg) begin
            counter <= 0;
            complete_reg <= 1;
            running_reg <= 0;
        end else begin
            counter <= counter + 1;
            complete_reg <= 0;
        end
    end else begin
        counter <= 0;
        complete_reg <= 0;
    end
  end
endmodule
