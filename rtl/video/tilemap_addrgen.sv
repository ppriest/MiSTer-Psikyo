// Tilemap VRAM address generator, one instance per layer.
//
// Computes the VRAM word index for a given (col,row) tile coordinate, for
// whichever of the four dynamic tilemap geometries is currently selected.
// See docs/phase1_video_engine.md ("Tilemap addressing") for the derivation:
// MAME's tile_scan<Layer> (psikyo_v.cpp) looks like a bit-interleave, but its
// result is always masked to the low 12 bits by the caller, and every extra
// term in each case's formula lands entirely above bit 11 -- dead once
// masked. All four modes reduce to plain row-major addressing,
// index = col + row*width, verified by exhaustive brute-force check
// (sim/tilemap_addrgen_tb/) against every (col,row) pair in each mode's grid.
//
// mode encodes the vreg layer-control bits [7:6] directly:
//   0 -> 64x64 tiles  (1024x1024 px), index = col[5:0] | row[5:0]<<6
//   1 -> 128x32 tiles (2048x512 px),  index = col[6:0] | row[4:0]<<7
//   2 -> 256x16 tiles (4096x256 px),  index = col[7:0] | row[3:0]<<8
//   3 -> 32x128 tiles (512x2048 px),  index = col[4:0] | row[6:0]<<5
//
// col/row are taken in as full 8/7-bit values (the maximum range any mode
// uses) and masked internally per-mode -- callers don't need to know each
// mode's actual grid extent, just feed the logical tilemap-space coordinate.

module tilemap_addrgen (
	input  logic [1:0] mode,
	input  logic [7:0] col,
	input  logic [6:0] row,
	output logic [11:0] vram_index
);

	always_comb begin
		unique case (mode)
			2'd0: vram_index = {6'd0, col[5:0]} | ({6'd0, row[5:0]} << 6);
			2'd1: vram_index = {5'd0, col[6:0]} | ({5'd0, row[4:0]} << 7);
			2'd2: vram_index = {4'd0, col[7:0]} | ({4'd0, row[3:0]} << 8);
			2'd3: vram_index = {7'd0, col[4:0]} | ({7'd0, row[6:0]} << 5);
		endcase
	end

endmodule
