// Minimal board test for Colorlight i5
// Blinks 4 LEDs (active-low), counts on 7-segment, sends "Hello!" on UART

module board_test(
    input  wire pclk,
    output wire D1, D2, D3, D4,
    output wire D5, D6, D7, D8,
    output wire TXD,
    output wire seg_a, seg_b, seg_c, seg_d, seg_e, seg_f, seg_g,
    output wire seg_select
);

    // ========== Counter ==========
    reg [25:0] counter = 0;
    always @(posedge pclk) begin
        counter <= counter + 1;
    end

    // ========== 8-bit value counting 0x00 to 0xFF ==========
    // 25_000_000 / 2 = 12_500_000 -> need ~24 bits, use counter[23] as tick
    // counter[23] toggles at ~3 Hz, divide further: use a separate slow counter
    reg [23:0] prescaler = 0;
    reg [7:0] value = 0;
    always @(posedge pclk) begin
        prescaler <= prescaler + 1;
        if (prescaler == 12_500_000 - 1) begin // 2 Hz
            prescaler <= 0;
            value <= value + 1;
        end
    end

    // ========== 8 LEDs (active-low) ==========
    // D1 is rightmost on board, D8 is leftmost
    // Map so D8=MSB(bit7), D1=LSB(bit0)
    assign D8 = ~value[7];
    assign D7 = ~value[6];
    assign D6 = ~value[5];
    assign D5 = ~value[4];
    assign D4 = ~value[3];
    assign D3 = ~value[2];
    assign D2 = ~value[1];
    assign D1 = ~value[0];

    // ========== 7-Segment Display (active-low, multiplexed) ==========
    wire mux_sel = counter[16]; // ~380 Hz multiplex rate
    assign seg_select = mux_sel;

    // seg_select=1 (right digit) = low nibble, seg_select=0 (left digit) = high nibble
    wire [3:0] digit = mux_sel ? value[3:0] : value[7:4];

    reg [6:0] seg_pattern;
    always @(*) begin
        case (digit)
            //                abcdefg
            4'h0: seg_pattern = 7'b1111110;
            4'h1: seg_pattern = 7'b0110000;
            4'h2: seg_pattern = 7'b1101101;
            4'h3: seg_pattern = 7'b1111001;
            4'h4: seg_pattern = 7'b0110011;
            4'h5: seg_pattern = 7'b1011011;
            4'h6: seg_pattern = 7'b1011111;
            4'h7: seg_pattern = 7'b1110000;
            4'h8: seg_pattern = 7'b1111111;
            4'h9: seg_pattern = 7'b1111011;
            4'hA: seg_pattern = 7'b1110111;
            4'hB: seg_pattern = 7'b0011111;
            4'hC: seg_pattern = 7'b1001110;
            4'hD: seg_pattern = 7'b0111101;
            4'hE: seg_pattern = 7'b1001111;
            4'hF: seg_pattern = 7'b1000111;
        endcase
    end

    // Invert for active-low segments
    assign {seg_a, seg_b, seg_c, seg_d, seg_e, seg_f, seg_g} = ~seg_pattern;

    // ========== UART TX (115200 baud at 25 MHz) ==========
    localparam BAUD_DIV = 217;  // 25_000_000 / 115200
    localparam MSG_LEN = 9;

    reg [7:0] message [0:MSG_LEN-1];
    initial begin
        message[0] = "H";
        message[1] = "e";
        message[2] = "l";
        message[3] = "l";
        message[4] = "o";
        message[5] = "!";
        message[6] = "\r";
        message[7] = "\n";
        message[8] = 0;
    end

    reg [15:0] baud_counter = 0;
    reg [3:0]  bit_index = 0;
    reg [3:0]  msg_index = 0;
    reg [25:0] repeat_timer = 0;
    reg        tx_reg = 1;       // idle high
    reg [1:0]  state = 0;

    assign TXD = tx_reg;

    always @(posedge pclk) begin
        case (state)
            0: begin
                if (baud_counter == 0) begin
                    baud_counter <= BAUD_DIV - 1;
                    case (bit_index)
                        0: begin
                            tx_reg <= 0;
                            bit_index <= 1;
                        end
                        1,2,3,4,5,6,7,8: begin
                            tx_reg <= message[msg_index][bit_index - 1];
                            bit_index <= bit_index + 1;
                        end
                        9: begin
                            tx_reg <= 1;
                            bit_index <= 0;
                            if (msg_index == MSG_LEN - 1) begin
                                msg_index <= 0;
                                state <= 1;
                                repeat_timer <= 0;
                            end else begin
                                msg_index <= msg_index + 1;
                            end
                        end
                        default: bit_index <= 0;
                    endcase
                end else begin
                    baud_counter <= baud_counter - 1;
                end
            end
            1: begin
                repeat_timer <= repeat_timer + 1;
                if (repeat_timer[24]) begin
                    state <= 0;
                    repeat_timer <= 0;
                end
            end
        endcase
    end

endmodule
