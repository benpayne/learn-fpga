// FM Algorithm Routing for 4-operator FM synthesis
//
// 8 algorithms define how operators connect:
//   0: OP4->OP3->OP2->OP1*           (serial chain, 1 carrier)
//   1: (OP3+OP4)->OP2->OP1*          (2 mods sum, 1 carrier)
//   2: OP4->OP3->OP2* + OP1*         (2 carriers, OP1 unmodulated)
//   3: OP4->OP3* + OP2->OP1*         (2 parallel pairs)
//   4: OP4->OP3* + OP4->OP2* + OP1*  (1 mod, 3 carriers, OP1 free)
//   5: OP4->OP3* + OP2* + OP1*       (1 mod chain, 3 carriers)
//   6: OP4* + OP3* + OP2* + OP1*     (additive, 4 carriers)
//   7: OP4->OP3->OP2->OP1* (feedback on OP4) (serial + feedback)
//
// Operators processed in order: OP4(3), OP3(2), OP2(1), OP1(0)
// * = carrier (contributes to voice output)

module fm_algorithm (
    input  wire [2:0]  algorithm,
    input  wire [1:0]  op_id,           // Current operator (3=OP4, 2=OP3, 1=OP2, 0=OP1)
    input  wire signed [15:0] op4_out,  // Stored OP4 output
    input  wire signed [15:0] op3_out,  // Stored OP3 output
    input  wire signed [15:0] op2_out,  // Stored OP2 output
    output reg  signed [15:0] mod_input,// Modulation input for current op
    output reg                is_carrier // 1 if current op is a carrier
);

    always @(*) begin
        mod_input = 16'sd0;
        is_carrier = 1'b0;

        case (algorithm)
            3'd0: begin // OP4->OP3->OP2->OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end // OP4: no mod
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b0; end // OP3: mod by OP4
                    2'd1: begin mod_input = op3_out;   is_carrier = 1'b0; end // OP2: mod by OP3
                    2'd0: begin mod_input = op2_out;   is_carrier = 1'b1; end // OP1: mod by OP2, carrier
                endcase
            end
            3'd1: begin // (OP3+OP4)->OP2->OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = 16'sd0;   is_carrier = 1'b0; end // OP3: no mod
                    2'd1: begin mod_input = op3_out + op4_out; is_carrier = 1'b0; end // OP2: sum
                    2'd0: begin mod_input = op2_out;   is_carrier = 1'b1; end
                endcase
            end
            3'd2: begin // OP4->OP3->OP2* + OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b0; end
                    2'd1: begin mod_input = op3_out;   is_carrier = 1'b1; end // OP2: carrier
                    2'd0: begin mod_input = 16'sd0;   is_carrier = 1'b1; end // OP1: free carrier
                endcase
            end
            3'd3: begin // OP4->OP3* + OP2->OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b1; end // OP3: carrier
                    2'd1: begin mod_input = 16'sd0;   is_carrier = 1'b0; end // OP2: no mod
                    2'd0: begin mod_input = op2_out;   is_carrier = 1'b1; end // OP1: carrier
                endcase
            end
            3'd4: begin // OP4->OP3* + OP4->OP2* + OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b1; end
                    2'd1: begin mod_input = op4_out;   is_carrier = 1'b1; end
                    2'd0: begin mod_input = 16'sd0;   is_carrier = 1'b1; end
                endcase
            end
            3'd5: begin // OP4->OP3* + OP2* + OP1*
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b1; end
                    2'd1: begin mod_input = 16'sd0;   is_carrier = 1'b1; end
                    2'd0: begin mod_input = 16'sd0;   is_carrier = 1'b1; end
                endcase
            end
            3'd6: begin // OP4* + OP3* + OP2* + OP1* (additive)
                mod_input = 16'sd0;
                is_carrier = 1'b1;
            end
            3'd7: begin // Same as 0 but OP4 has feedback (handled externally)
                case (op_id)
                    2'd3: begin mod_input = 16'sd0;   is_carrier = 1'b0; end
                    2'd2: begin mod_input = op4_out;   is_carrier = 1'b0; end
                    2'd1: begin mod_input = op3_out;   is_carrier = 1'b0; end
                    2'd0: begin mod_input = op2_out;   is_carrier = 1'b1; end
                endcase
            end
        endcase
    end
endmodule
