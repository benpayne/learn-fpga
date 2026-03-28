// ADSR Envelope Generator for FM Synthesis
// 24-bit internal level, 16-bit output (top bits)
module fm_envelope (
    input  wire        clk,
    input  wire        reset,
    input  wire        sample_tick,
    input  wire        gate,            // 1 = note on, 0 = note off
    input  wire [23:0] attack_rate,     // Added per sample during attack
    input  wire [23:0] decay_rate,      // Subtracted per sample during decay
    input  wire [23:0] sustain_level,   // Hold level during sustain
    input  wire [23:0] release_rate,    // Subtracted per sample during release
    output wire [15:0] level_out        // Unsigned envelope level (0..65535)
);

    localparam S_IDLE    = 3'd0;
    localparam S_ATTACK  = 3'd1;
    localparam S_DECAY   = 3'd2;
    localparam S_SUSTAIN = 3'd3;
    localparam S_RELEASE = 3'd4;

    reg [2:0]  state;
    reg [23:0] level;
    reg        gate_prev;

    assign level_out = level[23:8];

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            level     <= 24'd0;
            gate_prev <= 1'b0;
        end else if (sample_tick) begin
            gate_prev <= gate;

            // Gate transitions take priority
            if (gate && !gate_prev) begin
                state <= S_ATTACK;
            end else if (!gate && gate_prev && state != S_IDLE) begin
                state <= S_RELEASE;
            end else begin
                // Envelope progression
                case (state)
                    S_IDLE: begin
                        level <= 24'd0;
                    end
                    S_ATTACK: begin
                        if ({1'b0, level} + {1'b0, attack_rate} >= 25'h1000000) begin
                            level <= 24'hFFFFFF;
                            state <= S_DECAY;
                        end else begin
                            level <= level + attack_rate;
                        end
                    end
                    S_DECAY: begin
                        if (level <= sustain_level + decay_rate) begin
                            level <= sustain_level;
                            state <= S_SUSTAIN;
                        end else begin
                            level <= level - decay_rate;
                        end
                    end
                    S_SUSTAIN: begin
                        level <= sustain_level;
                    end
                    S_RELEASE: begin
                        if (level <= release_rate) begin
                            level <= 24'd0;
                            state <= S_IDLE;
                        end else begin
                            level <= level - release_rate;
                        end
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
