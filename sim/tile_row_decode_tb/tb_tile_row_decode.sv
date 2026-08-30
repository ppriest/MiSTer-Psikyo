// Verifies tile_row_decode against a row with a known, distinct nibble
// pattern (pixel x = value x, for x=0..15) and checks both the un-flipped
// and horizontally-flipped outputs.

module tb_tile_row_decode;

	logic [7:0] row_bytes [0:7];
	logic       flip_x;
	logic [3:0] pixel [0:15];

	tile_row_decode dut (
		.row_bytes(row_bytes),
		.flip_x(flip_x),
		.pixel(pixel)
	);

	int errors;

	initial begin
		errors = 0;

		// byte[i] = {pixel(2i) nibble, pixel(2i+1) nibble} = {2i, 2i+1}
		// so natural pixel x should decode to value x for x=0..15.
		// (explicit 4'() width casts -- self-determined width rules on a
		// bare "i[3:0]*2" inside a concatenation promote it to 32 bits and
		// silently corrupt the packed byte; caught this via the exhaustive
		// even/odd failure pattern below, not by inspection.)
		for (int i = 0; i < 8; i++) begin
			logic [3:0] hi, lo;
			hi = 4'(i * 2);
			lo = 4'(i * 2 + 1);
			row_bytes[i] = {hi, lo};
		end

		flip_x = 1'b0;
		#1;
		for (int x = 0; x < 16; x++) begin
			if (pixel[x] !== x[3:0]) begin
				errors++;
				$display("FAIL (no flip) x=%0d got=%0d expected=%0d", x, pixel[x], x);
			end
		end

		flip_x = 1'b1;
		#1;
		for (int x = 0; x < 16; x++) begin
			if (pixel[x] !== (15 - x)) begin
				errors++;
				$display("FAIL (flip) x=%0d got=%0d expected=%0d", x, pixel[x], 15 - x);
			end
		end

		if (errors == 0)
			$display("PASS: tile_row_decode correct for both flip_x=0 and flip_x=1 (32 pixel checks)");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
