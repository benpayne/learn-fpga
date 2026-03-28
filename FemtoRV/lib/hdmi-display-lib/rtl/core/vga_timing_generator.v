/*
VGA Timing Generator for 640x400@70Hz
retrocpu DVI Character Display GPU

Generates horizontal and vertical sync signals and timing counters
for VGA 640x400@70Hz (25.175 MHz pixel clock, using 25 MHz in practice)

Timing Parameters (from VESA standard):
- Horizontal: 640 visible + 16 front porch + 96 sync + 48 back porch = 800 total
- Vertical: 400 visible + 12 front porch + 2 sync + 35 back porch = 449 total
- Refresh rate: 70.087 Hz
- Pixel clock: 25.175 MHz (25 MHz acceptable)

Note: 640x400 allows simple 2x/4x line doubling for 200-line and 100-line graphics modes
without complex division, improving timing and eliminating multiplier usage.

Created: 2025-12-28
Updated: 2026-01-06 (switched to 640x400 for simpler scaling)
*/

module vga_timing_generator(
    input  wire        clk,           // Pixel clock (25 MHz)
    input  wire        rst_n,         // Active-low reset

    output reg  [9:0]  h_count,       // Horizontal counter (0-799)
    output reg  [9:0]  v_count,       // Vertical counter (0-524)

    output wire        hsync,         // Horizontal sync (active low, HPOL=0)
    output wire        vsync,         // Vertical sync (active high, VPOL=1)
    output wire        video_active,  // High during visible region
    output wire        frame_start    // Pulse at start of frame
);

//=============================================================================
// VGA 640x400@70Hz Timing Parameters
//=============================================================================

// Horizontal timing (in pixel clocks)
localparam H_VISIBLE    = 640;
localparam H_FRONT      = 16;
localparam H_SYNC       = 96;
localparam H_BACK       = 48;
localparam H_TOTAL      = H_VISIBLE + H_FRONT + H_SYNC + H_BACK; // 800

// Vertical timing (in lines) - 640x400@70Hz
localparam V_VISIBLE    = 400;  // 400 lines = 25 rows of 16-pixel chars
localparam V_FRONT      = 12;
localparam V_SYNC       = 2;
localparam V_BACK       = 35;
localparam V_TOTAL      = V_VISIBLE + V_FRONT + V_SYNC + V_BACK; // 449

// Sync pulse boundaries
localparam H_SYNC_START = H_VISIBLE + H_FRONT;                    // 656
localparam H_SYNC_END   = H_VISIBLE + H_FRONT + H_SYNC;           // 752
localparam V_SYNC_START = V_VISIBLE + V_FRONT;                    // 412
localparam V_SYNC_END   = V_VISIBLE + V_FRONT + V_SYNC;           // 414

//=============================================================================
// Counter Logic
//=============================================================================

// Horizontal counter: 0 to 799
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_count <= 0;
    end else begin
        if (h_count == H_TOTAL - 1) begin
            h_count <= 0;
        end else begin
            h_count <= h_count + 1;
        end
    end
end

// Vertical counter: 0 to 524, increments at end of each line
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        v_count <= 0;
    end else begin
        if (h_count == H_TOTAL - 1) begin
            if (v_count == V_TOTAL - 1) begin
                v_count <= 0;
            end else begin
                v_count <= v_count + 1;
            end
        end
    end
end

//=============================================================================
// Sync Signal Generation
//=============================================================================

// HSYNC: Active low during sync pulse (HPOL=0)
assign hsync = ~((h_count >= H_SYNC_START) && (h_count < H_SYNC_END));

// VSYNC: Active high during sync pulse (VPOL=1, required for 640x400@70Hz)
assign vsync = (v_count >= V_SYNC_START) && (v_count < V_SYNC_END);

//=============================================================================
// Control Signals
//=============================================================================

// Video active: High during visible region (both horizontal and vertical)
assign video_active = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);

// Frame start: Pulse at beginning of new frame (h=0, v=0)
assign frame_start = (h_count == 0) && (v_count == 0);

endmodule
