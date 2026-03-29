// FM Synth Top-Level for Colorlight i5
//
// 4 note buttons play C major: C4, E4, G4, C5
// 3 voice switches select FM synthesis voice presets (8 combinations)
// PWM audio output on GPIO pin
// LED indicates note active
//
// Voices (selected by 3 switches):
//   000: Electric Piano - warm, bell-like
//   001: Organ - steady, bright
//   010: Bass - deep, punchy
//   011: Brass - bright, brassy attack
//   100: Strings - slow attack, lush
//   101: Bell - metallic, long decay
//   110: Lead - sharp, cutting
//   111: Pluck - short, percussive

module fm_synth_top (
    input  wire       clk_i,      // 25 MHz system clock
    input  wire [3:0] btn,        // 4 note buttons (active-low)
    input  wire [2:0] sw,         // 3 voice switches (active-low)
    output wire       led_o,      // LED (active-low on i5)
    output wire       audio_out   // PWM audio on GPIO
);

    // ---- Phase increments for C major (48kHz sample rate, 32-bit phase) ----
    // freq * 2^32 / 48000
    localparam [31:0] PHASE_C4 = 32'h016534C3;  // C4  261.63 Hz
    localparam [31:0] PHASE_E4 = 32'h01C20D2F;  // E4  329.63 Hz
    localparam [31:0] PHASE_G4 = 32'h02173456;  // G4  392.00 Hz
    localparam [31:0] PHASE_C5 = 32'h02CA6987;  // C5  523.25 Hz

    // ---- Button debouncing ----
    reg [3:0] btn_sync1, btn_sync2;
    reg [3:0] btn_stable;
    reg [19:0] debounce_cnt;

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

    // ---- Switch synchronizer ----
    reg [2:0] sw_sync1, sw_sync2;
    always @(posedge clk_i) begin
        sw_sync1 <= sw;
        sw_sync2 <= sw_sync1;
    end
    wire [2:0] voice_sel = ~sw_sync2;  // Active-low switches

    // ---- Note selection ----
    wire [3:0] btn_active = ~btn_stable;
    wire gate = |btn_active;

    reg [31:0] phase_inc;
    always @(*) begin
        if (btn_active[0])      phase_inc = PHASE_C4;
        else if (btn_active[1]) phase_inc = PHASE_E4;
        else if (btn_active[2]) phase_inc = PHASE_G4;
        else if (btn_active[3]) phase_inc = PHASE_C5;
        else                    phase_inc = 32'd0;
    end

    // ---- Voice presets ----
    // Each voice defines: mod_ratio, mod_depth, carrier ADSR, modulator ADSR
    reg [15:0] mod_ratio;
    reg [15:0] mod_depth;
    reg [23:0] car_attack, car_decay, car_sustain, car_release;
    reg [23:0] mod_attack, mod_decay, mod_sustain, mod_release;

    always @(*) begin
        case (voice_sel)
            3'd0: begin // Electric Piano - warm, bell-like
                mod_ratio   = 16'h0200;      // 2.0x
                mod_depth   = 16'd2048;
                car_attack  = 24'd69905;      // 5ms
                car_decay   = 24'd1748;       // 200ms
                car_sustain = 24'd13421773;   // 80%
                car_release = 24'd3495;       // 100ms
                mod_attack  = 24'd69905;      // 5ms
                mod_decay   = 24'd699;        // 500ms
                mod_sustain = 24'd6710886;    // 40%
                mod_release = 24'd3495;       // 100ms
            end
            3'd1: begin // Organ - steady, bright
                mod_ratio   = 16'h0100;      // 1.0x
                mod_depth   = 16'd3000;
                car_attack  = 24'd139810;     // 2.5ms
                car_decay   = 24'd6990;       // 50ms
                car_sustain = 24'd15099494;   // 90%
                car_release = 24'd6990;       // 50ms
                mod_attack  = 24'd139810;     // 2.5ms
                mod_decay   = 24'd6990;       // 50ms
                mod_sustain = 24'd15099494;   // 90%
                mod_release = 24'd6990;       // 50ms
            end
            3'd2: begin // Bass - deep, punchy
                mod_ratio   = 16'h0100;      // 1.0x
                mod_depth   = 16'd4096;
                car_attack  = 24'd279620;     // 1.25ms
                car_decay   = 24'd1748;       // 200ms
                car_sustain = 24'd8388608;    // 50%
                car_release = 24'd1748;       // 200ms
                mod_attack  = 24'd279620;     // 1.25ms
                mod_decay   = 24'd349;        // 1000ms
                mod_sustain = 24'd3355443;    // 20%
                mod_release = 24'd1748;       // 200ms
            end
            3'd3: begin // Brass - bright, brassy attack
                mod_ratio   = 16'h0100;      // 1.0x
                mod_depth   = 16'd5000;
                car_attack  = 24'd13981;      // 25ms
                car_decay   = 24'd1748;       // 200ms
                car_sustain = 24'd13421773;   // 80%
                car_release = 24'd3495;       // 100ms
                mod_attack  = 24'd6990;       // 50ms
                mod_decay   = 24'd699;        // 500ms
                mod_sustain = 24'd10066329;   // 60%
                mod_release = 24'd3495;       // 100ms
            end
            3'd4: begin // Strings - slow attack, lush
                mod_ratio   = 16'h0300;      // 3.0x
                mod_depth   = 16'd1500;
                car_attack  = 24'd1748;       // 200ms
                car_decay   = 24'd699;        // 500ms
                car_sustain = 24'd13421773;   // 80%
                car_release = 24'd1748;       // 200ms
                mod_attack  = 24'd1748;       // 200ms
                mod_decay   = 24'd349;        // 1000ms
                mod_sustain = 24'd8388608;    // 50%
                mod_release = 24'd1748;       // 200ms
            end
            3'd5: begin // Bell - metallic, long decay
                mod_ratio   = 16'h0370;      // 3.44x (non-integer = inharmonic)
                mod_depth   = 16'd6000;
                car_attack  = 24'd279620;     // 1.25ms
                car_decay   = 24'd175;        // 2000ms
                car_sustain = 24'd0;          // 0% (fully decays)
                car_release = 24'd175;        // 2000ms
                mod_attack  = 24'd279620;     // 1.25ms
                mod_decay   = 24'd350;        // 1000ms
                mod_sustain = 24'd3355443;    // 20%
                mod_release = 24'd350;        // 1000ms
            end
            3'd6: begin // Lead - sharp, cutting
                mod_ratio   = 16'h0200;      // 2.0x
                mod_depth   = 16'd8000;
                car_attack  = 24'd279620;     // 1.25ms
                car_decay   = 24'd3495;       // 100ms
                car_sustain = 24'd11744051;   // 70%
                car_release = 24'd6990;       // 50ms
                mod_attack  = 24'd279620;     // 1.25ms
                mod_decay   = 24'd1748;       // 200ms
                mod_sustain = 24'd13421773;   // 80%
                mod_release = 24'd6990;       // 50ms
            end
            3'd7: begin // Pluck - short, percussive
                mod_ratio   = 16'h0300;      // 3.0x
                mod_depth   = 16'd5000;
                car_attack  = 24'd279620;     // 1.25ms
                car_decay   = 24'd699;        // 500ms
                car_sustain = 24'd0;          // 0% (fully decays)
                car_release = 24'd6990;       // 50ms
                mod_attack  = 24'd279620;     // 1.25ms
                mod_decay   = 24'd1748;       // 200ms
                mod_sustain = 24'd0;          // 0%
                mod_release = 24'd6990;       // 50ms
            end
        endcase
    end

    // ---- LED indicator (active low) ----
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
        .mod_ratio(mod_ratio),
        .mod_depth(mod_depth),
        .car_attack(car_attack),
        .car_decay(car_decay),
        .car_sustain(car_sustain),
        .car_release(car_release),
        .mod_attack(mod_attack),
        .mod_decay(mod_decay),
        .mod_sustain(mod_sustain),
        .mod_release(mod_release),
        .pcm_out(pcm_out),
        .sample_valid(sample_valid)
    );

    // ---- PWM DAC ----
    // Convert signed 16-bit PCM to unsigned 8-bit for PWM
    // Note: idle output is 50% duty cycle (~97.6kHz). Add RC low-pass
    // filter (R=1K, C=10nF, fc~16kHz) to clean up for headphones.
    wire [15:0] pcm_unsigned = pcm_out + 16'h8000;
    wire [7:0]  pwm_level = pcm_unsigned[15:8];

    // Free-running 8-bit counter at 25MHz -> PWM freq ~97.6 kHz
    reg [7:0] pwm_counter;
    always @(posedge clk_i)
        pwm_counter <= pwm_counter + 1;

    assign audio_out = (pwm_level > pwm_counter);

endmodule
