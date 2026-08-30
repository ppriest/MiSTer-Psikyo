// Exhaustively checks sprite_zoom_src_index against an independently
// computed reference, over every (dst_size, dx) pair sprite_zoom_lut can
// actually produce (the 8 distinct values from its table -- upstream raw
// zoom -> dst_size/dx mapping is sprite_zoom_lut's own responsibility and
// already verified there), every valid col for that dst_size, and both
// flip directions.

module tb_sprite_zoom_src_index;

	logic [3:0]  col, dst_size;
	logic [16:0] dx;
	logic         flip;
	logic [3:0]  src_index;

	sprite_zoom_src_index dut (.*);

	int errors;

	// (dst_size, dx) pairs from sprite_zoom_lut.sv's table, raw 0..15 collapsed
	// to the 8 distinct values (each hit by two adjacent raw values).
	int dst_sizes[8] = '{16, 15, 14, 13, 12, 11, 10, 9};
	int dxs[8]       = '{'h10000, 'h11111, 'h12492, 'h13b13, 'h15555, 'h1745D, 'h19999, 'h1C71C};

	task automatic check(int ds, int dxv, int c, int fl);
		int eff_c, exp_idx;
		dst_size = ds[3:0]; dx = dxv[16:0]; col = c[3:0]; flip = fl[0];
		#1;
		eff_c   = fl ? (ds - 1 - c) : c;
		exp_idx = (eff_c * dxv) >> 16;
		if (src_index !== exp_idx[3:0]) begin
			errors++;
			if (errors <= 10)
				$display("FAIL ds=%0d dx=%h col=%0d flip=%0d got=%0d expected=%0d",
						  ds, dxv, c, fl, src_index, exp_idx);
		end
	endtask

	int total;

	initial begin
		errors = 0;
		total = 0;
		foreach (dst_sizes[k]) begin
			for (int c = 0; c < dst_sizes[k]; c++)
				for (int fl = 0; fl <= 1; fl++) begin
					check(dst_sizes[k], dxs[k], c, fl);
					total++;
				end
		end
		$display("sweep done (%0d checks: all 8 (dst_size,dx) pairs x every valid col x 2 flip)", total);

		if (errors == 0)
			$display("PASS: sprite_zoom_src_index matches reference for the full realistic domain (%0d checks)", total);
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
