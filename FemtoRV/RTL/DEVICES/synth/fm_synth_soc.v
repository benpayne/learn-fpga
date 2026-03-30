// FM Synth SoC Peripheral
// Wraps TDM engine with register interface, MIDI note table, and preset ROM

module fm_synth_soc (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] wdata,
    input  wire        wstrb,
    input  wire        sel,
    output wire        audio_pwm,
    output wire        i2s_bclk,
    output wire        i2s_lrck,
    output wire        i2s_din
);

    // ---- Register interface ----
    wire [3:0]  voice_gate;
    wire [6:0]  voice_note_0, voice_note_1, voice_note_2, voice_note_3;
    wire [2:0]  voice_preset_0, voice_preset_1, voice_preset_2, voice_preset_3;
    wire [3:0]  voice_trigger;

    fm_synth_registers regs (
        .clk(clk), .reset(!reset),
        .wdata(wdata), .wstrb(wstrb), .sel(sel),
        .voice_gate(voice_gate), .voice_trigger(voice_trigger),
        .voice_note_0(voice_note_0), .voice_note_1(voice_note_1),
        .voice_note_2(voice_note_2), .voice_note_3(voice_note_3),
        .voice_preset_0(voice_preset_0), .voice_preset_1(voice_preset_1),
        .voice_preset_2(voice_preset_2), .voice_preset_3(voice_preset_3)
    );

    // ---- MIDI note -> phase_inc lookup ----
    reg [31:0] midi_table [0:127];
    initial $readmemh("midi_note_table.hex", midi_table);

    wire [31:0] v_phase_inc_0 = midi_table[voice_note_0];
    wire [31:0] v_phase_inc_1 = midi_table[voice_note_1];
    wire [31:0] v_phase_inc_2 = midi_table[voice_note_2];
    wire [31:0] v_phase_inc_3 = midi_table[voice_note_3];

    // ---- Preset selection (use voice 0's preset for all — simplification) ----
    // Each preset: algorithm + 4 ops (ratio, depth, attack, decay, sustain, release)
    wire [2:0] active_preset = voice_preset_0;

    reg [2:0]  p_algorithm;
    reg [15:0] p_ratio_0, p_ratio_1, p_ratio_2, p_ratio_3;
    reg [15:0] p_depth_0, p_depth_1, p_depth_2, p_depth_3;
    reg [23:0] p_attack_0, p_attack_1, p_attack_2, p_attack_3;
    reg [23:0] p_decay_0, p_decay_1, p_decay_2, p_decay_3;
    reg [23:0] p_sustain_0, p_sustain_1, p_sustain_2, p_sustain_3;
    reg [23:0] p_release_0, p_release_1, p_release_2, p_release_3;

    always @(*) begin
        case (active_preset)
            3'd0: begin // Electric Piano
                p_algorithm = 3'd0;
                p_ratio_0=16'h0100; p_depth_0=16'd0;     p_attack_0=24'd69905; p_decay_0=24'd1748; p_sustain_0=24'd13421773; p_release_0=24'd3495;
                p_ratio_1=16'h0100; p_depth_1=16'd2048;  p_attack_1=24'd69905; p_decay_1=24'd1748; p_sustain_1=24'd6710886;  p_release_1=24'd3495;
                p_ratio_2=16'h0200; p_depth_2=16'd2000;  p_attack_2=24'd69905; p_decay_2=24'd699;  p_sustain_2=24'd5033165;  p_release_2=24'd3495;
                p_ratio_3=16'h0E00; p_depth_3=16'd3000;  p_attack_3=24'd69905; p_decay_3=24'd349;  p_sustain_3=24'd3355443;  p_release_3=24'd3495;
            end
            3'd1: begin // Organ
                p_algorithm = 3'd6;
                p_ratio_0=16'h0100; p_depth_0=16'd0; p_attack_0=24'd139810; p_decay_0=24'd6990; p_sustain_0=24'd15099494; p_release_0=24'd6990;
                p_ratio_1=16'h0200; p_depth_1=16'd0; p_attack_1=24'd139810; p_decay_1=24'd6990; p_sustain_1=24'd13421773; p_release_1=24'd6990;
                p_ratio_2=16'h0300; p_depth_2=16'd0; p_attack_2=24'd139810; p_decay_2=24'd6990; p_sustain_2=24'd8388608;  p_release_2=24'd6990;
                p_ratio_3=16'h0400; p_depth_3=16'd0; p_attack_3=24'd139810; p_decay_3=24'd6990; p_sustain_3=24'd10066329; p_release_3=24'd6990;
            end
            3'd2: begin // Bass
                p_algorithm = 3'd0;
                p_ratio_0=16'h0080; p_depth_0=16'd0;    p_attack_0=24'd279620; p_decay_0=24'd1748; p_sustain_0=24'd10066329; p_release_0=24'd1748;
                p_ratio_1=16'h0100; p_depth_1=16'd3000; p_attack_1=24'd279620; p_decay_1=24'd1748; p_sustain_1=24'd5033165;  p_release_1=24'd1748;
                p_ratio_2=16'h0100; p_depth_2=16'd4096; p_attack_2=24'd279620; p_decay_2=24'd699;  p_sustain_2=24'd3355443;  p_release_2=24'd1748;
                p_ratio_3=16'h0100; p_depth_3=16'd6000; p_attack_3=24'd279620; p_decay_3=24'd349;  p_sustain_3=24'd1677721;  p_release_3=24'd1748;
            end
            3'd3: begin // Brass
                p_algorithm = 3'd3;
                p_ratio_0=16'h0100; p_depth_0=16'd0;    p_attack_0=24'd13981; p_decay_0=24'd1748; p_sustain_0=24'd13421773; p_release_0=24'd3495;
                p_ratio_1=16'h0300; p_depth_1=16'd3000; p_attack_1=24'd6990;  p_decay_1=24'd699;  p_sustain_1=24'd8388608;  p_release_1=24'd3495;
                p_ratio_2=16'h0100; p_depth_2=16'd0;    p_attack_2=24'd13981; p_decay_2=24'd1748; p_sustain_2=24'd13421773; p_release_2=24'd3495;
                p_ratio_3=16'h0100; p_depth_3=16'd5000; p_attack_3=24'd6990;  p_decay_3=24'd699;  p_sustain_3=24'd10066329; p_release_3=24'd3495;
            end
            3'd4: begin // Strings
                p_algorithm = 3'd2;
                p_ratio_0=16'h0100; p_depth_0=16'd0;    p_attack_0=24'd1748; p_decay_0=24'd699; p_sustain_0=24'd11744051; p_release_0=24'd1748;
                p_ratio_1=16'h0100; p_depth_1=16'd0;    p_attack_1=24'd1748; p_decay_1=24'd699; p_sustain_1=24'd13421773; p_release_1=24'd1748;
                p_ratio_2=16'h0200; p_depth_2=16'd1500; p_attack_2=24'd1748; p_decay_2=24'd699; p_sustain_2=24'd10066329; p_release_2=24'd1748;
                p_ratio_3=16'h0300; p_depth_3=16'd2000; p_attack_3=24'd1748; p_decay_3=24'd349; p_sustain_3=24'd8388608;  p_release_3=24'd1748;
            end
            3'd5: begin // Bell
                p_algorithm = 3'd0;
                p_ratio_0=16'h0100; p_depth_0=16'd0;    p_attack_0=24'd279620; p_decay_0=24'd175; p_sustain_0=24'd0; p_release_0=24'd175;
                p_ratio_1=16'h0140; p_depth_1=16'd3000; p_attack_1=24'd279620; p_decay_1=24'd350; p_sustain_1=24'd0; p_release_1=24'd350;
                p_ratio_2=16'h0370; p_depth_2=16'd5000; p_attack_2=24'd279620; p_decay_2=24'd350; p_sustain_2=24'd0; p_release_2=24'd350;
                p_ratio_3=16'h0570; p_depth_3=16'd4000; p_attack_3=24'd279620; p_decay_3=24'd175; p_sustain_3=24'd0; p_release_3=24'd175;
            end
            3'd6: begin // Lead
                p_algorithm = 3'd1;
                p_ratio_0=16'h0100; p_depth_0=16'd0;    p_attack_0=24'd279620; p_decay_0=24'd3495; p_sustain_0=24'd11744051; p_release_0=24'd6990;
                p_ratio_1=16'h0100; p_depth_1=16'd5000; p_attack_1=24'd279620; p_decay_1=24'd3495; p_sustain_1=24'd11744051; p_release_1=24'd6990;
                p_ratio_2=16'h0200; p_depth_2=16'd3000; p_attack_2=24'd279620; p_decay_2=24'd1748; p_sustain_2=24'd10066329; p_release_2=24'd6990;
                p_ratio_3=16'h0300; p_depth_3=16'd4000; p_attack_3=24'd279620; p_decay_3=24'd1748; p_sustain_3=24'd13421773; p_release_3=24'd6990;
            end
            3'd7: begin // Pluck
                p_algorithm = 3'd0;
                p_ratio_0=16'h0100; p_depth_0=16'd0;    p_attack_0=24'd279620; p_decay_0=24'd699; p_sustain_0=24'd0; p_release_0=24'd6990;
                p_ratio_1=16'h0100; p_depth_1=16'd3000; p_attack_1=24'd279620; p_decay_1=24'd699; p_sustain_1=24'd0; p_release_1=24'd6990;
                p_ratio_2=16'h0300; p_depth_2=16'd4000; p_attack_2=24'd279620; p_decay_2=24'd1748; p_sustain_2=24'd0; p_release_2=24'd6990;
                p_ratio_3=16'h0500; p_depth_3=16'd6000; p_attack_3=24'd279620; p_decay_3=24'd1748; p_sustain_3=24'd0; p_release_3=24'd6990;
            end
        endcase
    end

    // ---- TDM engine ----
    wire signed [15:0] pcm_out;
    wire sample_valid;

    fm_synth_tdm #(.CLK_FREQ(25_000_000), .SAMPLE_RATE(48_000)) engine (
        .clk(clk), .reset(!reset),
        .voice_gate(voice_gate),
        .voice_phase_inc_0(v_phase_inc_0), .voice_phase_inc_1(v_phase_inc_1),
        .voice_phase_inc_2(v_phase_inc_2), .voice_phase_inc_3(v_phase_inc_3),
        .voice_algorithm(p_algorithm),
        .voice_pitch_start_0(v_phase_inc_0), .voice_pitch_start_1(v_phase_inc_1),
        .voice_pitch_start_2(v_phase_inc_2), .voice_pitch_start_3(v_phase_inc_3),
        .voice_pitch_decay_0(16'd0), .voice_pitch_decay_1(16'd0),
        .voice_pitch_decay_2(16'd0), .voice_pitch_decay_3(16'd0),
        .voice_noise_mix_0(8'd0), .voice_noise_mix_1(8'd0),
        .voice_noise_mix_2(8'd0), .voice_noise_mix_3(8'd0),
        .op_ratio_0(p_ratio_0), .op_ratio_1(p_ratio_1),
        .op_ratio_2(p_ratio_2), .op_ratio_3(p_ratio_3),
        .op_depth_0(p_depth_0), .op_depth_1(p_depth_1),
        .op_depth_2(p_depth_2), .op_depth_3(p_depth_3),
        .op_attack_0(p_attack_0), .op_attack_1(p_attack_1),
        .op_attack_2(p_attack_2), .op_attack_3(p_attack_3),
        .op_decay_0(p_decay_0), .op_decay_1(p_decay_1),
        .op_decay_2(p_decay_2), .op_decay_3(p_decay_3),
        .op_sustain_0(p_sustain_0), .op_sustain_1(p_sustain_1),
        .op_sustain_2(p_sustain_2), .op_sustain_3(p_sustain_3),
        .op_release_0(p_release_0), .op_release_1(p_release_1),
        .op_release_2(p_release_2), .op_release_3(p_release_3),
        .pcm_out(pcm_out), .sample_valid(sample_valid)
    );

    // ---- PWM DAC ----
    wire [15:0] pcm_unsigned = pcm_out + 16'h8000;
    wire [7:0]  pwm_level = pcm_unsigned[15:8];
    reg [7:0] pwm_counter;
    always @(posedge clk) pwm_counter <= pwm_counter + 1;
    assign audio_pwm = (pwm_level > pwm_counter);

    // ---- I2S output ----
    i2s_tx #(.CLK_FREQ(25_000_000), .SAMPLE_RATE(48_000)) i2s (
        .clk(clk), .reset(!reset),
        .pcm_in(pcm_out), .sample_valid(sample_valid),
        .bclk(i2s_bclk), .lrck(i2s_lrck), .din(i2s_din)
    );

endmodule
