// FM Synth Register Interface for FemtoRV SoC
// Single 1-hot IO, reg index in wdata[12:8], value in wdata[7:0]

module fm_synth_registers (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] wdata,
    input  wire        wstrb,
    input  wire        sel,

    output reg  [3:0]  voice_gate,
    output reg  [6:0]  voice_note_0, voice_note_1, voice_note_2, voice_note_3,
    output reg  [2:0]  voice_preset_0, voice_preset_1, voice_preset_2, voice_preset_3,
    output reg  [3:0]  voice_trigger
);

    reg [1:0] cur_voice;
    reg [2:0] cur_preset;
    reg [7:0] cur_velocity;

    localparam REG_VOICE_SEL = 5'h00, REG_NOTE_ON = 5'h01, REG_NOTE_OFF = 5'h02;
    localparam REG_PRESET = 5'h03, REG_VELOCITY = 5'h04, REG_ALL_OFF = 5'h05;

    wire io_write = sel & wstrb;
    wire [4:0] reg_addr = wdata[12:8];
    wire [7:0] reg_data = wdata[7:0];

    always @(posedge clk) begin
        if (reset) begin
            cur_voice <= 0; cur_preset <= 0; cur_velocity <= 8'd200;
            voice_gate <= 0; voice_trigger <= 0;
            voice_note_0 <= 60; voice_note_1 <= 60; voice_note_2 <= 60; voice_note_3 <= 60;
            voice_preset_0 <= 0; voice_preset_1 <= 0; voice_preset_2 <= 0; voice_preset_3 <= 0;
        end else begin
            voice_trigger <= 0;
            if (io_write) begin
                case (reg_addr)
                    REG_VOICE_SEL: cur_voice <= reg_data[1:0];
                    REG_PRESET:    cur_preset <= reg_data[2:0];
                    REG_VELOCITY:  cur_velocity <= reg_data;
                    REG_ALL_OFF:   voice_gate <= 4'b0;
                    REG_NOTE_ON: begin
                        voice_gate[cur_voice] <= 1'b1;
                        voice_trigger[cur_voice] <= 1'b1;
                        case (cur_voice)
                            2'd0: begin voice_note_0 <= reg_data[6:0]; voice_preset_0 <= cur_preset; end
                            2'd1: begin voice_note_1 <= reg_data[6:0]; voice_preset_1 <= cur_preset; end
                            2'd2: begin voice_note_2 <= reg_data[6:0]; voice_preset_2 <= cur_preset; end
                            2'd3: begin voice_note_3 <= reg_data[6:0]; voice_preset_3 <= cur_preset; end
                        endcase
                    end
                    REG_NOTE_OFF: voice_gate[cur_voice] <= 1'b0;
                    default: ;
                endcase
            end
        end
    end

    initial begin
        cur_voice = 0; cur_preset = 0; cur_velocity = 8'd200;
        voice_gate = 0; voice_trigger = 0;
        voice_note_0 = 60; voice_note_1 = 60; voice_note_2 = 60; voice_note_3 = 60;
        voice_preset_0 = 0; voice_preset_1 = 0; voice_preset_2 = 0; voice_preset_3 = 0;
    end
endmodule
