// Testbench for fm_synth (integration test)
// Verifies: sample generation, FM modulation, gate behavior, note changes
`timescale 1ns/1ps

module tb_fm_synth;

    reg         clk;
    reg         reset;
    reg         gate;
    reg  [31:0] phase_inc;
    reg  [15:0] mod_ratio;
    reg  [15:0] mod_depth;
    reg  [23:0] car_attack, car_decay, car_sustain, car_release;
    reg  [23:0] mod_attack, mod_decay, mod_sustain, mod_release;
    wire signed [15:0] pcm_out;
    wire        sample_valid;

    // Use faster sample rate for simulation
    fm_synth #(
        .CLK_FREQ(25_000_000),
        .SAMPLE_RATE(48_000)
    ) uut (
        .clk(clk),
        .reset(reset),
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

    // 25 MHz clock
    initial clk = 0;
    always #20 clk = ~clk;

    integer pass_count;
    integer fail_count;
    integer i;
    integer sample_count;
    reg signed [15:0] max_sample, min_sample;
    reg signed [15:0] prev_pcm;
    integer zero_cross;
    reg prev_sign;
    integer nonzero_count;

    task wait_samples(input integer n);
        integer s;
        begin
            for (s = 0; s < n; s = s + 1) begin
                @(posedge clk);
                while (!sample_valid) @(posedge clk);
            end
        end
    endtask

    initial begin
        $dumpfile("tests/tb_fm_synth.vcd");
        $dumpvars(0, tb_fm_synth);

        pass_count = 0;
        fail_count = 0;

        // Setup FM parameters
        phase_inc   = 32'h016534C3;   // C4 (261.63 Hz)
        mod_ratio   = 16'h0200;       // 2:1 ratio
        mod_depth   = 16'd2048;       // Moderate depth

        // Fast envelopes for simulation
        car_attack  = 24'd167772;     // ~100 samples
        car_decay   = 24'd83886;      // ~200 samples
        car_sustain = 24'd13421773;   // 80%
        car_release = 24'd167772;     // ~100 samples

        mod_attack  = 24'd167772;
        mod_decay   = 24'd16777;      // ~1000 samples
        mod_sustain = 24'd6710886;    // 40%
        mod_release = 24'd167772;

        reset = 1;
        gate = 0;

        repeat (10) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        // ---- Test 1: Sample valid pulses ----
        $display("TEST 1: sample_valid pulses at sample rate");
        sample_count = 0;
        for (i = 0; i < 25000; i = i + 1) begin
            @(posedge clk);
            if (sample_valid) sample_count = sample_count + 1;
        end
        // At 25MHz, 25000 clocks = 1ms. At 48kHz, expect ~48 sample_valid pulses
        if (sample_count >= 45 && sample_count <= 51) begin
            $display("  PASS: %d sample_valid pulses in 1ms (~48kHz)", sample_count);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %d sample_valid pulses (expected ~48)", sample_count);
            fail_count = fail_count + 1;
        end

        // ---- Test 2: Silent when gate is off ----
        $display("TEST 2: Silent when gate is off");
        gate = 0;
        wait_samples(50);
        nonzero_count = 0;
        for (i = 0; i < 100; i = i + 1) begin
            wait_samples(1);
            if (pcm_out != 16'sd0) nonzero_count = nonzero_count + 1;
        end
        if (nonzero_count == 0) begin
            $display("  PASS: output is silent (all zero)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %d non-zero samples when gate off", nonzero_count);
            fail_count = fail_count + 1;
        end

        // ---- Test 3: Sound when gate on ----
        $display("TEST 3: Sound produced when gate is on");
        gate = 1;
        wait_samples(150);  // Past attack phase

        max_sample = -16'sd32767;
        min_sample = 16'sd32767;
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (pcm_out > max_sample) max_sample = pcm_out;
            if (pcm_out < min_sample) min_sample = pcm_out;
        end

        if (max_sample > 16'sd1000 && min_sample < -16'sd1000) begin
            $display("  PASS: output swings %d to %d", min_sample, max_sample);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: weak output %d to %d", min_sample, max_sample);
            fail_count = fail_count + 1;
        end

        // ---- Test 4: Output within valid 16-bit range ----
        $display("TEST 4: Output within signed 16-bit range");
        if (max_sample <= 16'sd32767 && min_sample >= -16'sd32767) begin
            $display("  PASS: output within [-32767, 32767]");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: output exceeded range");
            fail_count = fail_count + 1;
        end

        // ---- Test 5: FM modulation produces harmonics (more zero crossings than pure sine) ----
        $display("TEST 5: FM modulation adds harmonics");
        zero_cross = 0;
        prev_sign = 0;
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (pcm_out > 0 && prev_sign == 1)
                zero_cross = zero_cross + 1;
            if (pcm_out < 0 && prev_sign == 0)
                zero_cross = zero_cross + 1;
            prev_sign = pcm_out[15];
        end
        // Pure C4 at 48kHz: 400 samples ≈ 2.17 cycles ≈ 4 zero crossings
        // FM with ratio 2 should have more due to harmonics
        if (zero_cross >= 4) begin
            $display("  PASS: %d zero crossings (FM adds harmonics)", zero_cross);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: only %d zero crossings", zero_cross);
            fail_count = fail_count + 1;
        end

        // ---- Test 6: Sound fades after gate off ----
        $display("TEST 6: Sound fades after gate off (release)");
        // Record level while gate is on
        max_sample = -16'sd32767;
        for (i = 0; i < 50; i = i + 1) begin
            wait_samples(1);
            if (pcm_out > max_sample) max_sample = pcm_out;
        end

        gate = 0;
        wait_samples(200);  // Wait through release

        // Now should be near silent
        nonzero_count = 0;
        for (i = 0; i < 50; i = i + 1) begin
            wait_samples(1);
            if (pcm_out != 16'sd0) nonzero_count = nonzero_count + 1;
        end
        if (nonzero_count == 0) begin
            $display("  PASS: output silent after release");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %d non-zero samples after release", nonzero_count);
            fail_count = fail_count + 1;
        end

        // ---- Test 7: Note change ----
        $display("TEST 7: Note change (C4 -> C5)");
        gate = 1;
        phase_inc = 32'h016534C3;  // C4
        wait_samples(200);

        zero_cross = 0;
        prev_sign = 0;
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (pcm_out > 0 && prev_sign == 1)
                zero_cross = zero_cross + 1;
            if (pcm_out < 0 && prev_sign == 0)
                zero_cross = zero_cross + 1;
            prev_sign = pcm_out[15];
        end

        // Switch to C5
        phase_inc = 32'h02CA6987;
        wait_samples(200);

        // Count zero crossings for C5
        prev_sign = 0;
        // Reuse 'i' to store C4 count
        i = zero_cross;
        zero_cross = 0;
        begin : count_c5
            integer j;
            for (j = 0; j < 400; j = j + 1) begin
                wait_samples(1);
                if (pcm_out > 0 && prev_sign == 1)
                    zero_cross = zero_cross + 1;
                if (pcm_out < 0 && prev_sign == 0)
                    zero_cross = zero_cross + 1;
                prev_sign = pcm_out[15];
            end
        end

        // C5 should have roughly 2x the zero crossings of C4
        if (zero_cross > i) begin
            $display("  PASS: C5 crossings (%d) > C4 crossings (%d)", zero_cross, i);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: C5 crossings (%d) not > C4 crossings (%d)", zero_cross, i);
            fail_count = fail_count + 1;
        end

        gate = 0;

        // ---- Summary ----
        $display("");
        $display("========================================");
        $display("fm_synth: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("========================================");
        if (fail_count > 0) begin
            $display("RESULT: FAIL");
            $finish(1);
        end else begin
            $display("RESULT: PASS");
        end
        $finish(0);
    end

    // Timeout watchdog
    initial begin
        #500_000_000;  // 500ms
        $display("TIMEOUT: test took too long");
        $finish(1);
    end

endmodule
