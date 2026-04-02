// audio_ringbuf.v — Sampled audio ring buffer with half-buffer interrupt
//
// 1024 x 16-bit BRAM ring buffer (1 DP16KD block)
// Hardware reads at sample rate, CPU fills via IO writes
// Interrupt fires when read pointer crosses each half-boundary
//
// CPU write protocol (shares IO_SYNTH_bit, wdata[31]=1 selects this module):
//   wdata[31]=1, [30:29]=00: Set write pointer (wdata[9:0] = address)
//   wdata[31]=1, [30:29]=01: Write sample at write pointer, auto-increment
//                             wdata[15:0] = signed 16-bit sample
//   wdata[31]=1, [30:29]=10: Control register
//                             wdata[0] = enable playback
//                             wdata[1] = reset read pointer
//                             wdata[4:2] = volume shift (0=full, 1=-6dB, ...)

module audio_ringbuf (
    input  wire        clk,
    input  wire        reset,
    // CPU write interface
    input  wire [31:0] wdata,
    input  wire        wr_en,       // sel & wstrb & wdata[31]
    // CPU read interface
    input  wire        rd_en,       // sel & rstrb (unused, rdata always driven)
    output wire [31:0] rdata,
    // Audio interface
    input  wire        sample_tick, // 48kHz strobe from FM engine
    output reg signed [15:0] pcm_out,
    output reg         half_irq     // pulse when read ptr crosses half
);

    // ---- BRAM: 1024 x 16-bit ----
    reg signed [15:0] buffer [0:1023];

    // ---- State ----
    reg [9:0]  wr_ptr;
    reg [9:0]  rd_ptr;
    reg        enabled;
    reg [2:0]  vol_shift;
    reg        rd_ptr_msb_prev;  // For half-crossing detection

    // ---- Read data (status) ----
    assign rdata = {8'hAB, 8'b0, wr_ptr[9], vol_shift, rd_ptr_msb_prev, rd_ptr, enabled};

    // ---- Single always block for all state ----
    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            enabled <= 0;
            vol_shift <= 0;
            half_irq <= 0;
            pcm_out <= 0;
            rd_ptr_msb_prev <= 0;
        end else begin
            half_irq <= 0;  // Default: no interrupt

            // ---- CPU write port ----
            if (wr_en) begin
                case (wdata[30:29])
                    2'b00: begin
                        // Set write pointer
                        wr_ptr <= wdata[9:0];
                    end
                    2'b01: begin
                        // Write sample at write pointer, auto-increment
                        buffer[wr_ptr] <= wdata[15:0];
                        wr_ptr <= wr_ptr + 1;
                    end
                    2'b10: begin
                        // Control register
                        enabled <= wdata[0];
                        if (wdata[1])
                            rd_ptr <= 0;
                        vol_shift <= wdata[4:2];
                    end
                    default: ;
                endcase
            end

            // ---- Hardware read port (at sample rate) ----
            if (sample_tick && enabled) begin
                // Read sample from buffer and apply volume
                pcm_out <= buffer[rd_ptr] >>> vol_shift;

                // Advance read pointer
                rd_ptr_msb_prev <= rd_ptr[9];
                rd_ptr <= rd_ptr + 1;

                // Detect half-boundary crossing (bit 9 changed)
                if (rd_ptr[9] != rd_ptr_msb_prev)
                    half_irq <= 1;
            end
        end
    end

endmodule
