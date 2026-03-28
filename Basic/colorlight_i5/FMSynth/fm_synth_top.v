// FM Synth Top-Level for Colorlight i5 + carrier board
// 4 external buttons on P2 header play C major: C4, E4, G4, C5
// PWM audio output on P2 header pin
// On-module LED indicates note active
//
// Default button wiring (active high, accent to 3.3V with pull-down):
//   P2_3  (K18) = button 0 -> C4
//   P2_4  (T18) = button 1 -> E4
//   P2_5  (R17) = button 2 -> G4
//   P2_6  (M17) = button 3 -> C5
//
// Audio output:
//   P2_7  (U18) = PWM audio -> connect to speaker/amp via series resistor
//
// Adjust pin assignments in colorlight_i5.lpf to match your wiring.

module fm_synth_top (
    input  wire       clk_i,      // 25 MHz system clock
    input  wire [3:0] btn,        // 4 external buttons (active high)
    output wire       led_o,      // On-module LED (active low on i5)
    output wire       audio_out   // PWM audio on GPIO
);

    // ---- Phase increments for C major (48kHz sample rate, 32-bit phase) ----
    // freq * 2^32 / 48000
    localparam [31:0] PHASE_C4 = 32'h016534C3;  // C4  261.63 Hz
    localparam [31:0] PHASE_E4 = 32'h01C20D2F;  // E4  329.63 Hz
    localparam [31:0] PHASE_G4 = 32'h02173456;  // G4  392.00 Hz
    localparam [31:0] PHASE_C5 = 32'h02CA6987;  // C5  523.25 Hz

    // ---- FM synthesis parameters ----
    localparam [15:0] MOD_RATIO = 16'h0200;       // 2.0x carrier freq (8.8 fixed-point)
    localparam [15:0] MOD_DEPTH = 16'd2048;        // Moderate FM depth

    // Carrier ADSR: fast attack, medium decay, high sustain, medium release
    localparam [23:0] CAR_ATTACK  = 24'd69905;     // ~5ms
    localparam [23:0] CAR_DECAY   = 24'd1748;      // ~200ms
    localparam [23:0] CAR_SUSTAIN = 24'd13421773;   // ~80%
    localparam [23:0] CAR_RELEASE = 24'd3495;       // ~100ms

    // Modulator ADSR: fast attack, slow decay (timbre evolves), lower sustain
    localparam [23:0] MOD_ATTACK  = 24'd69905;     // ~5ms
    localparam [23:0] MOD_DECAY   = 24'd699;       // ~500ms
    localparam [23:0] MOD_SUSTAIN = 24'd6710886;    // ~40%
    localparam [23:0] MOD_RELEASE = 24'd3495;       // ~100ms

    // ---- Button debouncing ----
    reg [3:0] btn_sync1, btn_sync2;     // Double-flop synchronizer
    reg [3:0] btn_stable;
    reg [19:0] debounce_cnt;            // ~21ms at 25MHz

    always @(posedge clk_i) begin
        btn_sync1 <= btn;
        btn_sync2 <= btn_sync1;

        if (btn_sync2 != btn_stable) begin
            debounce_cnt <= debounce_cnt + 1;
            if (debounce_cnt[19]) begin
                btn_stable   <= btn_sync2;
                debounce_cnt <= 20'd0;
            end
        end else begin
            debounce_cnt <= 20'd0;
        end
    end

    // ---- Note selection (priority encoded, one note at a time) ----
    wire gate = |btn_stable;

    reg [31:0] phase_inc;
    always @(*) begin
        if (btn_stable[0])      phase_inc = PHASE_C4;
        else if (btn_stable[1]) phase_inc = PHASE_E4;
        else if (btn_stable[2]) phase_inc = PHASE_G4;
        else if (btn_stable[3]) phase_inc = PHASE_C5;
        else                    phase_inc = 32'd0;
    end

    // ---- LED indicator (active low on Colorlight i5) ----
    assign led_o = ~gate;

    // ---- FM Synth core ----
    wire signed [15:0] pcm_out;
    wire sample_valid;

    fm_synth #(
        .CLK_FREQ(25_000_000),
        .SAMPLE_RATE(48_000)
    ) synth (
        .clk(clk_i),
        .reset(1'b0),
        .gate(gate),
        .phase_inc(phase_inc),
        .mod_ratio(MOD_RATIO),
        .mod_depth(MOD_DEPTH),
        .car_attack(CAR_ATTACK),
        .car_decay(CAR_DECAY),
        .car_sustain(CAR_SUSTAIN),
        .car_release(CAR_RELEASE),
        .mod_attack(MOD_ATTACK),
        .mod_decay(MOD_DECAY),
        .mod_sustain(MOD_SUSTAIN),
        .mod_release(MOD_RELEASE),
        .pcm_out(pcm_out),
        .sample_valid(sample_valid)
    );

    // ---- PWM DAC ----
    // Convert signed 16-bit PCM to unsigned 8-bit for PWM
    wire [15:0] pcm_unsigned = pcm_out + 16'h8000;
    wire [7:0]  pwm_level = pcm_unsigned[15:8];

    // Free-running 8-bit counter at 25MHz -> PWM freq ~97.6 kHz
    reg [7:0] pwm_counter;
    always @(posedge clk_i)
        pwm_counter <= pwm_counter + 1;

    assign audio_out = (pwm_level > pwm_counter);

endmodule
