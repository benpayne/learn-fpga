// FM Synthesis Core
// 2-operator FM: one modulator feeding one carrier
// Generates 16-bit signed PCM at the configured sample rate
module fm_synth #(
    parameter CLK_FREQ    = 25_000_000,
    parameter SAMPLE_RATE = 48_000
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        gate,            // Note on/off
    input  wire [31:0] phase_inc,       // Carrier frequency (phase increment)
    input  wire [15:0] mod_ratio,       // Modulator:carrier freq ratio (8.8 fixed-point)
    input  wire [15:0] mod_depth,       // FM modulation depth
    // Carrier ADSR
    input  wire [23:0] car_attack,
    input  wire [23:0] car_decay,
    input  wire [23:0] car_sustain,
    input  wire [23:0] car_release,
    // Modulator ADSR
    input  wire [23:0] mod_attack,
    input  wire [23:0] mod_decay,
    input  wire [23:0] mod_sustain,
    input  wire [23:0] mod_release,
    // Output
    output wire signed [15:0] pcm_out,
    output wire        sample_valid
);

    // ---- Sample rate generator ----
    localparam SAMPLE_DIV = CLK_FREQ / SAMPLE_RATE;
    reg [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    reg sample_tick;

    always @(posedge clk) begin
        if (reset) begin
            sample_cnt  <= 0;
            sample_tick <= 1'b0;
        end else if (sample_cnt >= SAMPLE_DIV - 1) begin
            sample_cnt  <= 0;
            sample_tick <= 1'b1;
        end else begin
            sample_cnt  <= sample_cnt + 1;
            sample_tick <= 1'b0;
        end
    end

    assign sample_valid = sample_tick;

    // ---- Note-on edge detection (reset phase on new note) ----
    reg gate_prev;
    wire new_note = gate && !gate_prev;

    always @(posedge clk) begin
        if (reset)
            gate_prev <= 1'b0;
        else if (sample_tick)
            gate_prev <= gate;
    end

    // ---- Modulator frequency ----
    // mod_ratio is 8.8 fixed-point: multiply carrier inc and shift right 8
    wire [47:0] mod_inc_full = phase_inc * mod_ratio;
    wire [31:0] mod_phase_inc = mod_inc_full[39:8];

    // ---- Modulator operator ----
    wire signed [15:0] mod_sample;
    fm_operator mod_op (
        .clk(clk),
        .reset(reset),
        .phase_reset(new_note),
        .sample_tick(sample_tick),
        .phase_inc(mod_phase_inc),
        .phase_mod(32'sd0),
        .sample_out(mod_sample)
    );

    // ---- Modulator envelope ----
    wire [15:0] mod_env_level;
    fm_envelope mod_env (
        .clk(clk),
        .reset(reset),
        .sample_tick(sample_tick),
        .gate(gate),
        .attack_rate(mod_attack),
        .decay_rate(mod_decay),
        .sustain_level(mod_sustain),
        .release_rate(mod_release),
        .level_out(mod_env_level)
    );

    // ---- Apply modulator envelope and depth ----
    // mod_sample (-32767..32767) * mod_env_level (0..65535) => signed 32-bit
    // Shift right 16 to normalize back to ~(-32767..32767)
    wire signed [31:0] mod_env_product = mod_sample * $signed({1'b0, mod_env_level});
    wire signed [15:0] mod_with_env = mod_env_product >>> 16;

    // Scale by mod_depth to get phase modulation offset (signed 32-bit)
    // This value is added directly to the carrier's phase accumulator input
    wire signed [31:0] phase_mod_val = mod_with_env * $signed({1'b0, mod_depth});

    // ---- Carrier operator ----
    wire signed [15:0] car_sample;
    fm_operator car_op (
        .clk(clk),
        .reset(reset),
        .phase_reset(new_note),
        .sample_tick(sample_tick),
        .phase_inc(phase_inc),
        .phase_mod(phase_mod_val),
        .sample_out(car_sample)
    );

    // ---- Carrier envelope ----
    wire [15:0] car_env_level;
    fm_envelope car_env (
        .clk(clk),
        .reset(reset),
        .sample_tick(sample_tick),
        .gate(gate),
        .attack_rate(car_attack),
        .decay_rate(car_decay),
        .sustain_level(car_sustain),
        .release_rate(car_release),
        .level_out(car_env_level)
    );

    // ---- Apply carrier envelope for final output ----
    wire signed [31:0] car_env_product = car_sample * $signed({1'b0, car_env_level});
    wire signed [15:0] final_sample = car_env_product >>> 16;

    assign pcm_out = final_sample;

endmodule
