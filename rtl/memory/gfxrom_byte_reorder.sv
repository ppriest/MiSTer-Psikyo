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
// Real, previously-undetected integration bug this module exists to fix,
// found while wiring sim/port2_sdram_tb/tb_port2_sdram.sv (Port 2's sprite
// gfxrom path) with genuinely non-uniform gfx ROM content: sdram.sv and the
// gfx-row consumers were each built and verified independently against
// self-consistent but OPPOSITE byte-order conventions -- sdram.sv's is
// ordinary ascending-address-ascending-bit-position, matching standard
// little-endian ROM/CPU word semantics (and still correct as-is for
// rtl/memory/sdram_narrow_bridge.sv's 16-bit-word/8-bit-byte consumers --
// spritelut, maincpu, audiocpu -- which must NOT be routed through this
// module); the gfx-row consumers' is MAME's packed-MSB tile format. Neither
// side was wrong on its own, so the fix belongs at this specific seam, not
// in sdram.sv (already correct for general ROM access) or in
// tilemap_line_engine.sv/sprite_render_engine.sv (already correct against
// MAME's real tile format, and already independently unit-tested that way).
//
// sim/video_pipeline_tb/tb_video_pipeline_sdram.sv's tilemap integration
// test never caught this because its gfx ROM content was uniform (all
// 0x0000), which is byte-order-invariant -- worth remembering as a real gap
// in that test's coverage, not just a footnote (see docs/phase1_sdram_map.md).

module gfxrom_byte_reorder (
    input  logic [63:0] sdram_granule,
    output logic [63:0] gfxrom_data
);

    assign gfxrom_data = {sdram_granule[7:0],   sdram_granule[15:8],
                            sdram_granule[23:16], sdram_granule[31:24],
                            sdram_granule[39:32], sdram_granule[47:40],
                            sdram_granule[55:48], sdram_granule[63:56]};

endmodule
