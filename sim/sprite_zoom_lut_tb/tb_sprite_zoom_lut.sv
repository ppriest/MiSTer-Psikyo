// Exhaustive check of sprite_zoom_lut against the reference table computed
// independently with Python's exact integer arithmetic (see
// docs/phase1_video_engine.md derivation) for all 16 raw zoom values.

module tb_sprite_zoom_lut;

	logic [3:0]  raw_zoom;
	logic [4:0]  dst_size;
	logic [16:0] dx;

	sprite_zoom_lut dut (.raw_zoom(raw_zoom), .dst_size(dst_size), .dx(dx));

	// {dst_size, dx} for raw=0..15, computed in Python from the exact
	// drawgfxzoom_core formula (dstwidth=(scale*16+0x8000)>>16,
	// dx=(16<<16)/dstwidth, scale=(32-raw)<<11).
	int exp_size [0:15] = '{16,16,15,15,14,14,13,13,12,12,11,11,10,10,9,9};
	logic [16:0] exp_dx [0:15] = '{
		17'h10000, 17'h10000, 17'h11111, 17'h11111,
		17'h12492, 17'h12492, 17'h13B13, 17'h13B13,
		17'h15555, 17'h15555, 17'h1745D, 17'h1745D,
		17'h19999, 17'h19999, 17'h1C71C, 17'h1C71C
	};

	int errors;

	initial begin
		errors = 0;
		for (int r = 0; r < 16; r++) begin
			raw_zoom = r[3:0];
			#1;
			if (dst_size !== exp_size[r][4:0] || dx !== exp_dx[r]) begin
				errors++;
				$display("FAIL raw=%0d got=(size=%0d dx=%h) expected=(size=%0d dx=%h)",
						  r, dst_size, dx, exp_size[r], exp_dx[r]);
			end
		end

		if (errors == 0)
			$display("PASS: sprite_zoom_lut matches the reference table for all 16 raw zoom values");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
