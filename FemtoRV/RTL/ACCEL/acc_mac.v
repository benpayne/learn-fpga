// acc_mac.v -- int8 MAC lanes + int32 accumulator + per-group rescale
//
// See FemtoRV/RTL/ACCEL/DESIGN.md section 3 (block diagram, section 3.2) and
// section 3.4 (why int8, why the rescale is a product of two scales).
// Reference format: Q8_0 (specs/004-int8-matmul-accel/data-model.md entities 2/3).
//
// Role: consumes LANES int8 weight elements and LANES int8 activation
// elements per cycle (as delivered by acc_weight_fetch's FIFO and the
// resident activation BRAM), accumulates an int32 dot product per scale
// group of `gs` elements, and on group completion rescales that raw int32
// sum into the running fp32 row accumulator by the PRODUCT of the weight
// group's scale and the activation group's scale (data-model.md entity 3,
// "Rules": w->s[g] * x->s[g]; research R2). When the row's last group is
// consumed, the fp32 accumulator is the row's output value.
//
// Multiplies MUST be written behaviourally so yosys infers ECP5 MULT18X18D
// (or generic $mul) rather than hand-instantiated DSP primitives
// (constitution "Portability and inference"; DESIGN.md research R6).
//
// TODO(T028): finalize this port list against acc_weight_fetch/acc_top as
// those skeletons settle; this is the first pass per T001.
// TODO(T030): implement the lane multiply/accumulate, group rescale, and
// row accumulation. Cover saturation and sign cases (DESIGN.md Stage 0
// exit criterion).

module acc_mac #(
    parameter LANES      = 4,   // parallel int8 MAC lanes. Default 4 = 32-bit SDRAM word / 8-bit
                                 // element (DESIGN.md sec 3.4/4.2: "lanes = bytes/cycle / bytes/weight").
    parameter ELEM_WIDTH  = 8,  // width of one weight/activation element, signed. int8 default;
                                 // MUST remain a parameter so a 16-bit fallback (FR-011, DESIGN.md
                                 // sec 3.5 "format-parameterised") needs no redesign.
    parameter ACC_WIDTH   = 32, // integer accumulator width per group (int32 for int8 x int8 x GS).
    parameter GS_WIDTH    = 16  // width of the runtime group-size field (data-model.md entity 4: `gs`
                                 // is a descriptor field read from the model header, not a constant).
) (
    input  wire                        clk,
    input  wire                        resetn,     // active-low, synchronous

    // Streaming operand inputs. One LANES-wide chunk of weight and activation
    // elements is consumed per asserted `in_valid` cycle. Element i of each
    // bus is signed [ELEM_WIDTH-1:0], packed LSB-first (element 0 in bits
    // [ELEM_WIDTH-1:0], element 1 in the next ELEM_WIDTH bits, ...).
    input  wire                        in_valid,   // pulse: w_data/x_data are valid this cycle
    input  wire [LANES*ELEM_WIDTH-1:0] w_data,     // LANES signed weight elements (from weight FIFO)
    input  wire [LANES*ELEM_WIDTH-1:0] x_data,     // LANES signed activation elements (from x BRAM)

    // Runtime group/row framing (data-model.md entity 4 "Operation Descriptor")
    input  wire [GS_WIDTH-1:0]         gs,         // elements per scale group (e.g. 64); n MUST be a
                                                    // whole multiple of gs -- enforced upstream (FR-009)
    input  wire                        group_start,// pulse: first valid cycle of a new group; clears
                                                    // the int32 accumulator
    input  wire                        row_start,  // pulse: first group of a new output row; clears
                                                    // the fp32 row accumulator

    // Per-group fp32 scales. MUST be valid by the cycle `group_done` pulses;
    // acc_top is responsible for presenting the group currently completing
    // (weight scale from the prefetched scale BRAM, activation scale from
    // the quantized activation vector -- data-model.md entities 2/3).
    input  wire [31:0]                 w_scale,    // weight group scale, fp32
    input  wire [31:0]                 x_scale,    // activation group scale, fp32

    // Group completion: raw (pre-rescale) int32 dot product for the group
    // that just finished, valid for one cycle on `group_done`.
    output wire                        group_done,
    output wire signed [ACC_WIDTH-1:0] group_acc,

    // Row completion: rescaled, accumulated fp32 result for one output row,
    // valid for one cycle on `row_valid` (data-model.md entity 6, Result Buffer).
    output wire                        row_valid,
    output wire [31:0]                 row_result
);

    // TODO(T030): lane multiply-accumulate array (LANES x signed multiply,
    // ELEM_WIDTH x ELEM_WIDTH -> 2*ELEM_WIDTH, summed into ACC_WIDTH), group
    // counter driven by `gs`, per-group rescale multiply (w_scale * x_scale
    // * group_acc), and fp32 accumulation into the row result. No logic yet
    // per T001 -- port list and parameters only.

endmodule
