/*
my_hdmi_device

Copyright (C) 2021  Hirosh Dabui <hirosh@dabui.de>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
*/

/*
 * TMDS encoder implementation based on DVI specification 1.0, Page 29
 * Adapted for retrocpu DVI Character Display GPU
 * 2025-12-28: Validated on Colorlight i5 v7.0
 *
 * TMDS (Transition-Minimized Differential Signaling) encoding:
 * - Converts 8-bit pixel data to 10-bit encoded data
 * - Two-stage process:
 *   1. Transition minimization (XOR or XNOR encoding)
 *   2. DC balance correction (disparity tracking)
 * - During blanking: encodes control signals (HSYNC, VSYNC)
 */

module tmds_encoder(
    input clk,
    input DE,               // Data Enable: 1=video data, 0=blanking
    input [7:0]D,           // 8-bit pixel data input
    input C1,               // Control bit 1 (VSYNC for blue channel)
    input C0,               // Control bit 0 (HSYNC for blue channel)
    output reg[9:0] q_out = 0  // 10-bit TMDS encoded output
);

parameter LEGACY_DVI_CONTROL_LUT = 0;

// Count number of zeros in 8-bit input
function [3:0] N0;
    input [7:0] d;
    integer i;
    begin
        N0 = 0;
        for (i = 0; i < 8; i = i +1)
            N0 = N0 + !d[i];
    end
endfunction

// Count number of ones in 8-bit input
function [3:0] N1;
    input [7:0] d;
    integer i;
    begin
        N1 = 0;
        for (i = 0; i < 8; i = i +1)
            N1 = N1 + d[i];
    end
endfunction

// Running disparity tracking for DC balance
reg signed [7:0] cnt_prev = 0;
reg signed [7:0] cnt = 0;

// Intermediate 9-bit value after transition minimization
reg [8:0] q_m;

// Stage 1: Transition minimization
// Choose XOR or XNOR encoding to minimize transitions
always @(*) begin

    if ( (N1(D) > 4) | (N1(D) == 4) & (D[0] == 0) ) begin
        // Use XNOR encoding (fewer transitions)
        q_m[0] =           D[0];
        q_m[1] = q_m[0] ~^ D[1];
        q_m[2] = q_m[1] ~^ D[2];
        q_m[3] = q_m[2] ~^ D[3];
        q_m[4] = q_m[3] ~^ D[4];
        q_m[5] = q_m[4] ~^ D[5];
        q_m[6] = q_m[5] ~^ D[6];
        q_m[7] = q_m[6] ~^ D[7];
        q_m[8] = 1'b0;  // Bit 8 indicates XNOR

    end else begin
        // Use XOR encoding
        q_m[0] =          D[0];
        q_m[1] = q_m[0] ^ D[1];
        q_m[2] = q_m[1] ^ D[2];
        q_m[3] = q_m[2] ^ D[3];
        q_m[4] = q_m[3] ^ D[4];
        q_m[5] = q_m[4] ^ D[5];
        q_m[6] = q_m[5] ^ D[6];
        q_m[7] = q_m[6] ^ D[7];
        q_m[8] = 1'b1;  // Bit 8 indicates XOR

    end

end

// Stage 2: DC balance and control symbol encoding
always @(posedge clk) begin

    if (DE) begin
        // Video data period: apply DC balance correction

        if ((cnt_prev == 0) | (N1(q_m[7:0]) == N0(q_m[7:0]))) begin
            // Equal number of 1s and 0s, or disparity is zero

            q_out[9]   <= ~q_m[8];
            q_out[8]   <=  q_m[8];
            q_out[7:0] <= q_m[8] ? q_m[7:0] : ~q_m[7:0];

            if (q_m[8] == 0) begin
                cnt = cnt_prev + (N0(q_m[7:0]) - N1(q_m[7:0]));
            end else begin
                cnt = cnt_prev + (N1(q_m[7:0]) - N0(q_m[7:0]));
            end

        end else begin
            // Disparity correction needed

            if ( (cnt_prev > 0 & (N1(q_m[7:0]) > N0(q_m[7:0]))) |
                    (cnt_prev < 0 & (N0(q_m[7:0]) > N1(q_m[7:0]))) ) begin
                q_out[9] <= 1;
                q_out[8] <= q_m[8];
                q_out[7:0] <= ~q_m[7:0];
                cnt = cnt_prev + 2*q_m[8] + (N0(q_m[7:0]) - N1(q_m[7:0]));
            end else begin
                q_out[9] <= 0;
                q_out[8] <= q_m[8];
                q_out[7:0] <= q_m[7:0];
                cnt = cnt_prev - {~q_m[8], 1'b0} + (N1(q_m[7:0]) - N0(q_m[7:0]));
            end

        end

    end else begin
        // Blanking period: output control symbols
        cnt = 0;  // Reset disparity during blanking

        // Encode HSYNC (C0) and VSYNC (C1) control signals
        case ({C1, C0})
`ifdef LEGACY_DVI_CONTROL_LUT
            // DVI 1.0 control data lookup table
            2'b00: q_out <= 10'b00101_01011;
            2'b01: q_out <= 10'b11010_10100;
            2'b10: q_out <= 10'b00101_01010;
            2'b11: q_out <= 10'b11010_10101;
`else
            // HDMI control data period (recommended)
            2'b00: q_out <= 10'b1101010100;
            2'b01: q_out <= 10'b0010101011;
            2'b10: q_out <= 10'b0101010100;
            2'b11: q_out <= 10'b1010101011;
`endif
        endcase

    end

    cnt_prev <= cnt;

end

endmodule
