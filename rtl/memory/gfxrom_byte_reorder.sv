// Reorders a 64-bit SDRAM read granule (native ascending-address ->
// ascending-bit-position packing, as produced by rtl/memory/sdram/
// sdram.sv's burst-4 read capture -- see that module's own
// STATE_READ0..STATE_READ3 comments, and confirmed directly by
// sim/sdram_tb/tb_sdram.sv's Case 1: the lowest-address seeded word lands
// in dout's LOW 16 bits) into the MSB-first byte order tile_row_decode's
// callers require (tilemap_line_engine.sv / sprite_render_engine.sv's
// gfxrom_data port contract: "8 bytes, MSB-first", i.e. the byte at the
// LOWEST ROM address belongs in bits [63:56], not [7:0] -- matching MAME's
// gfx_16x16x4_packed_msb tile format, see rtl/video/tile_row_decode.sv's
// header for that format's own derivation).
//
// This module is the seam between two self-consistent but OPPOSITE
// byte-order conventions: sdram.sv's is ordinary
// ascending-address-ascending-bit-position, matching standard little-endian
// ROM/CPU word semantics (and correct as-is for
// rtl/memory/sdram_narrow_bridge.sv's 16-bit-word/8-bit-byte consumers --
// spritelut, maincpu, audiocpu -- which must NOT be routed through this
// module); the gfx-row consumers' is MAME's packed-MSB tile format.
// Neither side is wrong on its own, so the reorder belongs here, not in
// sdram.sv (correct for general ROM access) or in
// tilemap_line_engine.sv/sprite_render_engine.sv (correct against MAME's
// real tile format, and independently unit-tested that way). Note that
// uniform gfx ROM content is byte-order-invariant -- a testbench must use
// non-uniform content to exercise this at all (docs/phase1_sdram_map.md).

module gfxrom_byte_reorder (
	input  logic [63:0] sdram_granule,
	output logic [63:0] gfxrom_data
);

	assign gfxrom_data = {sdram_granule[7:0],   sdram_granule[15:8],
							sdram_granule[23:16], sdram_granule[31:24],
							sdram_granule[39:32], sdram_granule[47:40],
							sdram_granule[55:48], sdram_granule[63:56]};

endmodule
