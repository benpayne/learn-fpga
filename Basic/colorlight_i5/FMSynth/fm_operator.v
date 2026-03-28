// FM Synthesis Operator
// Phase accumulator with quarter-wave sine table lookup
module fm_operator (
    input  wire        clk,
    input  wire        reset,
    input  wire        phase_reset,     // Reset phase (on new note)
    input  wire        sample_tick,     // Pulse at sample rate
    input  wire [31:0] phase_inc,       // Phase increment (sets frequency)
    input  wire signed [31:0] phase_mod,// Phase modulation input
    output reg  signed [15:0] sample_out
);

    // 32-bit phase accumulator
    reg [31:0] phase_acc;

    // Quarter-wave sine table (256 entries, unsigned 0..32767)
    reg [15:0] sine_table [0:255];
    initial $readmemh("sine_table.hex", sine_table);

    // Compute effective phase with modulation
    wire [31:0] eff_phase = phase_acc + $unsigned(phase_mod);

    // Top 10 bits select the sine value
    //   [31]   = sign (negate output for quadrants 2-3)
    //   [30]   = mirror (reverse index for quadrants 1,3)
    //   [29:22] = 8-bit table index
    wire        q_sign   = eff_phase[31];
    wire        q_mirror = eff_phase[30];
    wire [7:0]  tbl_idx  = q_mirror ? ~eff_phase[29:22] : eff_phase[29:22];

    // Combinational sine lookup and sign correction
    wire [15:0] tbl_val = sine_table[tbl_idx];
    wire signed [15:0] pos_val = {1'b0, tbl_val[14:0]};
    wire signed [15:0] sine_val = q_sign ? -pos_val : pos_val;

    always @(posedge clk) begin
        if (reset) begin
            phase_acc  <= 32'd0;
            sample_out <= 16'sd0;
        end else if (phase_reset) begin
            phase_acc  <= 32'd0;
        end else if (sample_tick) begin
            phase_acc  <= phase_acc + phase_inc;
            sample_out <= sine_val;
        end
    end

endmodule
