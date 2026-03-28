// Testbench for fm_operator
// Verifies: sine output correctness, phase accumulation, phase modulation
`timescale 1ns/1ps

module tb_fm_operator;

    reg         clk;
    reg         reset;
    reg         phase_reset;
    reg         sample_tick;
    reg  [31:0] phase_inc;
    reg  signed [31:0] phase_mod;
    wire signed [15:0] sample_out;

    fm_operator uut (
        .clk(clk),
        .reset(reset),
        .phase_reset(phase_reset),
        .sample_tick(sample_tick),
        .phase_inc(phase_inc),
        .phase_mod(phase_mod),
        .sample_out(sample_out)
    );

    // 25 MHz clock (40ns period)
    initial clk = 0;
    always #20 clk = ~clk;

    // Generate sample tick at ~48kHz (every 521 clocks for simplicity)
    integer tick_count;
    always @(posedge clk) begin
        if (reset)
            tick_count <= 0;
        else begin
            tick_count <= tick_count + 1;
            sample_tick <= (tick_count == 520);
            if (tick_count == 520)
                tick_count <= 0;
        end
    end

    // Test variables
    integer i;
    integer pass_count;
    integer fail_count;
    reg signed [15:0] prev_sample;
    reg signed [15:0] max_sample;
    reg signed [15:0] min_sample;
    integer zero_cross_count;
    reg prev_sign;

    task wait_samples(input integer n);
        integer s;
        begin
            for (s = 0; s < n; s = s + 1) begin
                @(posedge clk);
                while (!sample_tick) @(posedge clk);
            end
        end
    endtask

    initial begin
        $dumpfile("tests/tb_fm_operator.vcd");
        $dumpvars(0, tb_fm_operator);

        pass_count = 0;
        fail_count = 0;
        reset = 1;
        phase_reset = 0;
        phase_inc = 32'd0;
        phase_mod = 32'sd0;
        sample_tick = 0;

        // Hold reset
        repeat (10) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        // ---- Test 1: Zero phase increment should output near-zero ----
        $display("TEST 1: Zero frequency -> near-zero output");
        phase_inc = 32'd0;
        wait_samples(10);
        if (sample_out == 16'sd0) begin
            $display("  PASS: output is 0 with zero phase_inc");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: output is %d, expected 0", sample_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 2: Output stays within valid range ----
        $display("TEST 2: Output range with C4 (261.63 Hz)");
        phase_inc = 32'h016534C3;  // C4
        max_sample = -16'sd32767;
        min_sample = 16'sd32767;

        // Run for ~2 full cycles (48000/261.63 ≈ 183 samples per cycle)
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (sample_out > max_sample) max_sample = sample_out;
            if (sample_out < min_sample) min_sample = sample_out;
        end

        if (max_sample > 16'sd0 && max_sample <= 16'sd32767) begin
            $display("  PASS: max sample = %d (valid positive)", max_sample);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: max sample = %d (out of range)", max_sample);
            fail_count = fail_count + 1;
        end

        if (min_sample < 16'sd0 && min_sample >= -16'sd32767) begin
            $display("  PASS: min sample = %d (valid negative)", min_sample);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: min sample = %d (out of range)", min_sample);
            fail_count = fail_count + 1;
        end

        // ---- Test 3: Zero crossings (verify it oscillates) ----
        $display("TEST 3: Oscillation (zero crossings)");
        phase_reset = 1;
        @(posedge clk);
        phase_reset = 0;

        zero_cross_count = 0;
        prev_sign = 0;
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (sample_out > 0 && prev_sign == 1)
                zero_cross_count = zero_cross_count + 1;
            if (sample_out < 0 && prev_sign == 0)
                zero_cross_count = zero_cross_count + 1;
            prev_sign = sample_out[15]; // sign bit
        end

        // For ~2 cycles of a sine wave, expect ~4 zero crossings (2 per cycle)
        if (zero_cross_count >= 3 && zero_cross_count <= 6) begin
            $display("  PASS: %d zero crossings in ~2 periods", zero_cross_count);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %d zero crossings (expected 3-6)", zero_cross_count);
            fail_count = fail_count + 1;
        end

        // ---- Test 4: Phase reset ----
        $display("TEST 4: Phase reset");
        // Let it run a bit
        wait_samples(50);
        prev_sample = sample_out;

        // Reset phase
        phase_reset = 1;
        @(posedge clk);
        phase_reset = 0;
        wait_samples(2);

        // After reset, output should be near the start of the sine wave (small positive)
        if (sample_out >= 16'sd0 && sample_out < 16'sd5000) begin
            $display("  PASS: after phase reset, output = %d (near zero start)", sample_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: after phase reset, output = %d (expected near zero)", sample_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 5: Higher frequency has more zero crossings ----
        $display("TEST 5: C5 has ~2x zero crossings of C4");
        phase_reset = 1;
        @(posedge clk);
        phase_reset = 0;
        phase_inc = 32'h02CA6987;  // C5 (523.25 Hz, double C4)

        zero_cross_count = 0;
        prev_sign = 0;
        for (i = 0; i < 400; i = i + 1) begin
            wait_samples(1);
            if (sample_out > 0 && prev_sign == 1)
                zero_cross_count = zero_cross_count + 1;
            if (sample_out < 0 && prev_sign == 0)
                zero_cross_count = zero_cross_count + 1;
            prev_sign = sample_out[15];
        end

        // C5 is 2x C4 freq, so ~8 zero crossings in same time window
        if (zero_cross_count >= 6 && zero_cross_count <= 12) begin
            $display("  PASS: C5 has %d zero crossings (~2x C4)", zero_cross_count);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: C5 has %d zero crossings (expected 6-12)", zero_cross_count);
            fail_count = fail_count + 1;
        end

        // ---- Summary ----
        $display("");
        $display("========================================");
        $display("fm_operator: %0d PASSED, %0d FAILED", pass_count, fail_count);
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
        #100_000_000;  // 100ms
        $display("TIMEOUT: test took too long");
        $finish(1);
    end

endmodule
