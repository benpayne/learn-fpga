// TDM FM Synthesizer Engine
// 4 voices x 4 operators = 16 operator slots
// Single shared multiplier, 48kHz sample rate

module fm_synth_tdm #(
    parameter CLK_FREQ    = 25_000_000,
    parameter SAMPLE_RATE = 48_000
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [3:0]  voice_gate,
    input  wire [31:0] voice_phase_inc_0,
    input  wire [31:0] voice_phase_inc_1,
    input  wire [31:0] voice_phase_inc_2,
    input  wire [31:0] voice_phase_inc_3,
    input  wire [2:0]  voice_algorithm,     // Same algorithm for all voices

    // Per-voice pitch envelope (for drums: pitch sweeps down on note-on)
    input  wire [31:0] voice_pitch_start_0, // Starting pitch (high freq, decays to phase_inc)
    input  wire [31:0] voice_pitch_start_1,
    input  wire [31:0] voice_pitch_start_2,
    input  wire [31:0] voice_pitch_start_3,
    input  wire [15:0] voice_pitch_decay_0, // Decay rate (subtracted per sample, 16-bit fraction of range)
    input  wire [15:0] voice_pitch_decay_1,
    input  wire [15:0] voice_pitch_decay_2,
    input  wire [15:0] voice_pitch_decay_3,
    input  wire [7:0]  voice_noise_mix_0,  // Noise mix: 0=pure FM, 255=pure noise
    input  wire [7:0]  voice_noise_mix_1,
    input  wire [7:0]  voice_noise_mix_2,
    input  wire [7:0]  voice_noise_mix_3,

    // Per-operator parameters (4 ops, shared across voices)
    input  wire [15:0] op_ratio_0, op_ratio_1, op_ratio_2, op_ratio_3,
    input  wire [15:0] op_depth_0, op_depth_1, op_depth_2, op_depth_3,
    input  wire [23:0] op_attack_0, op_attack_1, op_attack_2, op_attack_3,
    input  wire [23:0] op_decay_0, op_decay_1, op_decay_2, op_decay_3,
    input  wire [23:0] op_sustain_0, op_sustain_1, op_sustain_2, op_sustain_3,
    input  wire [23:0] op_release_0, op_release_1, op_release_2, op_release_3,

    output reg signed [15:0] pcm_out,
    output reg         sample_valid
);

    // ---- Mux helpers: select param by op_id (0..3) ----
    reg [31:0] cur_phase_inc;
    reg [15:0] cur_ratio, cur_depth;
    reg [23:0] cur_attack, cur_decay, cur_sustain, cur_release;

    wire [1:0] voice_id = op_idx[3:2];       // op_idx bits [3:2] select voice
    wire [1:0] op_id    = 2'd3 - op_idx[1:0]; // Process OP4 first (3,2,1,0)

    always @(*) begin
        case (voice_id)
            2'd0: cur_phase_inc = voice_phase_inc_0;
            2'd1: cur_phase_inc = voice_phase_inc_1;
            2'd2: cur_phase_inc = voice_phase_inc_2;
            2'd3: cur_phase_inc = voice_phase_inc_3;
        endcase
        case (op_id)
            2'd0: begin cur_ratio=op_ratio_0; cur_depth=op_depth_0;
                        cur_attack=op_attack_0; cur_decay=op_decay_0;
                        cur_sustain=op_sustain_0; cur_release=op_release_0; end
            2'd1: begin cur_ratio=op_ratio_1; cur_depth=op_depth_1;
                        cur_attack=op_attack_1; cur_decay=op_decay_1;
                        cur_sustain=op_sustain_1; cur_release=op_release_1; end
            2'd2: begin cur_ratio=op_ratio_2; cur_depth=op_depth_2;
                        cur_attack=op_attack_2; cur_decay=op_decay_2;
                        cur_sustain=op_sustain_2; cur_release=op_release_2; end
            2'd3: begin cur_ratio=op_ratio_3; cur_depth=op_depth_3;
                        cur_attack=op_attack_3; cur_decay=op_decay_3;
                        cur_sustain=op_sustain_3; cur_release=op_release_3; end
        endcase
    end

    // ---- Pitch envelope mux ----
    reg [31:0] cur_pitch_start;
    reg [15:0] cur_pitch_decay;
    always @(*) begin
        case (voice_id)
            2'd0: begin cur_pitch_start = voice_pitch_start_0; cur_pitch_decay = voice_pitch_decay_0; end
            2'd1: begin cur_pitch_start = voice_pitch_start_1; cur_pitch_decay = voice_pitch_decay_1; end
            2'd2: begin cur_pitch_start = voice_pitch_start_2; cur_pitch_decay = voice_pitch_decay_2; end
            2'd3: begin cur_pitch_start = voice_pitch_start_3; cur_pitch_decay = voice_pitch_decay_3; end
        endcase
    end

    // ---- Sample rate tick ----
    localparam SAMPLE_DIV = CLK_FREQ / SAMPLE_RATE;
    reg [9:0] master_cnt;
    wire sample_tick = (master_cnt == 0);

    // ---- Slot timing ----
    reg [4:0] op_idx;   // 0..16 (needs 5 bits to hold value 16)
    reg [4:0] slot_cnt;
    wire processing = (op_idx < 5'd16) && !sample_tick;

    // ---- Per-voice pitch envelope state ----
    // pitch_env_level: 16-bit, starts at 65535 on note-on, decays to 0
    // Effective phase_inc = base + (pitch_start - base) * pitch_env_level / 65536
    reg [15:0] pitch_env_level [0:3];
    reg        pitch_gate_prev [0:3];

    // ---- Operator state ----
    reg [31:0] state_phase   [0:15];
    reg [23:0] state_env     [0:15];
    reg [2:0]  state_env_fsm [0:15];
    reg        state_gate_prev [0:15];

    // ---- Per-voice working registers ----
    reg signed [15:0] voice_op_out [0:3];
    reg signed [17:0] voice_carrier_sum [0:3];

    // ---- Noise generator (16-bit LFSR) ----
    reg [15:0] lfsr = 16'hACE1;  // Non-zero seed
    always @(posedge clk)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};
    // Scale noise down to ~50% to match sine amplitude
    wire signed [15:0] noise_val = {lfsr[15], lfsr[15], lfsr[14:1]};  // Signed, halved

    // Noise mix mux per voice
    reg [7:0] cur_noise_mix;
    always @(*) begin
        case (voice_id)
            2'd0: cur_noise_mix = voice_noise_mix_0;
            2'd1: cur_noise_mix = voice_noise_mix_1;
            2'd2: cur_noise_mix = voice_noise_mix_2;
            2'd3: cur_noise_mix = voice_noise_mix_3;
        endcase
    end

    // ---- Sine ROM ----
    reg  [7:0]  sine_addr;
    wire [15:0] sine_data;
    fm_sine_rom sine_rom_inst (.clk(clk), .addr(sine_addr), .data(sine_data));

    // ---- Algorithm routing ----
    wire signed [15:0] alg_mod_input;
    wire               alg_is_carrier;
    fm_algorithm alg_inst (
        .algorithm(voice_algorithm),
        .op_id(op_id),
        .op4_out(voice_op_out[3]),
        .op3_out(voice_op_out[2]),
        .op2_out(voice_op_out[1]),
        .mod_input(alg_mod_input),
        .is_carrier(alg_is_carrier)
    );

    // ---- Pipeline registers ----
    reg [31:0] pipe_phase_acc;
    reg [23:0] pipe_env_level;
    reg [2:0]  pipe_env_fsm;
    reg        pipe_gate_prev;
    reg        pipe_gate;
    reg [15:0] pipe_mod_depth;
    reg        pipe_is_carrier;
    reg [31:0] pipe_new_phase;
    reg        pipe_q_sign;
    reg signed [15:0] pipe_sine_val;
    reg [23:0] pipe_new_env;
    reg [2:0]  pipe_new_env_fsm;
    reg        pipe_new_gate_prev;
    reg signed [15:0] pipe_scaled_output;

    // ---- Shared multiplier ----
    reg signed [17:0] mul_a, mul_b;
    reg signed [35:0] mul_result;
    always @(posedge clk)
        mul_result <= mul_a * mul_b;

    // ---- Pitch envelope application ----
    // eff_phase_inc = base + (start - base) * env_level / 65536
    // When env_level=65535, eff = start. When env_level=0, eff = base.
    wire [31:0] pitch_range = cur_pitch_start - cur_phase_inc; // Can be 0 if no pitch env
    wire [47:0] pitch_offset = pitch_range * pitch_env_level[voice_id];
    wire [31:0] eff_phase_inc = cur_phase_inc + pitch_offset[47:16];

    // ---- Operator frequency ----
    wire [47:0] freq_product = eff_phase_inc * cur_ratio;
    wire [31:0] op_phase_inc = freq_product[39:8];

    // ---- ADSR constants ----
    localparam ENV_IDLE = 3'd0, ENV_ATTACK = 3'd1, ENV_DECAY = 3'd2;
    localparam ENV_SUSTAIN = 3'd3, ENV_RELEASE = 3'd4;

    // ---- Master counter ----
    always @(posedge clk) begin
        if (reset)
            master_cnt <= 0;
        else if (master_cnt >= SAMPLE_DIV - 1)
            master_cnt <= 0;
        else
            master_cnt <= master_cnt + 1;
    end

    // ---- Slot sequencer ----
    always @(posedge clk) begin
        if (reset || sample_tick) begin
            op_idx   <= 0;
            slot_cnt <= 0;
        end else if (op_idx < 5'd16) begin
            if (slot_cnt == 5'd31) begin
                slot_cnt <= 0;
                op_idx   <= op_idx + 1;
            end else
                slot_cnt <= slot_cnt + 1;
        end
    end

    // ---- Output mixing ----
    reg signed [19:0] mix_total;

    // ---- Pipeline execution ----
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 16; i = i + 1) begin
                state_phase[i] <= 0; state_env[i] <= 0;
                state_env_fsm[i] <= 0; state_gate_prev[i] <= 0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                voice_op_out[i] <= 0; voice_carrier_sum[i] <= 0;
                pitch_env_level[i] <= 0; pitch_gate_prev[i] <= 0;
            end
            pcm_out <= 0; sample_valid <= 0; pipe_sine_val <= 0;
        end else begin
            sample_valid <= 0;

            if (processing) begin
                case (slot_cnt)
                5'd0: begin  // Load state
                    pipe_phase_acc  <= state_phase[op_idx];
                    pipe_env_level  <= state_env[op_idx];
                    pipe_env_fsm    <= state_env_fsm[op_idx];
                    pipe_gate_prev  <= state_gate_prev[op_idx];
                    pipe_gate       <= voice_gate[voice_id];
                    pipe_mod_depth  <= cur_depth;
                    pipe_is_carrier <= alg_is_carrier;
                    if (op_id == 2'd3)
                        voice_carrier_sum[voice_id] <= 0;
                end

                5'd1: begin  // Pitch envelope update (once per voice, on first op)
                    if (op_id == 2'd3) begin
                        if (voice_gate[voice_id] && !pitch_gate_prev[voice_id]) begin
                            // Note-on: reset pitch envelope to max
                            pitch_env_level[voice_id] <= 16'hFFFF;
                        end else if (pitch_env_level[voice_id] > cur_pitch_decay) begin
                            pitch_env_level[voice_id] <= pitch_env_level[voice_id] - cur_pitch_decay;
                        end else begin
                            pitch_env_level[voice_id] <= 0;
                        end
                        pitch_gate_prev[voice_id] <= voice_gate[voice_id];
                    end
                end

                5'd3: pipe_new_phase <= pipe_phase_acc + op_phase_inc;

                5'd4: begin  // Phase modulation multiply
                    mul_a <= {alg_mod_input[15], alg_mod_input[15], alg_mod_input};
                    mul_b <= {2'b0, pipe_mod_depth};
                end

                5'd6: pipe_new_phase <= pipe_new_phase + mul_result[31:0];

                5'd7: begin  // Sine lookup
                    pipe_q_sign <= pipe_new_phase[31];
                    sine_addr <= pipe_new_phase[30] ?
                                 ~pipe_new_phase[29:22] : pipe_new_phase[29:22];
                end

                5'd9: begin  // Sine result + sign correction + noise mix
                    if (cur_noise_mix == 8'd0)
                        pipe_sine_val <= pipe_q_sign ?
                            -{1'b0, sine_data[14:0]} : {1'b0, sine_data[14:0]};
                    else if (cur_noise_mix == 8'd255)
                        pipe_sine_val <= noise_val;
                    else begin
                        // Blend sine and noise using multiplier in next slot
                        // For now, simple threshold: >128 = noise, <=128 = sine
                        pipe_sine_val <= (cur_noise_mix > 8'd128) ? noise_val :
                            (pipe_q_sign ? -{1'b0, sine_data[14:0]} : {1'b0, sine_data[14:0]});
                    end
                end

                5'd10: begin  // Envelope ADSR update
                    pipe_new_gate_prev <= pipe_gate;
                    if (pipe_gate && !pipe_gate_prev) begin
                        pipe_new_env_fsm <= ENV_ATTACK;
                        pipe_new_env <= pipe_env_level;
                    end else if (!pipe_gate && pipe_gate_prev && pipe_env_fsm != ENV_IDLE) begin
                        pipe_new_env_fsm <= ENV_RELEASE;
                        pipe_new_env <= pipe_env_level;
                    end else begin
                        case (pipe_env_fsm)
                            ENV_IDLE: begin pipe_new_env <= 0; pipe_new_env_fsm <= ENV_IDLE; end
                            ENV_ATTACK: begin
                                if ({1'b0, pipe_env_level} + {1'b0, cur_attack} >= 25'h1000000) begin
                                    pipe_new_env <= 24'hFFFFFF; pipe_new_env_fsm <= ENV_DECAY;
                                end else begin
                                    pipe_new_env <= pipe_env_level + cur_attack;
                                    pipe_new_env_fsm <= ENV_ATTACK;
                                end
                            end
                            ENV_DECAY: begin
                                if (pipe_env_level <= cur_sustain + cur_decay) begin
                                    pipe_new_env <= cur_sustain; pipe_new_env_fsm <= ENV_SUSTAIN;
                                end else begin
                                    pipe_new_env <= pipe_env_level - cur_decay;
                                    pipe_new_env_fsm <= ENV_DECAY;
                                end
                            end
                            ENV_SUSTAIN: begin
                                pipe_new_env <= cur_sustain; pipe_new_env_fsm <= ENV_SUSTAIN;
                            end
                            ENV_RELEASE: begin
                                if (pipe_env_level <= cur_release) begin
                                    pipe_new_env <= 0; pipe_new_env_fsm <= ENV_IDLE;
                                end else begin
                                    pipe_new_env <= pipe_env_level - cur_release;
                                    pipe_new_env_fsm <= ENV_RELEASE;
                                end
                            end
                            default: begin pipe_new_env_fsm <= ENV_IDLE; pipe_new_env <= 0; end
                        endcase
                    end
                end

                5'd13: begin  // Envelope multiply
                    mul_a <= {pipe_sine_val[15], pipe_sine_val[15], pipe_sine_val};
                    mul_b <= {2'b0, pipe_new_env[23:8]};
                end

                5'd15: pipe_scaled_output <= mul_result[31:16];

                5'd17: begin  // Store results
                    state_phase[op_idx]     <= pipe_new_phase;
                    state_env[op_idx]       <= pipe_new_env;
                    state_env_fsm[op_idx]   <= pipe_new_env_fsm;
                    state_gate_prev[op_idx] <= pipe_new_gate_prev;
                    voice_op_out[op_id]     <= pipe_scaled_output;
                    if (pipe_is_carrier)
                        voice_carrier_sum[voice_id] <=
                            voice_carrier_sum[voice_id] +
                            {{2{pipe_scaled_output[15]}}, pipe_scaled_output};
                end
                default: ;
                endcase
            end

            // ---- Final mix ----
            if (master_cnt == SAMPLE_DIV - 2) begin
                mix_total = {{2{voice_carrier_sum[0][17]}}, voice_carrier_sum[0]}
                          + {{2{voice_carrier_sum[1][17]}}, voice_carrier_sum[1]}
                          + {{2{voice_carrier_sum[2][17]}}, voice_carrier_sum[2]}
                          + {{2{voice_carrier_sum[3][17]}}, voice_carrier_sum[3]};
                // Shift right by 2 (divide by 4) for headroom with 4 voices
                if (mix_total[19:17] == 3'b000 || mix_total[19:17] == 3'b111)
                    pcm_out <= mix_total[17:2];
                else if (mix_total[19])
                    pcm_out <= -16'sd32768;
                else
                    pcm_out <= 16'sd32767;
                sample_valid <= 1;
            end
        end
    end

    initial begin
        master_cnt = 0;
        op_idx = 0;
        slot_cnt = 0;
        pcm_out = 0;
        sample_valid = 0;
        pipe_sine_val = 0;
        pipe_phase_acc = 0;
        pipe_env_level = 0;
        pipe_env_fsm = 0;
        pipe_gate_prev = 0;
        pipe_gate = 0;
        pipe_mod_depth = 0;
        pipe_is_carrier = 0;
        pipe_new_phase = 0;
        pipe_q_sign = 0;
        pipe_new_env = 0;
        pipe_new_env_fsm = 0;
        pipe_new_gate_prev = 0;
        pipe_scaled_output = 0;
        mul_a = 0;
        mul_b = 0;
        mix_total = 0;
        sine_addr = 0;
        for (i = 0; i < 16; i = i + 1) begin
            state_phase[i] = 0; state_env[i] = 0;
            state_env_fsm[i] = 0; state_gate_prev[i] = 0;
        end
        for (i = 0; i < 4; i = i + 1) begin
            voice_op_out[i] = 0; voice_carrier_sum[i] = 0;
            pitch_env_level[i] = 0; pitch_gate_prev[i] = 0;
        end
    end
endmodule
