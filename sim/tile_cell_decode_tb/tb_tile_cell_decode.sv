// Exhaustively checks tile_cell_decode (both LAYER=0 and LAYER=1 instances)
// against the reference formula from get_tile_info<Layer>:
//   tile_number = vram_cell[12:0] + 0x2000*bank
//   color       = vram_cell[15:13] + layer*0x40
// across all 4 banks and a spread of vram_cell values covering every color code
// (vram_cell[15:13], 8 values) crossed with a spread of tile-code low bits.

module tb_tile_cell_decode;

	logic [15:0] vram_cell;
	logic [1:0]  bank;

	logic [14:0] tile_number0, tile_number1;
	logic [6:0]  color0, color1;

	tile_cell_decode #(.LAYER(0)) dut0 (.vram_cell(vram_cell), .bank(bank), .tile_number(tile_number0), .color(color0));
	tile_cell_decode #(.LAYER(1)) dut1 (.vram_cell(vram_cell), .bank(bank), .tile_number(tile_number1), .color(color1));

	int errors;

	task automatic check();
		int exp_tile, exp_color0, exp_color1;
		exp_tile   = (vram_cell & 16'h1FFF) + 32'(bank) * 32'h2000;
		exp_color0 = (vram_cell >> 13) & 3'h7;
		exp_color1 = ((vram_cell >> 13) & 3'h7) + 32'd64;
		#1;
		if (tile_number0 !== exp_tile[14:0] || color0 !== exp_color0[6:0]) begin
			errors++;
			if (errors <= 10)
				$display("FAIL layer0 vram_cell=%h bank=%0d got=(tile=%0d color=%0d) expected=(tile=%0d color=%0d)",
						  vram_cell, bank, tile_number0, color0, exp_tile, exp_color0);
		end
		if (tile_number1 !== exp_tile[14:0] || color1 !== exp_color1[6:0]) begin
			errors++;
			if (errors <= 10)
				$display("FAIL layer1 vram_cell=%h bank=%0d got=(tile=%0d color=%0d) expected=(tile=%0d color=%0d)",
						  vram_cell, bank, tile_number1, color1, exp_tile, exp_color1);
		end
	endtask

	initial begin
		errors = 0;

		for (int b = 0; b < 4; b++) begin
			bank = b[1:0];
			for (int colorcode = 0; colorcode < 8; colorcode++) begin
				for (int lo = 0; lo < 8192; lo += 37) begin  // spread over the 13-bit code field
					vram_cell = {colorcode[2:0], lo[12:0]};
					check();
				end
			end
			// boundary spot checks
			vram_cell = 16'h0000; check();
			vram_cell = 16'hFFFF; check();
			vram_cell = 16'h1FFF; check();
			vram_cell = 16'hE000; check();
		end

		if (errors == 0)
			$display("PASS: tile_cell_decode matches reference formula for both layers, all banks");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
