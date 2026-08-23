// ----------------------------------------------------------------------------
// chips_7400.v — Behavioral models of 7400-series logic chips
// Pin-naming follows the common LS/HC data sheets so these models can be
// used as structural primitives when composing real 74-logic designs.
// ----------------------------------------------------------------------------
`default_nettype none

// 74LS00 — Quad 2-input NAND
module SN74LS00 (
    input  wire [3:0] A,
    input  wire [3:0] B,
    output wire [3:0] Y
);
    assign Y = ~(A & B);
endmodule

// 74LS04 — Hex inverter
module SN74LS04 (
    input  wire [5:0] A,
    output wire [5:0] Y
);
    assign Y = ~A;
endmodule

// 74LS08 — Quad 2-input AND
module SN74LS08 (
    input  wire [3:0] A,
    input  wire [3:0] B,
    output wire [3:0] Y
);
    assign Y = A & B;
endmodule

// 74LS32 — Quad 2-input OR
module SN74LS32 (
    input  wire [3:0] A,
    input  wire [3:0] B,
    output wire [3:0] Y
);
    assign Y = A | B;
endmodule

// 74LS74 — Dual D flip-flop with async preset and clear (active-low)
module SN74LS74 (
    // Channel 1
    input  wire CLK1,
    input  wire D1,
    input  wire PRE1_n,
    input  wire CLR1_n,
    output wire Q1,
    output wire Q1_n,
    // Channel 2
    input  wire CLK2,
    input  wire D2,
    input  wire PRE2_n,
    input  wire CLR2_n,
    output wire Q2,
    output wire Q2_n
);
    reg q1, q2;

    always @(posedge CLK1 or negedge PRE1_n or negedge CLR1_n) begin
        if (!CLR1_n)      q1 <= 1'b0;
        else if (!PRE1_n) q1 <= 1'b1;
        else              q1 <= D1;
    end

    always @(posedge CLK2 or negedge PRE2_n or negedge CLR2_n) begin
        if (!CLR2_n)      q2 <= 1'b0;
        else if (!PRE2_n) q2 <= 1'b1;
        else              q2 <= D2;
    end

    assign Q1   = q1;
    assign Q1_n = ~q1;
    assign Q2   = q2;
    assign Q2_n = ~q2;
endmodule

// 74LS244 — Octal non-inverting buffer with tristate outputs
// Two independent 4-bit banks; OE is active-low per bank.
module SN74LS244 (
    input  wire       OE1_n,
    input  wire [3:0] A1,
    output wire [3:0] Y1,
    input  wire       OE2_n,
    input  wire [3:0] A2,
    output wire [3:0] Y2
);
    assign Y1 = OE1_n ? 4'bzzzz : A1;
    assign Y2 = OE2_n ? 4'bzzzz : A2;
endmodule

// 74LS245 — Octal bidirectional transceiver with tristate outputs
// DIR=1: A → B.  DIR=0: B → A.  OE_n=1: both sides tristate.
module SN74LS245 (
    input  wire       DIR,
    input  wire       OE_n,
    inout  wire [7:0] A,
    inout  wire [7:0] B
);
    assign A = (!OE_n &&  !DIR) ? B : 8'bzzzzzzzz;
    assign B = (!OE_n &&   DIR) ? A : 8'bzzzzzzzz;
endmodule

// 74LS373 — Octal transparent latch (LE high = transparent, falling edge = hold)
module SN74LS373 (
    input  wire       LE,
    input  wire       OE_n,
    input  wire [7:0] D,
    output wire [7:0] Q
);
    reg [7:0] q;
    always @(*) if (LE) q = D;
    assign Q = OE_n ? 8'bzzzzzzzz : q;
endmodule

`default_nettype wire
