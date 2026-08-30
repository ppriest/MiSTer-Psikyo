// Computes one 16x16 sub-tile's screen position and LUT-index code, from the
// get_sprites() sub-tile loop (psikyo_v.cpp, verified against the actual
// current source rather than re-derived by hand):
//
//   int xstart, xend, xinc;
//   if (flipx) { xstart = nx-1; xend = -1; xinc = -1; } else { xstart = 0; xend = nx; xinc = +1; }
//   int ystart, yend, yinc;
//   if (flipy) { ystart = ny-1; yend = -1; yinc = -1; } else { ystart = 0; yend = ny; yinc = +1; }
//   for (dy = ystart; dy != yend; dy += yinc)
//     for (dx = xstart; dx != xend; dx += xinc) {
//       sprite.code  = spritelut[code & (lutlen-1)];   // NOT done here, see next stage
//       sprite.x     = x + (dx * zoomx) / 2;            // zoomx here is the TRANSFORMED (32-raw) value
//       sprite.y     = y + (dy * zoomy) / 2;
//       code++;
//     }
//
// Two things worth being explicit about since they're easy to get backwards:
//
// 1. `dx`/`dy` in that C++ loop are simultaneously the position-grid column/row
//    AND the loop counter -- under flip they still range over 0..nx-1 (resp.
//    0..ny-1), just VISITED in descending order. This module takes the caller's
//    natural (always-ascending, flip-unaware) `ix`/`iy` grid indices and does
//    the nx-1-ix / ny-1-iy reversal internally when flip is set, producing the
//    same `dx`/`dy` grid value the C++ would use for `sprite.x`/`sprite.y` at
//    that visitation step.
// 2. `code` increments once per INNER-LOOP ITERATION, in VISITATION order --
//    i.e. it follows the reversed order under flip, not the natural grid
//    order. The caller is expected to drive `subtile_ordinal` as a plain
//    monotonic 0..nx*ny-1 counter that counts iterations in the same
//    start/inc/end sequence the C++ loop actually walks (ordinal 0 on the
//    first iteration regardless of flip direction) -- this module just adds
//    it to the base code, it does not independently re-derive visitation
//    order for it.
//
// The C++ has a `zoomx==32 && zoomy==32` fast path using `dx*16` directly;
// that's a software-only optimization (32/2 == 16 exactly), not a distinct
// hardware behavior, so it is deliberately not special-cased here -- `(dx *
// zoomx) / 2` alone already produces the identical result at zoomx==32.
//
// spritelut ROM indirection (code -> real gfx tile number) is a separate
// later pipeline stage, not handled here -- this module only produces the
// raw `code` value the LUT will be indexed with (docs/phase1_video_engine.md,
// "Code -> gfx ROM tile number is indirected through a ROM lookup table").
//
// Output width sizing: exhaustively swept the whole realistic input domain
// (x_pos -128..383, y_pos -256..255, nx/ny 1-8, zoom_raw 0-15, dx/dy
// 0..nx-1/0..ny-1) in Python -- true range is X:[-128,495], Y:[-256,367],
// both comfortably inside signed 10-bit (-512..511), so sub_x/sub_y stay
// the same width as sprite_pos_transform's x_adj/y_adj rather than growing.

module sprite_subtile_step (
	input  logic [3:0]        ix,                  // 0..nx-1, natural (flip-unaware) column index
	input  logic [3:0]        iy,                  // 0..ny-1, natural (flip-unaware) row index
	input  logic [3:0]        nx,                  // 1-8
	input  logic [3:0]        ny,                  // 1-8
	input  logic              flip_x,
	input  logic              flip_y,
	input  logic signed [9:0] x_adj,
	input  logic signed [9:0] y_adj,
	input  logic [5:0]        zoom_x_transformed,  // 17-32
	input  logic [5:0]        zoom_y_transformed,  // 17-32
	input  logic [5:0]        subtile_ordinal,     // 0-63, visitation-order iteration count
	input  logic [16:0]       code_base,

	output logic signed [9:0] sub_x,
	output logic signed [9:0] sub_y,
	output logic [16:0]       sub_code
);

	logic [3:0] dx_grid, dy_grid;    // real range 0-7

	assign dx_grid = flip_x ? (nx - 4'd1 - ix) : ix;
	assign dy_grid = flip_y ? (ny - 4'd1 - iy) : iy;

	logic [7:0] x_step_prod, y_step_prod;  // dx_grid(max 7) * zoom(max 32) = max 224
	logic [6:0] x_step, y_step;            // >>1 of the above, max 112

	assign x_step_prod = {4'd0, dx_grid} * {2'd0, zoom_x_transformed};
	assign x_step       = x_step_prod[7:1];
	assign sub_x         = x_adj + $signed({3'd0, x_step});

	assign y_step_prod = {4'd0, dy_grid} * {2'd0, zoom_y_transformed};
	assign y_step       = y_step_prod[7:1];
	assign sub_y         = y_adj + $signed({3'd0, y_step});

	assign sub_code = code_base + {11'd0, subtile_ordinal};

endmodule
