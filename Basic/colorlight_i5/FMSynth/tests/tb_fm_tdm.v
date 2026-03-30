`timescale 1ns/1ps
module tb_fm_tdm;
    reg clk = 0;
    always #20 clk = ~clk;  // 25MHz

    wire signed [15:0] pcm_out;
    wire sample_valid;

    fm_synth_tdm #(
        .CLK_FREQ(25_000_000),
        .SAMPLE_RATE(48_000)
    ) dut (
        .clk(clk),
        .reset(1'b0),
        .voice_gate(4'b0001),  // Voice 0 on
        .voice_phase_inc_0(32'h016534C3),  // C4
        .voice_phase_inc_1(32'h0),
        .voice_phase_inc_2(32'h0),
        .voice_phase_inc_3(32'h0),
        .voice_algorithm(3'd6),  // All carriers
        // All ops: 1x ratio, no mod, fast attack, high sustain
        .op_ratio_0(16'h0100), .op_ratio_1(16'h0100),
        .op_ratio_2(16'h0100), .op_ratio_3(16'h0100),
        .op_depth_0(16'd0), .op_depth_1(16'd0),
        .op_depth_2(16'd0), .op_depth_3(16'd0),
        .op_attack_0(24'd279620), .op_attack_1(24'd279620),
        .op_attack_2(24'd279620), .op_attack_3(24'd279620),
        .op_decay_0(24'd6990), .op_decay_1(24'd6990),
        .op_decay_2(24'd6990), .op_decay_3(24'd6990),
        .op_sustain_0(24'd13421773), .op_sustain_1(24'd13421773),
        .op_sustain_2(24'd13421773), .op_sustain_3(24'd13421773),
        .op_release_0(24'd6990), .op_release_1(24'd6990),
        .op_release_2(24'd6990), .op_release_3(24'd6990),
        .pcm_out(pcm_out),
        .sample_valid(sample_valid)
    );

    integer sample_count = 0;

    always @(posedge clk) begin
        if (sample_valid) begin
            sample_count <= sample_count + 1;
            $display("Sample %0d: pcm=%0d (0x%04h)", sample_count, pcm_out, pcm_out);
            if (sample_count >= 20) $finish;
        end
    end

    // Also monitor pipeline internals
    initial begin
        // Wait a few samples then dump state
        #100000;  // ~5000 clocks = ~9 samples
        $display("--- Internal state after 5000 clocks ---");
        $display("master_cnt=%0d op_idx=%0d slot_cnt=%0d",
                 dut.master_cnt, dut.op_idx, dut.slot_cnt);
        $display("voice_gate=%b", dut.voice_gate);
        $display("state_phase[0]=%h state_env[0]=%h state_env_fsm[0]=%0d",
                 dut.state_phase[0], dut.state_env[0], dut.state_env_fsm[0]);
        $display("state_phase[1]=%h state_env[1]=%h state_env_fsm[1]=%0d",
                 dut.state_phase[1], dut.state_env[1], dut.state_env_fsm[1]);
        $display("voice_carrier_sum[0]=%0d", dut.voice_carrier_sum[0]);
        $display("pipe_sine_val=%0d pipe_scaled_output=%0d",
                 dut.pipe_sine_val, dut.pipe_scaled_output);
    end

    initial begin
        $dumpfile("tb_fm_tdm.vcd");
        $dumpvars(0, tb_fm_tdm);
        #2000000;  // 100000 clocks
        $display("TIMEOUT");
        $finish;
    end
endmodule
