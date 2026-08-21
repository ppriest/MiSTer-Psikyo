// Raw video timing generator for the Phase 1 screen configuration --
// verified directly from psikyo.cpp's machine config, not assumed:
//   m_screen->set_raw(14.318181_MHz_XTAL/2, 456, 0, 320, 262, 0, 224);
// i.e. pixel clock ~7.159MHz, htotal=456 (active 0-319, blank 320-455),
// vtotal=262 (active 0-223, blank 224-261) -- identical across both Phase
// 1 boards (docs/phase1_memory_map.md, docs/phase1_video_engine.md).
//
// MAME's set_raw() only specifies the blanking BOUNDARIES it needs for its
// own rasterizer -- it doesn't drive a real CRT, so it has no opinion on
// actual hsync/vsync PULSE width/position within those blanking windows.
// Those are a genuine RTL-level design choice this doc is explicit about
// (not sourced from MAME): hsync is a 32-pixel-clock pulse starting 16
// pixel-clocks into hblank (a common front-porch/sync-width split for this
// class of MiSTer arcade core), vsync is a 3-line pulse starting 4 lines
// into vblank. Not claimed to match the original PCB's exact analog sync
// timing (unknowable without real hardware access, see ROADMAP.md's "no
// original Psikyo PCB" open item) -- MiSTer's own scandoubler/CRT_Offset
// framework is what actually adapts this to a real display, same as every
// other arcade core of this class.
//
// hcnt/vcnt are raw raster counters (not gated by ce_pix themselves --
// they only ADVANCE on ce_pix cycles, but hold their value the rest of the
// time, matching Template_MiSTer's existing ce_pix/CE_PIXEL convention).
// vcnt_active is the tilemap engines' expected 0-223 view (checked
// directly against tilemap_line_engine.sv's `input logic [7:0] vcnt` port
// -- garbage/frozen outside the active window is fine since h_active/
// line_start already gate when it's actually consumed).
//
// line_start fires at the very start of hblank (hcnt==320) -- giving the
// video engines' prefetch pipelines the full 136-pixel-clock hblank
// window as lead time before h_active next asserts, generous headroom
// against docs/phase1_video_engine.md's own "one scanline is only htotal
// pixel-clocks" time-budget concern.
//
// frame_start fires on vblank's RISING edge (vcnt going 223->224) --
// matches psikyo_v.cpp's own sprite-buffer swap trigger (screen_vblank(),
// psikyo_v.cpp:667-675, already noted in docs/phase1_memory_map.md), so
// this is the natural place for a future top-level to trigger
// sprite_frame_buffer's frame_swap and sprite_render_engine's frame_start.

module video_timing (
    input  logic clk,
    input  logic ce_pix,
    input  logic reset,

    output logic [8:0] hcnt,          // 0-455, raw raster column
    output logic [8:0] vcnt,          // 0-261, raw raster line
    output logic [7:0] vcnt_active,   // vcnt truncated to tilemap_line_engine's 0-223 port width

    output logic h_active,   // 1 while hcnt in [0,319]
    output logic v_active,   // 1 while vcnt in [0,223]
    output logic hblank,
    output logic vblank,
    output logic hsync,
    output logic vsync,

    output logic line_start,    // 1-cycle pulse (on a ce_pix cycle), hcnt==320
    output logic frame_start    // 1-cycle pulse (on a ce_pix cycle), vblank rising edge
);

    localparam int H_TOTAL   = 456;
    localparam int H_ACTIVE  = 320;
    localparam int H_SYNC_ST = 320 + 16;
    localparam int H_SYNC_EN = 320 + 16 + 32;

    localparam int V_TOTAL   = 262;
    localparam int V_ACTIVE  = 224;
    localparam int V_SYNC_ST = 224 + 4;
    localparam int V_SYNC_EN = 224 + 4 + 3;

    assign h_active = (hcnt < H_ACTIVE);
    assign v_active = (vcnt < V_ACTIVE);
    assign hblank   = ~h_active;
    assign vblank   = ~v_active;
    assign hsync    = (hcnt >= H_SYNC_ST) && (hcnt < H_SYNC_EN);
    assign vsync    = (vcnt >= V_SYNC_ST) && (vcnt < V_SYNC_EN);

    assign vcnt_active = vcnt[7:0];

    logic v_active_prev;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            hcnt          <= 9'd0;
            vcnt          <= 9'd0;
            line_start    <= 1'b0;
            frame_start   <= 1'b0;
            v_active_prev <= 1'b1;
        end else begin
            line_start  <= 1'b0;
            frame_start <= 1'b0;

            if (ce_pix) begin
                v_active_prev <= v_active;

                if (hcnt == H_TOTAL - 1) begin
                    hcnt <= 9'd0;
                    if (vcnt == V_TOTAL - 1) vcnt <= 9'd0;
                    else                       vcnt <= vcnt + 9'd1;
                end else begin
                    hcnt <= hcnt + 9'd1;
                end

                if (hcnt == H_ACTIVE - 1) line_start <= 1'b1;   // fires the cycle hcnt is about to become H_ACTIVE (320)

                if (v_active_prev && !v_active) frame_start <= 1'b1;
            end
        end
    end

endmodule
