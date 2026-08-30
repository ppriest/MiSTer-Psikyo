// Decodes one 16-pixel row of a 16x16x4bpp "packed_msb" tile (MAME's
// gfx_16x16x4_packed_msb layout, used for both the "sprites" and "tiles"
// gfx regions -- gfx_psikyo in psikyo.cpp) into 16 4-bit pixel/palette-nibble
// values.
//
// Format, verified against MAME's actual decode algorithm
// (src/emu/drawgfx.cpp: gfx_element::decode()/readbit()), NOT just the
// gfx_layout struct's field values at face value -- a first pass at reading
// the struct alone (planeoffset={0,1,2,3}) suggested the nibble might need
// bit-reversing, which turned out to be wrong once the actual plane->pixel
// bit assignment (planebit starts at 1<<(planes-1) for plane 0, i.e. plane 0
// is the pixel's MSB, not LSB) and readbit()'s MSB-first bit addressing were
// worked through together:
//
//   - Row = 8 bytes, byte-major, MSB-first: byte0 holds pixels 0-1, byte1
//     holds pixels 2-3, ..., byte7 holds pixels 14-15.
//   - Each byte's HIGH nibble is the even (left) pixel, LOW nibble is the
//     odd (right) pixel ("x order: hi nibble first" per generic.cpp).
//   - Within a nibble, the 4 bits map DIRECTLY to the pixel's palette index
//     (bit3..bit0 of the nibble = bit3..bit0 of the pixel value) -- no
//     reversal needed.
//
// flip_x mirrors the whole 16-pixel row (sprite/tile horizontal flip).

module tile_row_decode (
	input  logic [7:0] row_bytes [0:7],  // row_bytes[0] = leftmost byte (pixels 0,1)
	input  logic        flip_x,
	output logic [3:0]  pixel [0:15]     // pixel[0] = leftmost displayed pixel
);

	logic [3:0] natural [0:15];

	genvar gx;
	generate
		for (gx = 0; gx < 16; gx++) begin : g_natural
			// even x -> high nibble of byte[x/2], odd x -> low nibble
			assign natural[gx] = gx[0] ? row_bytes[gx/2][3:0] : row_bytes[gx/2][7:4];
		end
	endgenerate

	genvar gy;
	generate
		for (gy = 0; gy < 16; gy++) begin : g_out
			assign pixel[gy] = flip_x ? natural[15 - gy] : natural[gy];
		end
	endgenerate

endmodule
