// FM Synth Top-Level for Colorlight i5
// 4-voice polyphony, 4 operators per voice, 8 algorithms
// TDM architecture sharing one multiplier pipeline
//
// 4 note buttons: each button = one voice (polyphonic)
// 3 voice switches: select preset (algorithm + operator params)
// PWM + I2S audio output

module fm_synth_top (
    input  wire       clk_i,
    input  wire [3:0] btn,        // 4 note buttons (active-low)
    input  wire [2:0] sw,         // 3 voice switches (active-low)
    output wire       led_o,      // LED (active-low)
    output wire       audio_out,  // PWM audio
    output wire       i2s_bclk,
    output wire       i2s_lrck,
    output wire       i2s_din,
    output wire       i2s_sd,
    output wire       i2s_gain
);

    // ---- Phase increments (48kHz, 32-bit phase acc) ----
    localparam [31:0] PHASE_C4 = 32'h016534C3;  // 261.63 Hz
    localparam [31:0] PHASE_E4 = 32'h01C20D2F;  // 329.63 Hz
    localparam [31:0] PHASE_G4 = 32'h02173456;  // 392.00 Hz
    localparam [31:0] PHASE_C5 = 32'h02CA6987;  // 523.25 Hz

    // Drum frequencies
    localparam [31:0] PHASE_40HZ  = 32'h000D9999;  // Kick target
    localparam [31:0] PHASE_200HZ = 32'h004444FF;  // Kick start
    localparam [31:0] PHASE_150HZ = 32'h003333BF;  // Tom target
    localparam [31:0] PHASE_400HZ = 32'h008889FF;  // Tom start
    localparam [31:0] PHASE_300HZ = 32'h006666FF;  // Snare body
    localparam [31:0] PHASE_800HZ = 32'h011113FF;  // Snare start
    localparam [31:0] PHASE_8KHZ  = 32'h0AAAAAAA;  // Hi-hat

    // ---- Button debouncing ----
    reg [3:0] btn_sync1, btn_sync2, btn_stable;
    reg [19:0] debounce_cnt;

    always @(posedge clk_i) begin
        btn_sync1 <= btn;
        btn_sync2 <= btn_sync1;
        if (btn_sync2 != btn_stable) begin
            debounce_cnt <= debounce_cnt + 1;
            if (debounce_cnt[19]) begin
                btn_stable   <= btn_sync2;
                debounce_cnt <= 0;
            end
        end else
            debounce_cnt <= 0;
    end

    wire [3:0] btn_active = ~btn_stable;

    // ---- Switch synchronizer ----
    reg [2:0] sw_sync1, sw_sync2;
    always @(posedge clk_i) begin
        sw_sync1 <= sw;
        sw_sync2 <= sw_sync1;
    end
    wire [2:0] voice_sel = ~sw_sync2;

    // ---- Voice allocation: each button = one voice ----
    wire [3:0] voice_gate = btn_active;

    // Per-voice base frequency, pitch envelope, and noise mix
    reg [31:0] voice_phase_inc [0:3];
    reg [31:0] voice_pitch_start [0:3];
    reg [15:0] voice_pitch_decay [0:3];
    reg [7:0]  voice_noise_mix [0:3];    // 0=pure FM, 255=pure noise

    // ---- Voice presets: per-operator parameters ----
    // 16 operators (4 voices x 4 ops), all voices share same preset
    wire [2:0] algorithm;
    reg [15:0] p_ratio    [0:3];  // Per-op ratio
    reg [15:0] p_depth    [0:3];  // Per-op mod depth
    reg [23:0] p_attack   [0:3];  // Per-op envelope
    reg [23:0] p_decay    [0:3];
    reg [23:0] p_sustain  [0:3];
    reg [23:0] p_release  [0:3];

    reg [2:0] preset_algorithm;
    assign algorithm = preset_algorithm;

    always @(*) begin
        // Defaults: melodic mode (C major chord), no pitch envelope
        voice_phase_inc[0] = PHASE_C4;
        voice_phase_inc[1] = PHASE_E4;
        voice_phase_inc[2] = PHASE_G4;
        voice_phase_inc[3] = PHASE_C5;
        voice_pitch_start[0] = PHASE_C4;  // Same as base = no pitch sweep
        voice_pitch_start[1] = PHASE_E4;
        voice_pitch_start[2] = PHASE_G4;
        voice_pitch_start[3] = PHASE_C5;
        voice_pitch_decay[0] = 16'd0;
        voice_pitch_decay[1] = 16'd0;
        voice_pitch_decay[2] = 16'd0;
        voice_pitch_decay[3] = 16'd0;
        voice_noise_mix[0] = 8'd0;  // No noise for melodic presets
        voice_noise_mix[1] = 8'd0;
        voice_noise_mix[2] = 8'd0;
        voice_noise_mix[3] = 8'd0;

        case (voice_sel)
            3'd0: begin // Electric Piano (algo 0: serial chain)
                preset_algorithm = 3'd0;
                p_ratio[3]   = 16'h0E00;  p_depth[3]   = 16'd3000;
                p_attack[3]  = 24'd69905; p_decay[3]  = 24'd349;
                p_sustain[3] = 24'd3355443; p_release[3] = 24'd3495;
                p_ratio[2]   = 16'h0200;  p_depth[2]   = 16'd2000;
                p_attack[2]  = 24'd69905; p_decay[2]  = 24'd699;
                p_sustain[2] = 24'd5033165; p_release[2] = 24'd3495;
                p_ratio[1]   = 16'h0100;  p_depth[1]   = 16'd2048;
                p_attack[1]  = 24'd69905; p_decay[1]  = 24'd1748;
                p_sustain[1] = 24'd6710886; p_release[1] = 24'd3495;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd69905; p_decay[0]  = 24'd1748;
                p_sustain[0] = 24'd13421773; p_release[0] = 24'd3495;
            end
            3'd1: begin // Organ (algo 6: additive)
                preset_algorithm = 3'd6;
                // All 4 ops are carriers at different harmonics
                p_ratio[3]   = 16'h0400;  p_depth[3]   = 16'd0;
                p_attack[3]  = 24'd139810; p_decay[3]  = 24'd6990;
                p_sustain[3] = 24'd10066329; p_release[3] = 24'd6990;
                p_ratio[2]   = 16'h0200;  p_depth[2]   = 16'd0;
                p_attack[2]  = 24'd139810; p_decay[2]  = 24'd6990;
                p_sustain[2] = 24'd13421773; p_release[2] = 24'd6990;
                p_ratio[1]   = 16'h0300;  p_depth[1]   = 16'd0;
                p_attack[1]  = 24'd139810; p_decay[1]  = 24'd6990;
                p_sustain[1] = 24'd8388608; p_release[1] = 24'd6990;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd139810; p_decay[0]  = 24'd6990;
                p_sustain[0] = 24'd15099494; p_release[0] = 24'd6990;
            end
            3'd2: begin // Bass (algo 0: serial, heavy mod)
                preset_algorithm = 3'd0;
                p_ratio[3]   = 16'h0100;  p_depth[3]   = 16'd6000;
                p_attack[3]  = 24'd279620; p_decay[3]  = 24'd349;
                p_sustain[3] = 24'd1677721; p_release[3] = 24'd1748;
                p_ratio[2]   = 16'h0100;  p_depth[2]   = 16'd4096;
                p_attack[2]  = 24'd279620; p_decay[2]  = 24'd699;
                p_sustain[2] = 24'd3355443; p_release[2] = 24'd1748;
                p_ratio[1]   = 16'h0100;  p_depth[1]   = 16'd3000;
                p_attack[1]  = 24'd279620; p_decay[1]  = 24'd1748;
                p_sustain[1] = 24'd5033165; p_release[1] = 24'd1748;
                p_ratio[0]   = 16'h0080;  p_depth[0]   = 16'd0;  // 0.5x = sub octave
                p_attack[0]  = 24'd279620; p_decay[0]  = 24'd1748;
                p_sustain[0] = 24'd10066329; p_release[0] = 24'd1748;
            end
            3'd3: begin // Brass (algo 3: two parallel pairs)
                preset_algorithm = 3'd3;
                p_ratio[3]   = 16'h0100;  p_depth[3]   = 16'd5000;
                p_attack[3]  = 24'd6990;  p_decay[3]  = 24'd699;
                p_sustain[3] = 24'd10066329; p_release[3] = 24'd3495;
                p_ratio[2]   = 16'h0100;  p_depth[2]   = 16'd0;
                p_attack[2]  = 24'd13981; p_decay[2]  = 24'd1748;
                p_sustain[2] = 24'd13421773; p_release[2] = 24'd3495;
                p_ratio[1]   = 16'h0300;  p_depth[1]   = 16'd3000;
                p_attack[1]  = 24'd6990;  p_decay[1]  = 24'd699;
                p_sustain[1] = 24'd8388608; p_release[1] = 24'd3495;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd13981; p_decay[0]  = 24'd1748;
                p_sustain[0] = 24'd13421773; p_release[0] = 24'd3495;
            end
            3'd4: begin // Strings (algo 2: OP4->OP3->OP2* + OP1*)
                preset_algorithm = 3'd2;
                p_ratio[3]   = 16'h0300;  p_depth[3]   = 16'd2000;
                p_attack[3]  = 24'd1748;  p_decay[3]  = 24'd349;
                p_sustain[3] = 24'd8388608; p_release[3] = 24'd1748;
                p_ratio[2]   = 16'h0200;  p_depth[2]   = 16'd1500;
                p_attack[2]  = 24'd1748;  p_decay[2]  = 24'd699;
                p_sustain[2] = 24'd10066329; p_release[2] = 24'd1748;
                p_ratio[1]   = 16'h0100;  p_depth[1]   = 16'd0;
                p_attack[1]  = 24'd1748;  p_decay[1]  = 24'd699;
                p_sustain[1] = 24'd13421773; p_release[1] = 24'd1748;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd1748;  p_decay[0]  = 24'd699;
                p_sustain[0] = 24'd11744051; p_release[0] = 24'd1748;
            end
            3'd5: begin // Bell (algo 0: serial, inharmonic ratios)
                preset_algorithm = 3'd0;
                p_ratio[3]   = 16'h0570;  p_depth[3]   = 16'd4000;
                p_attack[3]  = 24'd279620; p_decay[3]  = 24'd175;
                p_sustain[3] = 24'd1677721; p_release[3] = 24'd175;
                p_ratio[2]   = 16'h0370;  p_depth[2]   = 16'd5000;
                p_attack[2]  = 24'd279620; p_decay[2]  = 24'd350;
                p_sustain[2] = 24'd3355443; p_release[2] = 24'd350;
                p_ratio[1]   = 16'h0140;  p_depth[1]   = 16'd3000;
                p_attack[1]  = 24'd279620; p_decay[1]  = 24'd350;
                p_sustain[1] = 24'd5033165; p_release[1] = 24'd350;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd279620; p_decay[0]  = 24'd175;
                p_sustain[0] = 24'd0;      p_release[0] = 24'd175;
            end
            3'd6: begin // Lead (algo 1: (OP3+OP4)->OP2->OP1)
                preset_algorithm = 3'd1;
                p_ratio[3]   = 16'h0300;  p_depth[3]   = 16'd4000;
                p_attack[3]  = 24'd279620; p_decay[3]  = 24'd1748;
                p_sustain[3] = 24'd13421773; p_release[3] = 24'd6990;
                p_ratio[2]   = 16'h0200;  p_depth[2]   = 16'd3000;
                p_attack[2]  = 24'd279620; p_decay[2]  = 24'd1748;
                p_sustain[2] = 24'd10066329; p_release[2] = 24'd6990;
                p_ratio[1]   = 16'h0100;  p_depth[1]   = 16'd5000;
                p_attack[1]  = 24'd279620; p_decay[1]  = 24'd3495;
                p_sustain[1] = 24'd11744051; p_release[1] = 24'd6990;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd279620; p_decay[0]  = 24'd3495;
                p_sustain[0] = 24'd11744051; p_release[0] = 24'd6990;
            end
            3'd7: begin // DRUM KIT
                // Each voice is a different drum sound with pitch envelope
                preset_algorithm = 3'd0;  // Serial chain for all drums

                // Voice 0 = KICK: 200Hz->40Hz fast sweep, pure tone
                voice_phase_inc[0] = PHASE_40HZ;
                voice_pitch_start[0] = PHASE_200HZ;
                voice_pitch_decay[0] = 16'd4000;
                voice_noise_mix[0] = 8'd0;

                // Voice 1 = SNARE: mid pitch + moderate noise
                voice_phase_inc[1] = PHASE_300HZ;
                voice_pitch_start[1] = PHASE_800HZ;
                voice_pitch_decay[1] = 16'd5000;
                voice_noise_mix[1] = 8'd140;        // ~55% noise

                // Voice 2 = HI-HAT: pure noise, very short
                voice_phase_inc[2] = PHASE_8KHZ;
                voice_pitch_start[2] = PHASE_8KHZ;
                voice_pitch_decay[2] = 16'd0;
                voice_noise_mix[2] = 8'd255;

                // Voice 3 = TOM: pitch sweep, slight noise
                voice_phase_inc[3] = PHASE_150HZ;
                voice_pitch_start[3] = PHASE_400HZ;
                voice_pitch_decay[3] = 16'd2000;
                voice_noise_mix[3] = 8'd20;

                // Shared op params — but each voice's envelope is key:
                // Kick: long body (~200ms)
                // Snare: medium (~150ms)
                // Hi-hat: ultra short (~30ms)
                // Tom: medium-long (~180ms)
                // Since all voices share op params, we tune for a compromise.
                // Use algorithm 6 (additive) so each voice is independent.
                preset_algorithm = 3'd6;

                // Only OP1 (carrier) matters in additive mode.
                // OP4,3,2 are also carriers but at lower levels for body.
                // Keep them simple - 1x ratio, no modulation.
                p_ratio[3]   = 16'h0100;  p_depth[3]   = 16'd0;
                p_attack[3]  = 24'd559240; p_decay[3]  = 24'd6990;   // ~50ms
                p_sustain[3] = 24'd0;      p_release[3] = 24'd69905;
                p_ratio[2]   = 16'h0100;  p_depth[2]   = 16'd0;
                p_attack[2]  = 24'd559240; p_decay[2]  = 24'd3495;   // ~100ms
                p_sustain[2] = 24'd0;      p_release[2] = 24'd69905;
                p_ratio[1]   = 16'h0100;  p_depth[1]   = 16'd0;
                p_attack[1]  = 24'd559240; p_decay[1]  = 24'd1748;   // ~200ms
                p_sustain[1] = 24'd0;      p_release[1] = 24'd69905;
                p_ratio[0]   = 16'h0100;  p_depth[0]   = 16'd0;
                p_attack[0]  = 24'd559240; p_decay[0]  = 24'd1748;   // ~200ms
                p_sustain[0] = 24'd0;      p_release[0] = 24'd69905;
            end
        endcase
    end

    // ---- TDM FM Synth Engine ----
    wire signed [15:0] pcm_out;
    wire sample_valid;

    fm_synth_tdm #(
        .CLK_FREQ(25_000_000),
        .SAMPLE_RATE(48_000)
    ) synth_engine (
        .clk(clk_i),
        .reset(1'b0),
        .voice_gate(voice_gate),
        .voice_phase_inc_0(voice_phase_inc[0]),
        .voice_phase_inc_1(voice_phase_inc[1]),
        .voice_phase_inc_2(voice_phase_inc[2]),
        .voice_phase_inc_3(voice_phase_inc[3]),
        .voice_algorithm(algorithm),
        .voice_pitch_start_0(voice_pitch_start[0]),
        .voice_pitch_start_1(voice_pitch_start[1]),
        .voice_pitch_start_2(voice_pitch_start[2]),
        .voice_pitch_start_3(voice_pitch_start[3]),
        .voice_pitch_decay_0(voice_pitch_decay[0]),
        .voice_pitch_decay_1(voice_pitch_decay[1]),
        .voice_pitch_decay_2(voice_pitch_decay[2]),
        .voice_pitch_decay_3(voice_pitch_decay[3]),
        .voice_noise_mix_0(voice_noise_mix[0]),
        .voice_noise_mix_1(voice_noise_mix[1]),
        .voice_noise_mix_2(voice_noise_mix[2]),
        .voice_noise_mix_3(voice_noise_mix[3]),
        .op_ratio_0(p_ratio[0]),   .op_ratio_1(p_ratio[1]),
        .op_ratio_2(p_ratio[2]),   .op_ratio_3(p_ratio[3]),
        .op_depth_0(p_depth[0]),   .op_depth_1(p_depth[1]),
        .op_depth_2(p_depth[2]),   .op_depth_3(p_depth[3]),
        .op_attack_0(p_attack[0]), .op_attack_1(p_attack[1]),
        .op_attack_2(p_attack[2]), .op_attack_3(p_attack[3]),
        .op_decay_0(p_decay[0]),   .op_decay_1(p_decay[1]),
        .op_decay_2(p_decay[2]),   .op_decay_3(p_decay[3]),
        .op_sustain_0(p_sustain[0]), .op_sustain_1(p_sustain[1]),
        .op_sustain_2(p_sustain[2]), .op_sustain_3(p_sustain[3]),
        .op_release_0(p_release[0]), .op_release_1(p_release[1]),
        .op_release_2(p_release[2]), .op_release_3(p_release[3]),
        .pcm_out(pcm_out),
        .sample_valid(sample_valid)
    );

    // ---- LED ----
    assign led_o = ~(|voice_gate);

    // ---- PWM DAC ----
    wire [15:0] pcm_unsigned = pcm_out + 16'h8000;
    wire [7:0]  pwm_level = pcm_unsigned[15:8];
    reg [7:0] pwm_counter;
    always @(posedge clk_i) pwm_counter <= pwm_counter + 1;
    assign audio_out = (pwm_level > pwm_counter);

    // ---- I2S output ----
    i2s_tx #(.CLK_FREQ(25_000_000), .SAMPLE_RATE(48_000)) i2s (
        .clk(clk_i), .reset(1'b0),
        .pcm_in(pcm_out), .sample_valid(sample_valid),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .din(i2s_din)
    );
    assign i2s_sd = 1'b1;
    assign i2s_gain = 1'b0;

endmodule
