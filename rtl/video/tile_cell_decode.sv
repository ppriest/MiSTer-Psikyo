// Decodes a raw 16-bit tilemap VRAM cell (named vram_cell -- "cell" is a
// reserved SystemVerilog keyword, part of the config/cell/liblist/use
// declaration syntax) into a gfx-ROM tile number and palette color-group
// index, per get_tile_info<Layer> (psikyo_v.cpp:78-86):
//
//   tile_number = (vram_cell[12:0]) + 0x2000 * bank
//   color       = vram_cell[15:13] + layer*0x40
//
// `bank` (0-3) is the live tile-source bank selected via vreg layer-control
// bit 10 on gunbird/btlkroad (m_ka302c_banking) -- fixed at 0 (layer 0) / 1
// (layer 1) on sngkace, which never changes it (see docs/phase1_video_engine.md,
// "Tile cell format"). `layer` is a static per-instance parameter (0 or 1),
// not a runtime input -- each tilemap layer gets its own instance.

module tile_cell_decode #(
	parameter int LAYER = 0   // 0 or 1
) (
	input  logic [15:0] vram_cell,
	input  logic [1:0]  bank,
	output logic [14:0] tile_number,
	output logic [6:0]  color
);

	// Concatenation-based bank/layer-offset construction throughout,
	// deliberately avoiding bare shift/multiply-by-parameter expressions --
	// see the tile_row_decode_tb commit message for why: Verilog's
	// self-determined operand widths inside arithmetic expressions are an
	// easy silent-corruption trap.
	localparam logic [6:0] LAYER_BASE = (LAYER != 0) ? 7'd64 : 7'd0;

	assign tile_number = {2'b00, vram_cell[12:0]} + {bank, 13'd0};
	assign color        = {4'b0000, vram_cell[15:13]} + LAYER_BASE;

endmodule
