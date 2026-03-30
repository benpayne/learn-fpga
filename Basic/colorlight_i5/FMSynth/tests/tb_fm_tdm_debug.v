`timescale 1ns/1ps
module tb_fm_tdm_debug;
    reg clk = 0;
    always #20 clk = ~clk;

    wire signed [15:0] pcm_out;
    wire sample_valid;

    fm_synth_tdm #(.CLK_FREQ(25_000_000), .SAMPLE_RATE(48_000)) dut (
        .clk(clk), .reset(1'b0), .voice_gate(4'b0001),
        .voice_phase_inc_0(32'h016534C3),  // C4
        .voice_phase_inc_1(32'h0),
        .voice_phase_inc_2(32'h0),
        .voice_phase_inc_3(32'h0),
        .voice_algorithm(3'd0),  // Serial chain
        // OP4: modulator, 14x ratio, depth 3000
        .op_ratio_0(16'h0100), .op_ratio_1(16'h0100),
        .op_ratio_2(16'h0200), .op_ratio_3(16'h0E00),
        .op_depth_0(16'd0),    .op_depth_1(16'd2048),
        .op_depth_2(16'd2000), .op_depth_3(16'd3000),
        .op_attack_0(24'd69905), .op_attack_1(24'd69905),
        .op_attack_2(24'd69905), .op_attack_3(24'd69905),
        .op_decay_0(24'd1748), .op_decay_1(24'd1748),
        .op_decay_2(24'd699),  .op_decay_3(24'd349),
        .op_sustain_0(24'd13421773), .op_sustain_1(24'd6710886),
        .op_sustain_2(24'd5033165), .op_sustain_3(24'd3355443),
        .op_release_0(24'd3495), .op_release_1(24'd3495),
        .op_release_2(24'd3495), .op_release_3(24'd3495),
        .pcm_out(pcm_out), .sample_valid(sample_valid)
    );

    // Track slot processing for voice 0 only (first 4 slots per sample)
    integer sample_num = 0;
    reg [4:0] prev_op_idx = 0;

    always @(posedge clk) begin
        if (sample_valid) begin
            $display("=== SAMPLE %0d: pcm=%0d ===", sample_num, pcm_out);
            sample_num <= sample_num + 1;
            if (sample_num >= 10) $finish;
        end

        // Log key pipeline events for first 3 samples
        if (dut.processing && sample_num < 3) begin
            // State load
            if (dut.slot_cnt == 5'd0 && dut.op_idx < 4)
                $display("  [v%0d op%0d] LOAD: phase=%h env=%h efsm=%0d gate=%b gateprev=%b carrier=%b",
                    dut.voice_id, dut.op_id,
                    dut.state_phase[dut.op_idx], dut.state_env[dut.op_idx],
                    dut.state_env_fsm[dut.op_idx], dut.voice_gate[dut.voice_id],
                    dut.state_gate_prev[dut.op_idx], dut.alg_is_carrier);

            // After phase compute
            if (dut.slot_cnt == 5'd7 && dut.op_idx < 4)
                $display("  [v%0d op%0d] PHASE: new=%h freq_prod=%h op_phase_inc=%h",
                    dut.voice_id, dut.op_id,
                    dut.pipe_new_phase, dut.freq_product[39:8], dut.op_phase_inc);

            // After sine lookup
            if (dut.slot_cnt == 5'd10 && dut.op_idx < 4)
                $display("  [v%0d op%0d] SINE: val=%0d  ENV: level=%h fsm=%0d->%0d",
                    dut.voice_id, dut.op_id,
                    dut.pipe_sine_val, dut.pipe_env_level,
                    dut.pipe_env_fsm, dut.pipe_new_env_fsm);

            // After multiply
            if (dut.slot_cnt == 5'd16 && dut.op_idx < 4)
                $display("  [v%0d op%0d] SCALED: %0d  mul_result=%h",
                    dut.voice_id, dut.op_id,
                    dut.pipe_scaled_output, dut.mul_result);

            // After store
            if (dut.slot_cnt == 5'd18 && dut.op_idx < 4)
                $display("  [v%0d op%0d] STORED: carrier_sum=%0d",
                    dut.voice_id, dut.op_id,
                    dut.voice_carrier_sum[dut.voice_id]);
        end
    end

    initial begin
        #1000000;
        $display("TIMEOUT - only got %0d samples", sample_num);
        $finish;
    end
endmodule
