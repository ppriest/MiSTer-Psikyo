// Exhaustively checks sprite_record_decode's Y and X position/zoom/count
// decode (all 65536 values each) against the reference formulas from
// get_sprites(), independently computed here (not reusing the RTL's own
// expressions). Also spot-checks the attr/code word decode.

module tb_sprite_record_decode;

	logic [15:0] word_y, word_x, word_attr, word_code_lo;

	logic [3:0]        zoom_y_raw, zoom_x_raw;
	logic [3:0]        ny, nx;
	logic signed [9:0] y_pos, x_pos;
	logic              flip_y, flip_x;
	logic [4:0]        color;
	logic [1:0]        priority_field;
	logic [16:0]       code;

	sprite_record_decode dut (.*);

	int errors;

	task automatic check_y(int wy);
		int exp_zoom, exp_ny, exp_y9, exp_ypos;
		word_y = wy[15:0];
		#1;
		exp_zoom = (wy >> 12) & 4'hF;
		exp_ny   = ((wy >> 9) & 3'h7) + 1;
		exp_y9   = wy & 9'h1FF;
		exp_ypos = (exp_y9 & 8'hFF) - (exp_y9 & 9'h100);
		if (zoom_y_raw !== exp_zoom[3:0] || ny !== exp_ny[3:0] || y_pos !== exp_ypos[9:0]) begin
			errors++;
			if (errors <= 10)
				$display("FAIL(y) wy=%h got=(zoom=%0d ny=%0d ypos=%0d) expected=(zoom=%0d ny=%0d ypos=%0d)",
						  wy, zoom_y_raw, ny, y_pos, exp_zoom, exp_ny, exp_ypos);
		end
	endtask

	task automatic check_x(int wx);
		int exp_zoom, exp_nx, exp_x9, exp_xpos;
		word_x = wx[15:0];
		#1;
		exp_zoom = (wx >> 12) & 4'hF;
		exp_nx   = ((wx >> 9) & 3'h7) + 1;
		exp_x9   = wx & 9'h1FF;
		exp_xpos = (exp_x9 >= 'h180) ? (exp_x9 - 'h200) : exp_x9;
		if (zoom_x_raw !== exp_zoom[3:0] || nx !== exp_nx[3:0] || x_pos !== exp_xpos[9:0]) begin
			errors++;
			if (errors <= 10)
				$display("FAIL(x) wx=%h got=(zoom=%0d nx=%0d xpos=%0d) expected=(zoom=%0d nx=%0d xpos=%0d)",
						  wx, zoom_x_raw, nx, x_pos, exp_zoom, exp_nx, exp_xpos);
		end
	endtask

	initial begin
		errors = 0;
		word_attr = 16'h0000;
		word_code_lo = 16'h0000;

		for (int wy = 0; wy < 65536; wy++) check_y(wy);
		$display("Y sweep done (65536 values)");

		for (int wx = 0; wx < 65536; wx++) check_x(wx);
		$display("X sweep done (65536 values)");

		// spot-check attr/code decode. Built via concatenation (1+1+1+5+2+5+1
		// = 16 bits, self-verifying -- SV errors if the field widths don't
		// sum to 16) rather than a hand-counted binary literal: an earlier
		// version used `16'b1_1_0_1010_10_00001_1`, which is only 15 bits
		// and silently left-pads to 16, shifting every field by one and
		// producing a bogus "FAIL" that had nothing to do with the DUT.
		word_attr = {1'b1, 1'b1, 1'b0, 5'b10101, 2'b10, 5'b00000, 1'b1};   // fy=1 fx=1 used=0 color=10101 pri=10 code_hi=1
		word_code_lo = 16'hABCD;
		#1;
		if (flip_y !== 1'b1 || flip_x !== 1'b1 || color !== 5'b10101 || priority_field !== 2'b10 || code !== {1'b1, 16'hABCD}) begin
			errors++;
			$display("FAIL(attr) got=(fy=%b fx=%b color=%b pri=%b code=%h) expected=(1,1,10101,10,%h)",
					  flip_y, flip_x, color, priority_field, code, {1'b1, 16'hABCD});
		end

		word_attr = {1'b0, 1'b0, 1'b1, 5'b01010, 2'b01, 5'b11111, 1'b0};   // fy=0 fx=0 used=1(ignored) color=01010 pri=01 code_hi=0
		word_code_lo = 16'h1234;
		#1;
		if (flip_y !== 1'b0 || flip_x !== 1'b0 || color !== 5'b01010 || priority_field !== 2'b01 || code !== {1'b0, 16'h1234}) begin
			errors++;
			$display("FAIL(attr2) got=(fy=%b fx=%b color=%b pri=%b code=%h)", flip_y, flip_x, color, priority_field, code);
		end

		if (errors == 0)
			$display("PASS: sprite_record_decode matches reference for all Y/X values (131072 checks) and attr/code spot checks");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
