// I2S Transmitter for MAX98357A and similar I2S DAC/amplifier chips
//
// Generates standard I2S signals: BCLK, LRCK, DIN
// Accepts 16-bit signed PCM at sample_tick rate
//
// I2S format (Philips standard):
//   - LRCK: low = left channel, high = right channel
//   - LRCK transitions one BCLK before MSB
//   - Data is MSB-first, valid on rising edge of BCLK
//   - 32 BCLK cycles per channel (16 data + 16 padding)
//
// For 48kHz stereo: BCLK = 48000 * 64 = 3.072 MHz
// From 25MHz clock: divider = 25000000 / (3072000 * 2) ≈ 4
// Actual BCLK = 25MHz / 8 = 3.125 MHz (1.7% fast, within spec)
//
// The MAX98357A is mono — it uses LRCK to select left or right channel.
// Default (no channel select pin) plays left channel.
// We send the same data on both channels.

module i2s_tx #(
    parameter CLK_FREQ   = 25_000_000,
    parameter SAMPLE_RATE = 48_000,
    parameter BIT_DEPTH  = 16
)(
    input  wire        clk,          // System clock
    input  wire        reset,        // Synchronous reset
    input  wire signed [15:0] pcm_in, // 16-bit signed PCM sample
    input  wire        sample_valid, // Pulse when new sample ready

    output reg         bclk,        // I2S bit clock
    output reg         lrck,        // I2S left/right clock (word select)
    output reg         din          // I2S serial data (directly to MAX98357A)
);

    // BCLK divider: toggle bclk every N system clocks
    // BCLK freq = SAMPLE_RATE * 64 (32 bits per channel, 2 channels)
    // Half-period in system clocks = CLK_FREQ / (SAMPLE_RATE * 64 * 2)
    localparam BCLK_HALF = CLK_FREQ / (SAMPLE_RATE * 64 * 2);
    localparam BCLK_WIDTH = $clog2(BCLK_HALF + 1);

    reg [BCLK_WIDTH-1:0] bclk_cnt;
    wire bclk_edge = (bclk_cnt == BCLK_HALF - 1);

    // 6-bit counter: counts 0-63 within each stereo frame
    // 0-31 = left channel, 32-63 = right channel
    reg [5:0] bit_cnt;

    // Shift register for serial output
    reg [31:0] shift_reg;

    // Latch incoming sample
    reg signed [15:0] pcm_latched;
    always @(posedge clk) begin
        if (reset)
            pcm_latched <= 16'sd0;
        else if (sample_valid)
            pcm_latched <= pcm_in;
    end

    always @(posedge clk) begin
        if (reset) begin
            bclk_cnt  <= 0;
            bclk      <= 0;
            lrck      <= 0;
            din       <= 0;
            bit_cnt   <= 0;
            shift_reg <= 0;
        end else begin
            if (bclk_edge) begin
                bclk_cnt <= 0;
                bclk <= ~bclk;

                if (bclk) begin
                    // Falling edge of BCLK: advance bit counter, update data
                    bit_cnt <= bit_cnt + 1;

                    // LRCK transitions one bit before MSB of each channel
                    // bit_cnt 31 -> LRCK goes high (right channel next)
                    // bit_cnt 63 -> LRCK goes low (left channel next)
                    if (bit_cnt == 6'd31)
                        lrck <= 1'b1;
                    else if (bit_cnt == 6'd63)
                        lrck <= 1'b0;

                    // Load shift register at start of each channel
                    // Bit 0 of left channel, bit 32 of right channel
                    if (bit_cnt == 6'd63 || bit_cnt == 6'd31) begin
                        // 16-bit data in upper bits, zero-padded lower 16
                        shift_reg <= {pcm_latched, 16'h0000};
                    end else begin
                        shift_reg <= {shift_reg[30:0], 1'b0};
                    end

                    // Output MSB of shift register
                    din <= shift_reg[31];
                end
            end else begin
                bclk_cnt <= bclk_cnt + 1;
            end
        end
    end

endmodule
