// Interrput Controller for FemtoRV, 
//  InterruptController.v
//
// Ben Payne, 2024

module InterruptController(
    input wire 	       rst, // reset
    input wire 	       clk, // system clock
    input wire 	       wstrb, // write strobe
    input wire 	       rstrb, // read strobe
    input wire 	       sel, // select (read/write ignored if low)
    input wire  [31:0] wdata, // data to be written
    output wire [31:0] rdata, // data to be read
    input wire [31:0]  interrupts, // interupt triggers from devices
    output reg         interrupt_request // interrupt output to CPU, high when any interrupt is active
);

    reg [31:0] interrupt_status; // Registered interrupt status
    reg [31:0] device_interrupts_d; // Delayed version of device_interrupts
    reg [31:0] int_latched;         // Latch for device interrupt edges

    // read data handler
    assign rdata = (sel && rstrb ? interrupt_status : 32'b0);

    // Edge detection for device interrupts
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            device_interrupts_d <= 32'b0;
            int_latched <= 32'b0;
        end else begin
            device_interrupts_d <= interrupts;
            int_latched <= (interrupts & ~device_interrupts_d);
        end
    end

    // Trigger interrupt request when any interrupt changes
    always @(posedge clk) begin
        if ( |int_latched ) begin
            interrupt_request <= 1;
        end else begin
            interrupt_request <= 0;
        end
    end

    // Update interrupt status register when interrupts are triggered and when they are cleared
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            interrupt_status <= 32'b0;
        end else begin
            // Capture triggered interrupts, set corresponding bits in interrupt_status
            if ( sel && wstrb ) begin
                interrupt_status <= (interrupt_status & ~wdata) | int_latched;
            end else begin
                interrupt_status <= interrupt_status | int_latched;
            end
        end
    end
endmodule
