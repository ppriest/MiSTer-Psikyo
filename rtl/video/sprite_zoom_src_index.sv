// Per-destination-column source pixel index for the nearest-neighbor
// zoom-blit accumulator (gfx_element::drawgfxzoom_core, drawgfxt.ipp:738-805),
// collapsed to a closed form -- see docs/phase1_video_engine.md, "The actual
// per-tile scaling algorithm":
//
//   no flip: accum before column `col` (0-indexed) = col * dx
//   flip:    accum before column `col`              = (dst_size-1-col) * dx
//   src_index = accum >> 16
//
// dx is constant across one sub-tile row/column (it only depends on the
// sprite's raw zoom value, via sprite_zoom_lut), so the running accumulator
// the C++ actually uses is just an arithmetic progression -- no per-cycle
// state needed here, this is pure combinational per-column math. `col` is
// expected to be driven 0..dst_size-1 by the caller (a sequential blit
// walker, not yet built); behavior for col >= dst_size is a don't-care.
//
// Verified in Python that src_index always lands in 0-15 across the full
// valid domain (all 16 raw zoom values, both flip directions, every valid
// col for that raw's dst_size) despite col*dx needing ~21 bits before the
// >>16 -- it never indexes outside the source tile's 16 pixels.

module sprite_zoom_src_index (
	input  logic [3:0]  col,        // 0..dst_size-1 (caller-guaranteed)
	input  logic [3:0]  dst_size,   // 9-16, from sprite_zoom_lut
	input  logic [16:0] dx,         // 16.16 fixed-point step, from sprite_zoom_lut
	input  logic         flip,

	output logic [3:0]  src_index   // 0-15
);

	logic [3:0]  eff_col;
	logic [20:0] prod;   // col/eff_col (4b, max 15) * dx (17b, max 0x1C71C) needs 21 bits

	assign eff_col = flip ? (dst_size - 4'd1 - col) : col;
	assign prod     = {17'd0, eff_col} * {4'd0, dx};
	assign src_index = prod[19:16];

endmodule
