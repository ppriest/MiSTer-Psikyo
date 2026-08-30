// Exhaustive check of tilemap_addrgen against the verified row-major formula
// (index = col + row*width, wrapped to each mode's grid) for every (mode,
// col, row) combination -- mirrors the Python brute-force check used to
// derive the formula in the first place (see docs/phase1_video_engine.md).

module tb_tilemap_addrgen;

	logic [1:0] mode;
	logic [7:0] col;
	logic [6:0] row;
	logic [11:0] vram_index;

	tilemap_addrgen dut (
		.mode(mode),
		.col(col),
		.row(row),
		.vram_index(vram_index)
	);

	int width;
	int wmask, hmask;
	int expected;
	int errors;

	initial begin
		errors = 0;

		for (int m = 0; m < 4; m++) begin
			mode = m[1:0];
			case (m)
				0: width = 64;
				1: width = 128;
				2: width = 256;
				3: width = 32;
			endcase
			wmask = width - 1;
			case (m)
				0: hmask = 63;   // 64 rows
				1: hmask = 31;   // 32 rows
				2: hmask = 15;   // 16 rows
				3: hmask = 127;  // 128 rows
			endcase

			for (int r = 0; r < 128; r++) begin
				for (int c = 0; c < 256; c++) begin
					col = c[7:0];
					row = r[6:0];
					#1;
					expected = (c & wmask) + (r & hmask) * width;
					if (vram_index !== expected[11:0]) begin
						errors++;
						if (errors <= 10)
							$display("FAIL mode=%0d col=%0d row=%0d got=%0d expected=%0d",
									  m, c, r, vram_index, expected);
					end
				end
			end
			$display("mode %0d: checked 256x128=32768 (col,row) pairs", m);
		end

		if (errors == 0)
			$display("PASS: tilemap_addrgen matches col+row*width for all 4 modes, all (col,row) pairs (4x32768=131072 checks)");
		else
			$display("FAIL: %0d mismatches out of 131072 checks", errors);

		$finish;
	end

endmodule
