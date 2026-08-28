// Final compositing stage: two live tilemap-layer pixel streams
// (tilemap_line_engine x2) + the sprite frame buffer's read port ->
// resolved palette index -> xRGB_555 RGB. Per-pixel priority mux, not a
// persisted priority bitmap -- see docs/phase1_video_engine.md,
// "Compositor: backdrop, transparent-pen, and palette lookup" for the full
// derivation (traced directly from screen_update(), including a real MAME
// quirk: the backdrop color is ALWAYS derived from layer 0's
// transparent-pen-select bit alone, regardless of which layer is actually
// enabled -- `layers_ctrl`, which would select otherwise, is hardcoded to
// -1 in the current driver, making that fallback logic dead code. This RTL
// reproduces that exact behavior rather than the probably-intended
// alternative, per this project's standing "match MAME" rule.
//
// Sprite opacity needs no per-pixel check here: sprite_render_engine
// already applied trans_pen0/trans_pen15 before ever writing to the frame
// buffer, so sp_present alone means "opaque."
//
// Palette RAM (xRGB_555, 4096 entries) is a 1-cycle sync read port owned
// externally (shared with CPU-visible palette writes) -- this module
// computes pal_addr purely combinationally from its inputs; the 1-cycle
// latency comes entirely from the external palette memory's own read
// port (matching every other BRAM interface in this project), not from
// any register in here -- an earlier draft also registered `rgb` inside
// this module, which would have added a REDUNDANT second cycle of
// latency on top of the palette memory's own, silently doubling the
// pipeline depth. `rgb` is simply `pal_data[14:0]`. This module ends up
// entirely combinational (no clock, no registers) as a result.

module compositor (
    input logic         l0_valid,
    input logic [3:0]  l0_pixel,
    input logic [6:0]  l0_color,
    input logic         l0_ctrl_enable,        // layer_ctrl[0] bit 0
    input logic         l0_ctrl_opaque,        // layer_ctrl[0] bit 1
    input logic         l0_ctrl_transpen_sel,  // layer_ctrl[0] bit 3 (1 -> pen 0 transparent, 0 -> pen 15)

    input logic         l1_valid,
    input logic [3:0]  l1_pixel,
    input logic [6:0]  l1_color,
    input logic         l1_ctrl_enable,
    input logic         l1_ctrl_opaque,
    input logic         l1_ctrl_transpen_sel,

    input logic         sp_present,
    input logic [3:0]  sp_pixel,
    input logic [4:0]  sp_color,
    input logic [1:0]  sp_priority,

    output logic [11:0] pal_addr,
    input  logic [15:0] pal_data,   // xRGB_555

    output logic [14:0] rgb
);

    // ---- per-layer opacity ----
    logic [3:0]  l0_transpen, l1_transpen;
    logic         l0_draws, l1_draws;

    assign l0_transpen = l0_ctrl_transpen_sel ? 4'd0 : 4'd15;
    assign l1_transpen = l1_ctrl_transpen_sel ? 4'd0 : 4'd15;

    assign l0_draws = l0_valid && l0_ctrl_enable && (l0_ctrl_opaque || (l0_pixel != l0_transpen));
    assign l1_draws = l1_valid && l1_ctrl_enable && (l1_ctrl_opaque || (l1_pixel != l1_transpen));

    // ---- priority resolution + sprite gating ----
    logic [1:0] priority_val;
    assign priority_val = l1_draws ? 2'd2 : (l0_draws ? 2'd1 : 2'd0);

    logic [7:0] primask;
    always_comb begin
        unique case (sp_priority)
            2'd0: primask = 8'h00;
            2'd1: primask = 8'hFC;
            2'd2: primask = 8'hFF;
            2'd3: primask = 8'hFF;
        endcase
    end

    logic sprite_wins;
    assign sprite_wins = sp_present && ((({6'd0, priority_val}) & primask) == 8'h00);

    // ---- palette address mux ----
    // tilemap: 0x800 + color*16 + pixel (color already includes layer 1's +64);
    // {color,pixel} concatenation IS color*16+pixel exactly since pixel is
    // always a 4-bit low nibble -- no actual multiply needed.
    // sprite:  0x000 + color*16 + pixel, same trick.
    // backdrop: layer 0's transparent-pen-select bit picks pen 0 (0x800) or
    // pen 15 (0x80f) -- unconditionally, see header comment.
    logic [10:0] l1_pal_offset, l0_pal_offset;   // color(7b)*16+pixel(4b), max 71*16+15=1151
    logic [8:0]  sp_pal_offset;                    // color(5b)*16+pixel(4b), max 31*16+15=511
    assign l1_pal_offset = {l1_color, l1_pixel};
    assign l0_pal_offset = {l0_color, l0_pixel};
    assign sp_pal_offset  = {sp_color, sp_pixel};

    always_comb begin
        if (sprite_wins)
            pal_addr = {3'd0, sp_pal_offset};
        else if (l1_draws)
            pal_addr = 12'h800 + {1'b0, l1_pal_offset};
        else if (l0_draws)
            pal_addr = 12'h800 + {1'b0, l0_pal_offset};
        else
            pal_addr = l0_ctrl_transpen_sel ? 12'h800 : 12'h80f;
    end

    assign rgb = pal_data[14:0];

endmodule
