// gpu_scanline_renderer.v — Hi-res scanline-based 8bpp renderer
//
// Double-buffered 640-byte scanline buffer for 640x400@8bpp display.
// CPU fills the inactive buffer via IO writes while GPU reads the active one.
// Buffers auto-swap at each HBlank.
// 256-entry RGB444 palette maps 8-bit pixel values to 12-bit color.
//
// All logic runs in clk_pixel domain (same freq as clk_cpu = 25MHz).

module gpu_scanline_renderer (
    input  wire        clk_pixel,
    input  wire        clk_cpu,        // Unused — everything runs on clk_pixel
    input  wire        rst_n,

    // VGA timing
    input  wire [9:0]  h_count,
    input  wire [9:0]  v_count,
    input  wire        video_active,

    // CPU register interface (active in clk_pixel domain since same freq)
    input  wire [3:0]  reg_addr,
    input  wire [7:0]  reg_data_in,
    input  wire        reg_we,

    // RGB output (8-bit per channel)
    output wire [7:0]  rgb_r_out,
    output wire [7:0]  rgb_g_out,
    output wire [7:0]  rgb_b_out,

    // Interrupt
    output reg         hblank_irq      // Pulse at start of each HBlank
);

    // ---- Parameters ----
    localparam H_VISIBLE = 640;
    localparam V_VISIBLE = 400;

    // Register addresses
    localparam REG_SCANLINE_ADDR_LO = 4'hE;  // Write pointer low byte
    localparam REG_SCANLINE_ADDR_HI = 4'hD;  // Write pointer high bits (unused for now)
    localparam REG_SCANLINE_DATA    = 4'hF;  // Write pixel, auto-increment

    // ---- Double-buffered scanline BRAM (2 x 640 bytes) ----
    reg [7:0] line_buf [0:1279];

    // Active buffer: GPU reads from this one, CPU writes to the other
    reg active_buf;  // 0 = GPU reads buf 0, CPU writes buf 1

    // ---- CPU write state ----
    reg [9:0] wr_ptr;

    // ---- 256-entry RGB444 palette ----
    reg [3:0] palette_r [0:255];
    reg [3:0] palette_g [0:255];
    reg [3:0] palette_b [0:255];

    // Initialize palette to default 332 mapping + CGA first 16
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            palette_r[i] = {i[7:5], 1'b0};
            palette_g[i] = {i[4:2], 1'b0};
            palette_b[i] = {i[1:0], 2'b00};
        end
        palette_r[0]=4'h0; palette_g[0]=4'h0; palette_b[0]=4'h0;
        palette_r[1]=4'h0; palette_g[1]=4'h0; palette_b[1]=4'hA;
        palette_r[2]=4'h0; palette_g[2]=4'hA; palette_b[2]=4'h0;
        palette_r[3]=4'h0; palette_g[3]=4'hA; palette_b[3]=4'hA;
        palette_r[4]=4'hA; palette_g[4]=4'h0; palette_b[4]=4'h0;
        palette_r[5]=4'hA; palette_g[5]=4'h0; palette_b[5]=4'hA;
        palette_r[6]=4'hA; palette_g[6]=4'h5; palette_b[6]=4'h0;
        palette_r[7]=4'hA; palette_g[7]=4'hA; palette_b[7]=4'hA;
        palette_r[8]=4'h5; palette_g[8]=4'h5; palette_b[8]=4'h5;
        palette_r[9]=4'h5; palette_g[9]=4'h5; palette_b[9]=4'hF;
        palette_r[10]=4'h5; palette_g[10]=4'hF; palette_b[10]=4'h5;
        palette_r[11]=4'h5; palette_g[11]=4'hF; palette_b[11]=4'hF;
        palette_r[12]=4'hF; palette_g[12]=4'h5; palette_b[12]=4'h5;
        palette_r[13]=4'hF; palette_g[13]=4'h5; palette_b[13]=4'hF;
        palette_r[14]=4'hF; palette_g[14]=4'hF; palette_b[14]=4'h5;
        palette_r[15]=4'hF; palette_g[15]=4'hF; palette_b[15]=4'hF;
    end

    // ---- GPU read port ----
    reg [7:0] pixel_data;
    wire [10:0] read_addr = active_buf ? ({1'b1, h_count[9:0]}) : ({1'b0, h_count[9:0]});

    // ---- Palette lookup pipeline ----
    reg [3:0] pal_r, pal_g, pal_b;
    reg       pixel_valid_d;

    // ---- HBlank detection ----
    reg was_active;

    // ---- Single always block (clk_pixel domain) ----
    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            active_buf <= 0;
            wr_ptr <= 0;
            hblank_irq <= 0;
            was_active <= 0;
            pixel_data <= 0;
            pal_r <= 0; pal_g <= 0; pal_b <= 0;
            pixel_valid_d <= 0;
        end else begin
            hblank_irq <= 0;

            // ---- CPU register writes ----
            if (reg_we) begin
                case (reg_addr)
                    REG_SCANLINE_ADDR_LO: wr_ptr[7:0] <= reg_data_in;
                    REG_SCANLINE_ADDR_HI: wr_ptr[9:8] <= reg_data_in[1:0];
                    REG_SCANLINE_DATA: begin
                        // Write to inactive buffer, auto-increment
                        if (active_buf == 0)
                            line_buf[{1'b1, wr_ptr}] <= reg_data_in;
                        else
                            line_buf[{1'b0, wr_ptr}] <= reg_data_in;
                        wr_ptr <= (wr_ptr < 639) ? wr_ptr + 1 : wr_ptr;
                    end
                    default: ;
                endcase
            end

            // ---- Pixel read from active buffer (pipeline stage 1) ----
            if (h_count < H_VISIBLE && v_count < V_VISIBLE)
                pixel_data <= line_buf[read_addr];
            else
                pixel_data <= 8'd0;

            // ---- Palette lookup (pipeline stage 2) ----
            pal_r <= palette_r[pixel_data];
            pal_g <= palette_g[pixel_data];
            pal_b <= palette_b[pixel_data];
            pixel_valid_d <= (v_count < V_VISIBLE);

            // ---- Buffer swap at HBlank ----
            was_active <= (h_count < H_VISIBLE) && (v_count < V_VISIBLE);
            if (was_active && !(h_count < H_VISIBLE)) begin
                if (v_count < V_VISIBLE) begin
                    active_buf <= ~active_buf;
                    wr_ptr <= 0;
                    hblank_irq <= 1;
                end
            end
        end
    end

    // Expand 4-bit to 8-bit color
    assign rgb_r_out = pixel_valid_d ? {pal_r, pal_r} : 8'd0;
    assign rgb_g_out = pixel_valid_d ? {pal_g, pal_g} : 8'd0;
    assign rgb_b_out = pixel_valid_d ? {pal_b, pal_b} : 8'd0;

endmodule
