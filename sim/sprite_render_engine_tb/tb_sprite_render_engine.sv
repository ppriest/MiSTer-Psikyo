// Integration test for sprite_render_engine: wires up synchronous memory
// models for the display list, attribute table, spritelut ROM (req/valid,
// artificial 2-cycle latency), and sprite gfx ROM (req/valid, artificial
// 3-cycle latency -- deliberately different from the LUT's latency to
// confirm the handshakes are genuinely latency-agnostic, not accidentally
// relying on a specific timing), then checks the resulting frame-buffer
// writes against an independently-computed reference.
//
// Four cases, each isolating a different integration risk rather than one
// giant combined scenario:
//   A: 1x1 sprite, no flip -- position + pixel pattern + color/priority
//      wired correctly end-to-end.
//   B: 1x1 sprite, flip_x -- per-pixel horizontal mirroring alone (no
//      sub-tile grid to confuse it with, since nx=1).
//   C: 2x1 sprite, flip_x, two distinct solid-color tiles -- sub-tile GRID
//      visitation order under flip (which tile lands on which screen half).
//   D: same tile as A, trans_pen0 set -- transparent-pen skip logic.

module tb_sprite_render_engine;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;
	logic frame_start, frame_busy, frame_done;
	logic trans_pen0, trans_pen15;
	logic [11:0] dl_addr;
	logic [15:0] dl_data;
	logic [11:0] at_addr;
	logic [15:0] at_data;
	logic         lut_req;
	logic [16:0] lut_addr;
	logic         lut_valid;
	logic [15:0] lut_data;
	logic         gfxrom_req;
	logic [22:0] gfxrom_addr;
	logic         gfxrom_valid;
	logic [63:0] gfxrom_data;
	logic         fb_we;
	logic [8:0]  fb_x;
	logic [7:0]  fb_y;
	logic [3:0]  fb_pixel;
	logic [4:0]  fb_color;
	logic [1:0]  fb_priority;

	sprite_render_engine dut (.*);

	// ---- display list / attribute table memory models (1-cycle sync) ----
	logic [15:0] dl_mem [0:4095];
	logic [15:0] at_mem [0:4095];
	always_ff @(posedge clk) dl_data <= dl_mem[dl_addr];
	always_ff @(posedge clk) at_data <= at_mem[at_addr];

	// ---- spritelut ROM model (req/valid, fixed 2-cycle latency) ----
	logic [15:0] lut_mem [0:131071];
	localparam int LUT_LATENCY = 2;
	logic lut_req_d;
	int   lut_cnt;
	always_ff @(posedge clk) begin
		lut_valid <= 1'b0;
		lut_req_d <= lut_req;
		if (lut_req && !lut_req_d) begin
			lut_cnt <= 0;
		end else if (lut_req && lut_req_d) begin
			if (lut_cnt == LUT_LATENCY - 1) begin
				lut_valid <= 1'b1;
				lut_data  <= lut_mem[lut_addr];
			end else begin
				lut_cnt <= lut_cnt + 1;
			end
		end
	end

	// ---- sprite gfx ROM model (req/valid, fixed 3-cycle latency) ----
	logic [7:0] gfx_mem [0:8191];
	localparam int GFX_LATENCY = 3;
	logic gfxrom_req_d;
	int   gfx_cnt;
	always_ff @(posedge clk) begin
		gfxrom_valid <= 1'b0;
		gfxrom_req_d <= gfxrom_req;
		if (gfxrom_req && !gfxrom_req_d) begin
			gfx_cnt <= 0;
		end else if (gfxrom_req && gfxrom_req_d) begin
			if (gfx_cnt == GFX_LATENCY - 1) begin
				gfxrom_valid <= 1'b1;
				gfxrom_data  <= {gfx_mem[gfxrom_addr+0], gfx_mem[gfxrom_addr+1],
								   gfx_mem[gfxrom_addr+2], gfx_mem[gfxrom_addr+3],
								   gfx_mem[gfxrom_addr+4], gfx_mem[gfxrom_addr+5],
								   gfx_mem[gfxrom_addr+6], gfx_mem[gfxrom_addr+7]};
			end else begin
				gfx_cnt <= gfx_cnt + 1;
			end
		end
	end

	// ---- frame buffer capture ----
	logic         got_written [0:319][0:223];
	logic [3:0]  got_pixel     [0:319][0:223];
	logic [4:0]  got_color     [0:319][0:223];
	logic [1:0]  got_priority [0:319][0:223];

	always_ff @(posedge clk) begin
		if (fb_we) begin
			got_written[fb_x][fb_y]  <= 1'b1;
			got_pixel[fb_x][fb_y]     <= fb_pixel;
			got_color[fb_x][fb_y]     <= fb_color;
			got_priority[fb_x][fb_y] <= fb_priority;
		end
	end

	task automatic clear_fb;
		for (int x = 0; x < 320; x++)
			for (int y = 0; y < 224; y++)
				got_written[x][y] = 1'b0;
	endtask

	// fills gfx_mem for `tile_code` with pixel(r,c) = (r+c)%16
	task automatic write_gradient_tile(int tile_code);
		automatic int base = tile_code * 128;
		for (int r = 0; r < 16; r++)
			for (int k = 0; k < 8; k++) begin
				automatic int p0 = (r + 2*k) % 16;
				automatic int p1 = (r + 2*k + 1) % 16;
				gfx_mem[base + r*8 + k] = {p0[3:0], p1[3:0]};
			end
	endtask

	// fills gfx_mem for `tile_code` with every pixel == `val`
	task automatic write_solid_tile(int tile_code, int val);
		automatic int base = tile_code * 128;
		for (int r = 0; r < 16; r++)
			for (int k = 0; k < 8; k++)
				gfx_mem[base + r*8 + k] = {val[3:0], val[3:0]};
	endtask

	// writes one attribute-table record + a 1-entry display list pointing at it
	task automatic setup_single_sprite(
		int sprite_idx, int x_pos, int y_pos, int nx_m1, int ny_m1,
		int zoom_x_raw, int zoom_y_raw, int flip_x, int flip_y,
		int color, int pri, int code
	);
		automatic logic [15:0] wy, wx, wattr, wcodelo;
		wy      = {zoom_y_raw[3:0], ny_m1[2:0], y_pos[8:0]};
		wx      = {zoom_x_raw[3:0], nx_m1[2:0], x_pos[8:0]};
		wattr   = {flip_y[0], flip_x[0], 1'b0, color[4:0], pri[1:0], 5'd0, code[16]};
		wcodelo = code[15:0];
		at_mem[sprite_idx*4 + 0] = wy;
		at_mem[sprite_idx*4 + 1] = wx;
		at_mem[sprite_idx*4 + 2] = wattr;
		at_mem[sprite_idx*4 + 3] = wcodelo;

		dl_mem[12'hC00] = sprite_idx[15:0];
		dl_mem[12'hC01] = 16'hFFFF;
	endtask

	task automatic run_frame;
		reset = 1;
		@(posedge clk); @(posedge clk);
		reset = 0;
		@(posedge clk);
		frame_start = 1;
		@(posedge clk);
		frame_start = 0;
		// budget generously: up to 8 sub-tiles/sprite * 16 rows * (GFX_LATENCY
		// round-trip + 16 columns) + LUT round-trips, plus headroom
		for (int i = 0; i < 5000; i++) begin
			@(posedge clk);
			if (frame_done) return;
		end
		$display("TIMEOUT waiting for frame_done");
	endtask

	int errors;

	task automatic check_pixel(string label, int x, int y, int exp_written, int exp_pixel, int exp_color, int exp_pri);
		if (got_written[x][y] !== exp_written[0:0]) begin
			errors++;
			if (errors <= 20)
				$display("FAIL(%s) (%0d,%0d) written: got=%b expected=%b", label, x, y, got_written[x][y], exp_written);
			return;
		end
		if (exp_written && (got_pixel[x][y] !== exp_pixel[3:0] || got_color[x][y] !== exp_color[4:0] || got_priority[x][y] !== exp_pri[1:0])) begin
			errors++;
			if (errors <= 20)
				$display("FAIL(%s) (%0d,%0d) got=(pix=%0d col=%0d pri=%0d) expected=(pix=%0d col=%0d pri=%0d)",
						  label, x, y, got_pixel[x][y], got_color[x][y], got_priority[x][y], exp_pixel, exp_color, exp_pri);
		end
	endtask

	initial begin
		errors = 0;
		frame_start = 0;
		trans_pen0 = 0;
		trans_pen15 = 0;
		for (int i = 0; i < 4096; i++) begin dl_mem[i] = 16'h0000; at_mem[i] = 16'h0000; end
		for (int i = 0; i < 131072; i++) lut_mem[i] = 16'h0000;
		for (int i = 0; i < 8192; i++) gfx_mem[i] = 8'h00;

		// ================= Case A: 1x1, no flip =================
		clear_fb();
		write_gradient_tile(7);
		lut_mem[3] = 16'd7;   // sub_code (=code, subtile_ordinal 0) 3 -> tile 7
		setup_single_sprite(0, 100, 50, 0, 0, 0, 0, 0, 0, 5, 1, 3);
		run_frame();

		for (int r = 0; r < 16; r++)
			for (int c = 0; c < 16; c++)
				check_pixel("A", 100+c, 50+r, 1, (r+c)%16, 5, 1);
		// spot-check nothing written just outside the tile
		check_pixel("A-border", 99, 50, 0, 0, 0, 0);
		check_pixel("A-border", 116, 50, 0, 0, 0, 0);
		check_pixel("A-border", 100, 66, 0, 0, 0, 0);
		$display("Case A done");

		// ================= Case B: 1x1, flip_x =================
		clear_fb();
		// reuse tile 7's gradient pattern; flip_x means natural col (15-c) is
		// read for destination col c (sprite_zoom_src_index's flip handling)
		lut_mem[3] = 16'd7;
		setup_single_sprite(0, 150, 50, 0, 0, 0, 0, /*flip_x=*/1, 0, 5, 1, 3);
		run_frame();

		for (int r = 0; r < 16; r++)
			for (int c = 0; c < 16; c++)
				check_pixel("B", 150+c, 50+r, 1, (r + (15-c)) % 16, 5, 1);
		$display("Case B done");

		// ================= Case C: 2x1, flip_x, distinct solid tiles =================
		clear_fb();
		write_solid_tile(10, 1);   // sub_code base+0 -> tile 10, all pixel=1
		write_solid_tile(11, 2);   // sub_code base+1 -> tile 11, all pixel=2
		lut_mem[20] = 16'd10;
		lut_mem[21] = 16'd11;
		// nx=2 (nx_m1=1), flip_x=1: visitation order is dx=1 (code_base+0=20->tile10)
		// then dx=0 (code_base+1=21->tile11). Screen columns: dx_grid IS the
		// screen column (0=left tile, 1=right tile) regardless of flip -- flip
		// only reorders WHICH code is assigned to which dx_grid, per
		// sprite_subtile_step's header. So: dx_grid=0 (left, x=50..65) is
		// visited SECOND (ix=1, ordinal=1) -> code_base+1=21->tile11(pixel=2).
		// dx_grid=1 (right, x=66..81) is visited FIRST (ix=0, ordinal=0) ->
		// code_base+0=20->tile10(pixel=1).
		setup_single_sprite(0, 50, 150, 1, 0, 0, 0, /*flip_x=*/1, 0, 3, 2, 20);
		run_frame();

		for (int r = 0; r < 16; r++)
			for (int c = 0; c < 16; c++) begin
				check_pixel("C-left",  50+c, 150+r, 1, 2, 3, 2);   // tile 11
				check_pixel("C-right", 66+c, 150+r, 1, 1, 3, 2);   // tile 10
			end
		$display("Case C done");

		// ================= Case D: 1x1, no flip, trans_pen0 =================
		clear_fb();
		write_gradient_tile(7);
		lut_mem[3] = 16'd7;
		trans_pen0 = 1;
		setup_single_sprite(0, 200, 50, 0, 0, 0, 0, 0, 0, 5, 1, 3);
		run_frame();
		trans_pen0 = 0;

		for (int r = 0; r < 16; r++)
			for (int c = 0; c < 16; c++) begin
				automatic int pv = (r+c) % 16;
				if (pv == 0)
					check_pixel("D", 200+c, 50+r, 0, 0, 0, 0);
				else
					check_pixel("D", 200+c, 50+r, 1, pv, 5, 1);
			end
		$display("Case D done");

		if (errors == 0)
			$display("PASS: sprite_render_engine matches reference for all cases (A: basic 1x1, B: flip_x pixel mirror, C: multi-tile flip grid order, D: transparent pen0)");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
