/*
 *  PicoSoC - A simple example SoC using PicoRV32
 *
 *  Copyright (C) 2017  Clifford Wolf <clifford@clifford.at>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

 // October 2019, Matthias Koch: Renamed wires and optimizations.
 // December 2020, Bruno Levy: parameterization with freq and bauds
 //                            Factorized recv_divcnt and send_divcnt
 //                            Additional LUT golfing tricks

module buart #(
  parameter FREQ_MHZ = 12,
  parameter BAUDS    = 115200
) (
    input clk,
    input resetq,

    output tx,
    input  rx,

    input  wr,
    input  rd,
    input  [7:0] tx_data,
    output [7:0] rx_data,

    output busy,
    output valid
);

   /************** Baud frequency constants ******************/

    parameter divider = FREQ_MHZ * 1000000 / BAUDS;
    parameter divwidth = $clog2(divider);

    parameter baud_init = divider;
    parameter half_baud_init = divider/2+1;

   /************* Receiver with 16-byte FIFO ******************/

    reg [divwidth:0] recv_divcnt;
    wire recv_baud_clk = recv_divcnt[divwidth];

    reg recv_state;
    reg [8:0] recv_pattern;

    // 256-byte RX FIFO (must hold full XMODEM packet: 132 bytes)
    reg [7:0] rx_fifo [0:255];
    reg [7:0] rx_fifo_wr = 0;
    reg [7:0] rx_fifo_rd = 0;
    wire rx_fifo_empty = (rx_fifo_wr == rx_fifo_rd);
    wire [7:0] rx_fifo_next_wr = rx_fifo_wr + 1;
    wire rx_fifo_full = (rx_fifo_next_wr == rx_fifo_rd);

    assign rx_data = rx_fifo[rx_fifo_rd];
    assign valid = !rx_fifo_empty;

    // FIFO read: advance read pointer when CPU reads
    always @(posedge clk) begin
       if (!resetq) begin
          rx_fifo_rd <= 0;
       end else if (rd && !rx_fifo_empty) begin
          rx_fifo_rd <= rx_fifo_rd + 1;
       end
    end

    // Receiver shift register + FIFO write
    always @(posedge clk) begin
       if (!resetq) begin
          recv_state <= 0;
          recv_pattern <= 0;
          rx_fifo_wr <= 0;
       end else begin
          case (recv_state)
            0: begin
                  if (!rx) begin
                    recv_state <= 1;
                    /* verilator lint_off WIDTH */
                    recv_divcnt <= half_baud_init;
                    /* verilator lint_on WIDTH */
                  end
                  recv_pattern <= 0;
               end

            1: begin
                  if (recv_baud_clk) begin
                    if (recv_pattern[0]) begin
                      // Byte complete - push to FIFO if not full
                      if (!rx_fifo_full) begin
                         rx_fifo[rx_fifo_wr] <= ~recv_pattern[8:1];
                         rx_fifo_wr <= rx_fifo_next_wr;
                      end
                      recv_state <= 0;
                    end else begin
                      recv_pattern <= {~rx, recv_pattern[8:1]};
                      /* verilator lint_off WIDTH */
                      recv_divcnt <= baud_init;
                      /* verilator lint_on WIDTH */
                    end
                  end else recv_divcnt <= recv_divcnt - 1;
               end
          endcase
       end
    end

   /************* Transmitter ******************************/
    // Modified: added TX holding register so writes during busy are
    // buffered instead of corrupting the shift register mid-transmission.

    reg [divwidth:0] send_divcnt;
    wire send_baud_clk  = send_divcnt[divwidth];

    reg [9:0] send_pattern = 1;
    assign tx = send_pattern[0];

    wire shifting = |send_pattern[9:1];

    // TX holding register: buffers next byte while shift register is busy
    reg [7:0] tx_hold;
    reg       tx_hold_full = 0;

    // busy = shift register active OR holding register full
    // (tells software it can't accept another byte yet)
    assign busy = shifting | tx_hold_full;

    always @(posedge clk) begin
       // If shift register is idle and holding register has data, load it
       if (!shifting && tx_hold_full) begin
          send_pattern <= {1'b1, tx_hold[7:0], 1'b0};
          tx_hold_full <= 0;
          send_divcnt <= baud_init;
       end
       // CPU write: if shift register is idle, load directly; otherwise buffer
       else if (wr) begin
          if (!shifting) begin
             send_pattern <= {1'b1, tx_data[7:0], 1'b0};
             /* verilator lint_off WIDTH */
             send_divcnt <= baud_init;
             /* verilator lint_on WIDTH */
          end else begin
             tx_hold <= tx_data;
             tx_hold_full <= 1;
          end
       end
       // Normal shifting
       else if (send_baud_clk & shifting) begin
          send_pattern <= send_pattern >> 1;
          /* verilator lint_off WIDTH */
          send_divcnt <= baud_init;
          /* verilator lint_on WIDTH */
       end
       else begin
          send_divcnt <= send_divcnt - 1;
       end
    end

endmodule


