// Decodes one raw 8-byte spriteram attribute record (4 x 16-bit words)
// into its constituent fields, per get_sprites() (psikyo_v.cpp:185-235,
// BEFORE the zoom-transform/position-offset math those fields feed into --
// see sprite_pos_transform for that next stage).
//
// X and Y use genuinely different sign conventions -- re-verified directly
// against the C++ line by line (see docs/phase1_video_engine.md, "Position
// sign convention") after an earlier documentation pass wrote it up as if
// there were one shared convention, which was wrong:
//   X: mask to 9 bits, then -= 0x200 only if the masked value >= 0x180
//      (asymmetric: 0-383 positive, 384-511 -> -128..-1)
//   Y: (y&0xFF)-(y&0x100) -- plain 9-bit two's-complement sign extension
//      (flips at bit 8, range -256..255)
// Both are extracted from the RAW word; the zoom/tile-count fields live in
// the upper 7 bits and are read before the 9-bit position mask is applied.

module sprite_record_decode (
	input  logic [15:0] word_y,        // spriteram record +0x0
	input  logic [15:0] word_x,        // spriteram record +0x2
	input  logic [15:0] word_attr,     // spriteram record +0x4
	input  logic [15:0] word_code_lo,  // spriteram record +0x6

	output logic [3:0]        zoom_y_raw,
	output logic [3:0]        zoom_x_raw,
	output logic [3:0]        ny,           // 1-8
	output logic [3:0]        nx,           // 1-8
	output logic signed [9:0] y_pos,        // -256..255
	output logic signed [9:0] x_pos,        // -128..383
	output logic              flip_y,
	output logic              flip_x,
	output logic [4:0]        color,
	output logic [1:0]        priority_field,
	output logic [16:0]       code
);

	logic [8:0] y_raw9, x_raw9;

	assign zoom_y_raw = word_y[15:12];
	assign ny          = {1'b0, word_y[11:9]} + 4'd1;
	assign y_raw9       = word_y[8:0];
	assign y_pos         = $signed({y_raw9[8], y_raw9});   // plain 9-bit sign extension

	assign zoom_x_raw = word_x[15:12];
	assign nx          = {1'b0, word_x[11:9]} + 4'd1;
	assign x_raw9       = word_x[8:0];
	assign x_pos = (x_raw9 >= 9'd384) ? ({1'b0, x_raw9} - 10'd512) : $signed({1'b0, x_raw9});

	assign flip_y         = word_attr[15];
	assign flip_x         = word_attr[14];
	// bit 13 ("?used") is genuinely excluded -- see docs/phase1_video_engine.md
	// for how the 5-bit width (not 4) was confirmed via prio_zoom_transmask's
	// `color % colors()` (colors()==32) rather than trusted from the comment.
	assign color           = word_attr[12:8];
	assign priority_field = word_attr[7:6];
	assign code             = {word_attr[0], word_code_lo};

endmodule
