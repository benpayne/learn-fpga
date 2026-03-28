// Testbench for fm_envelope
// Verifies: ADSR state transitions, level correctness, gate behavior
`timescale 1ns/1ps

module tb_fm_envelope;

    reg         clk;
    reg         reset;
    reg         sample_tick;
    reg         gate;
    reg  [23:0] attack_rate;
    reg  [23:0] decay_rate;
    reg  [23:0] sustain_level;
    reg  [23:0] release_rate;
    wire [15:0] level_out;

    fm_envelope uut (
        .clk(clk),
        .reset(reset),
        .sample_tick(sample_tick),
        .gate(gate),
        .attack_rate(attack_rate),
        .decay_rate(decay_rate),
        .sustain_level(sustain_level),
        .release_rate(release_rate),
        .level_out(level_out)
    );

    // 25 MHz clock
    initial clk = 0;
    always #20 clk = ~clk;

    // Sample tick generator (simplified: every 32 clocks for faster sim)
    reg [4:0] tick_cnt;
    always @(posedge clk) begin
        if (reset) begin
            tick_cnt <= 0;
            sample_tick <= 0;
        end else begin
            tick_cnt <= tick_cnt + 1;
            sample_tick <= (tick_cnt == 5'd31);
        end
    end

    integer pass_count;
    integer fail_count;
    integer i;
    reg [15:0] prev_level;

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
        $dumpfile("tests/tb_fm_envelope.vcd");
        $dumpvars(0, tb_fm_envelope);

        pass_count = 0;
        fail_count = 0;

        // Setup: moderate rates for testability
        // Attack: reach max in ~100 samples
        attack_rate  = 24'd167772;    // ~16777216/100
        decay_rate   = 24'd83886;     // ~16777216/200
        sustain_level = 24'd8388608;  // 50%
        release_rate  = 24'd167772;   // ~100 samples

        reset = 1;
        gate = 0;
        sample_tick = 0;

        repeat (10) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        // ---- Test 1: Idle state - output should be zero ----
        $display("TEST 1: Idle state -> zero output");
        wait_samples(10);
        if (level_out == 16'd0) begin
            $display("  PASS: level = 0 in idle");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: level = %d in idle (expected 0)", level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 2: Attack phase - level increases ----
        $display("TEST 2: Attack phase -> level increases");
        gate = 1;
        wait_samples(5);  // Let attack start
        prev_level = level_out;
        wait_samples(10);

        if (level_out > prev_level) begin
            $display("  PASS: level increased %d -> %d during attack", prev_level, level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: level did not increase: %d -> %d", prev_level, level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 3: Attack reaches maximum ----
        $display("TEST 3: Attack reaches maximum");
        wait_samples(120);  // Well past attack time
        if (level_out > 16'd60000) begin
            $display("  PASS: level reached near-max = %d", level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: level = %d after full attack (expected >60000)", level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 4: Decay to sustain level ----
        $display("TEST 4: Decay settles to sustain level");
        wait_samples(300);  // Wait for decay to complete
        // Sustain level = 50% of 2^24 = 8388608, top 16 bits = 32768
        if (level_out >= 16'd32000 && level_out <= 16'd33500) begin
            $display("  PASS: sustain level = %d (~50%%)", level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: sustain level = %d (expected ~32768)", level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 5: Sustain holds steady ----
        $display("TEST 5: Sustain holds steady");
        prev_level = level_out;
        wait_samples(50);
        if (level_out == prev_level) begin
            $display("  PASS: sustain held at %d", level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: sustain drifted %d -> %d", prev_level, level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 6: Release phase - level decreases ----
        $display("TEST 6: Release phase -> level decreases");
        gate = 0;
        wait_samples(5);
        prev_level = level_out;
        wait_samples(20);

        if (level_out < prev_level) begin
            $display("  PASS: level decreased %d -> %d during release", prev_level, level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: level did not decrease: %d -> %d", prev_level, level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 7: Release reaches zero ----
        $display("TEST 7: Release reaches zero");
        wait_samples(150);
        if (level_out == 16'd0) begin
            $display("  PASS: level reached 0 after release");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: level = %d after release (expected 0)", level_out);
            fail_count = fail_count + 1;
        end

        // ---- Test 8: Re-trigger during release ----
        $display("TEST 8: Re-trigger during release");
        gate = 1;
        wait_samples(40);
        gate = 0;
        wait_samples(20);  // Partially through release
        prev_level = level_out;

        // Re-trigger
        gate = 1;
        wait_samples(20);
        if (level_out > prev_level) begin
            $display("  PASS: re-trigger increased level %d -> %d", prev_level, level_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: re-trigger did not increase: %d -> %d", prev_level, level_out);
            fail_count = fail_count + 1;
        end
        gate = 0;
        wait_samples(200);  // Let it fully release

        // ---- Summary ----
        $display("");
        $display("========================================");
        $display("fm_envelope: %0d PASSED, %0d FAILED", pass_count, fail_count);
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
        #200_000_000;  // 200ms
        $display("TIMEOUT: test took too long");
        $finish(1);
    end

endmodule
