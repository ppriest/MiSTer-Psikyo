// Applies the position offset correction and zoom-factor transform that
// get_sprites() does between decoding the raw record and iterating
// sub-tiles (psikyo_v.cpp:235-239):
//
//   x += (nx * zoomx_raw + 2) / 4          -- offset correction, uses RAW zoom
//   y += (ny * zoomy_raw + 2) / 4
//   zoomx = 32 - zoomx_raw                  -- THEN the raw->transformed zoom
//   zoomy = 32 - zoomy_raw
//
// Note the offset correction uses the raw (0-15) zoom value, computed
// BEFORE the 32-raw transform -- easy to accidentally swap the order since
// both are one-line C++ statements next to each other. zoom_*_transformed
// here is for sub-tile position stepping (sprite_subtile_step, not yet
// written); it is NOT the same value sprite_zoom_lut consumes -- that
// module takes the raw 0-15 value directly (see its header comment).
//
// flip_screen (a global DIP-controlled screen flip, psikyo_v.cpp:241-247)
// is deliberately not handled here -- deferred, see docs/phase1_video_engine.md.

module sprite_pos_transform (
	input  logic signed [9:0] x_pos,
	input  logic signed [9:0] y_pos,
	input  logic [3:0]        nx,           // 1-8
	input  logic [3:0]        ny,           // 1-8
	input  logic [3:0]        zoom_x_raw,   // 0-15
	input  logic [3:0]        zoom_y_raw,   // 0-15

	output logic signed [9:0] x_adj,
	output logic signed [9:0] y_adj,
	output logic [5:0]        zoom_x_transformed,   // 17-32
	output logic [5:0]        zoom_y_transformed    // 17-32
);

	logic [6:0] x_prod, y_prod;      // nx(4b, max 8) * zoom_raw(4b, max 15) = max 120, 7 bits
	logic [4:0] x_offset, y_offset;  // (prod+2)>>2, max (120+2)>>2 = 30, 5 bits

	assign x_prod   = {3'd0, nx} * {3'd0, zoom_x_raw};
	assign x_offset = (x_prod + 7'd2) >> 2;
	assign x_adj    = x_pos + $signed({5'd0, x_offset});

	assign y_prod   = {3'd0, ny} * {3'd0, zoom_y_raw};
	assign y_offset = (y_prod + 7'd2) >> 2;
	assign y_adj    = y_pos + $signed({5'd0, y_offset});

	assign zoom_x_transformed = 6'd32 - {2'd0, zoom_x_raw};
	assign zoom_y_transformed = 6'd32 - {2'd0, zoom_y_raw};

endmodule
