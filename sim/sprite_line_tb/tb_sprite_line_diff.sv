// Differential test: the per-scanline sprite path (sprite_line_list +
// sprite_line_engine) against the retired whole-frame renderer
// (sprite_render_engine), which stays in the tree precisely to serve as
// this golden reference -- same records, same decode modules, whole frame.
//
// For every case the golden engine renders the full frame into a 2D
// capture; the DUT builds its per-frame table once, then renders each of
// the 224 lines individually, and every line is compared pixel-for-pixel
// (written/pixel/color/priority) against the golden row. Overwrite order
// (display-list order, later entries win) must match exactly, so the
// 100-sprite random case with heavy overlap is the strongest check.
//
// The DUT's ROM models use DIFFERENT latencies from the golden's (4/5 vs
// 2/3 cycles) so any accidental latency assumption in the new FSM shows up
// as a mismatch rather than surviving by coincidence.
//
// Case list:
//   A: 1x1 sprite, no flip (end-to-end sanity)
//   B: 8x8 sprite, 64 distinct gradient tiles ("large sprites" -- the case
//      the first line renderer was parked over)
//   C: 8x8 sprite, zoomed (9/16) + flip_y (FIND_ROW x zoom x flip)
//   D: 4x2 sprite, flip_x, zoom_x only
//   E: sprites crossing the top and bottom screen edges
//   F: trans_pen0 transparency
//   G: 100 random sprites, overlapping, mixed everything
//   H: hard-resync abort mid-line, then the same line re-rendered clean
//      (regression for the compounding-deficit failure)
//   I: empty display list
//   J: fully off-screen sprite (build-pass prune must not lose visible ones
//      -- G already proves that -- and must draw nothing here)

module tb_sprite_line_diff;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;
	logic trans_pen0, trans_pen15;

	// ---- shared content memories (each side has its own model FSMs) ----
	logic [15:0] dl_mem [0:4095];
	logic [15:0] at_mem [0:4095];
	logic [15:0] lut_mem [0:131071];
	logic [7:0]  gfx_mem [0:65535];

	// =====================================================================
	// GOLDEN: whole-frame renderer
	// =====================================================================
	logic         g_frame_start, g_frame_busy, g_frame_done;
	logic [11:0] g_dl_addr, g_at_addr;
	logic [15:0] g_dl_data, g_at_data;
	logic         g_lut_req, g_lut_valid;
	logic [16:0] g_lut_addr;
	logic [15:0] g_lut_data;
	logic         g_gfx_req, g_gfx_valid;
	logic [22:0] g_gfx_addr;
	logic [63:0] g_gfx_data;
	logic         g_we;
	logic [8:0]  g_x;
	logic [7:0]  g_y;
	logic [3:0]  g_pixel;
	logic [4:0]  g_color;
	logic [1:0]  g_priority;

	sprite_render_engine u_golden (
		.clk(clk), .reset(reset),
		.frame_start(g_frame_start), .frame_busy(g_frame_busy), .frame_done(g_frame_done),
		.trans_pen0(trans_pen0), .trans_pen15(trans_pen15),
		.dl_addr(g_dl_addr), .dl_data(g_dl_data),
		.at_addr(g_at_addr), .at_data(g_at_data),
		.lut_req(g_lut_req), .lut_addr(g_lut_addr), .lut_valid(g_lut_valid), .lut_data(g_lut_data),
		.gfxrom_req(g_gfx_req), .gfxrom_addr(g_gfx_addr),
		.gfxrom_valid(g_gfx_valid), .gfxrom_data(g_gfx_data),
		.fb_we(g_we), .fb_x(g_x), .fb_y(g_y),
		.fb_pixel(g_pixel), .fb_color(g_color), .fb_priority(g_priority)
	);

	always_ff @(posedge clk) g_dl_data <= dl_mem[g_dl_addr];
	always_ff @(posedge clk) g_at_data <= at_mem[g_at_addr];

	localparam int G_LUT_LAT = 2, G_GFX_LAT = 3;
	logic g_lut_req_d;  int g_lut_cnt;
	always_ff @(posedge clk) begin
		g_lut_valid <= 1'b0;
		g_lut_req_d <= g_lut_req;
		if (g_lut_req && !g_lut_req_d) g_lut_cnt <= 0;
		else if (g_lut_req && g_lut_req_d) begin
			if (g_lut_cnt == G_LUT_LAT - 1) begin
				g_lut_valid <= 1'b1;
				g_lut_data  <= lut_mem[g_lut_addr];
			end else g_lut_cnt <= g_lut_cnt + 1;
		end
	end
	logic g_gfx_req_d;  int g_gfx_cnt;
	always_ff @(posedge clk) begin
		g_gfx_valid <= 1'b0;
		g_gfx_req_d <= g_gfx_req;
		if (g_gfx_req && !g_gfx_req_d) g_gfx_cnt <= 0;
		else if (g_gfx_req && g_gfx_req_d) begin
			if (g_gfx_cnt == G_GFX_LAT - 1) begin
				g_gfx_valid <= 1'b1;
				g_gfx_data  <= {gfx_mem[g_gfx_addr[15:0]+0], gfx_mem[g_gfx_addr[15:0]+1],
								  gfx_mem[g_gfx_addr[15:0]+2], gfx_mem[g_gfx_addr[15:0]+3],
								  gfx_mem[g_gfx_addr[15:0]+4], gfx_mem[g_gfx_addr[15:0]+5],
								  gfx_mem[g_gfx_addr[15:0]+6], gfx_mem[g_gfx_addr[15:0]+7]};
			end else g_gfx_cnt <= g_gfx_cnt + 1;
		end
	end

	logic         ref_written [0:319][0:223];
	logic [3:0]  ref_pixel     [0:319][0:223];
	logic [4:0]  ref_color     [0:319][0:223];
	logic [1:0]  ref_priority [0:319][0:223];
	always @(posedge clk) begin
		if (g_we) begin
			ref_written[g_x][g_y]  <= 1'b1;
			ref_pixel[g_x][g_y]     <= g_pixel;
			ref_color[g_x][g_y]     <= g_color;
			ref_priority[g_x][g_y] <= g_priority;
		end
	end

	// =====================================================================
	// DUT: build pass + line engine
	// =====================================================================
	logic         d_build_start, d_build_busy, d_build_done;
	logic [11:0] d_dl_addr, d_at_addr;
	logic [15:0] d_dl_data, d_at_data;
	logic [9:0]  d_scan_addr, d_rec_addr;
	logic [17:0] d_scan_ytest;
	logic [63:0] d_rec_data;
	logic [10:0] d_count;

	sprite_line_list u_list (
		.clk(clk), .reset(reset),
		.build_start(d_build_start), .build_busy(d_build_busy), .build_done(d_build_done),
		.dl_addr(d_dl_addr), .dl_data(d_dl_data),
		.at_addr(d_at_addr), .at_data(d_at_data),
		.scan_addr(d_scan_addr), .scan_ytest(d_scan_ytest),
		.rec_addr(d_rec_addr), .rec_data(d_rec_data),
		.count(d_count)
	);

	always_ff @(posedge clk) d_dl_data <= dl_mem[d_dl_addr];
	always_ff @(posedge clk) d_at_data <= at_mem[d_at_addr];

	logic         d_line_tick, d_line_start;
	logic [7:0]  d_render_line;
	logic         d_busy, d_ovr_ev;
	logic         d_lut_req, d_lut_valid;
	logic [16:0] d_lut_addr;
	logic [15:0] d_lut_data;
	logic         d_gfx_req, d_gfx_valid;
	logic [22:0] d_gfx_addr;
	logic [63:0] d_gfx_data;
	logic         d_we;
	logic [8:0]  d_x;
	logic [3:0]  d_pixel;
	logic [4:0]  d_color;
	logic [1:0]  d_priority;

	sprite_line_engine u_dut (
		.clk(clk), .reset(reset),
		.line_tick(d_line_tick), .line_start(d_line_start),
		.render_line(d_render_line),
		.busy(d_busy), .ovr_ev(d_ovr_ev),
		.trans_pen0(trans_pen0), .trans_pen15(trans_pen15),
		.scan_addr(d_scan_addr), .scan_ytest(d_scan_ytest),
		.rec_addr(d_rec_addr), .rec_data(d_rec_data), .count(d_count),
		.lut_req(d_lut_req), .lut_addr(d_lut_addr), .lut_valid(d_lut_valid), .lut_data(d_lut_data),
		.gfxrom_req(d_gfx_req), .gfxrom_addr(d_gfx_addr),
		.gfxrom_valid(d_gfx_valid), .gfxrom_data(d_gfx_data),
		.fb_we(d_we), .fb_x(d_x),
		.fb_pixel(d_pixel), .fb_color(d_color), .fb_priority(d_priority)
	);

	// deliberately different latencies from the golden side
	localparam int D_LUT_LAT = 4, D_GFX_LAT = 5;

	// ---- LUT path: the REAL sdram_narrow_bridge, not a behavioural model --
	// The first version of this bench modelled the LUT as a counter that
	// always answered cleanly. Hardware disagreed (wrong tile numbers in
	// large sprites) while this bench passed, which is the classic signature
	// of a transport-protocol violation the model cannot express. The real
	// bridge has a granule CACHE (so a second request inside the same 8-byte
	// granule answers in ONE cycle instead of ~20 -- the line engine walks
	// consecutive ordinals, so most of its requests are cache hits, a regime
	// the counter model never produced), and a B_DRAIN state that exists
	// precisely because a held-req client "would re-latch the still-high req
	// and serve a spurious second hit". sprite_line_engine holds lut_req
	// until valid, so it is exactly that kind of client.
	logic         d_g_req, d_g_valid;
	logic [24:0] d_g_addr;
	logic [63:0] d_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_lut_bridge (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(d_lut_req), .addr({6'd0, d_lut_addr, 1'b0} + 25'd0),
		.valid(d_lut_valid), .data(d_lut_data),
		.g_req(d_g_req), .g_addr(d_g_addr), .g_valid(d_g_valid), .g_data(d_g_data)
	);

	// Granule side: hold g_req until g_valid, one outstanding transaction,
	// matching sdram_arbiter6's single-transaction design. Latency is varied
	// so nothing can pass by depending on a fixed round trip.
	int  d_g_cnt;
	int  d_g_lat;
	always_ff @(posedge clk) begin
		d_g_valid <= 1'b0;
		if (!d_g_req) begin
			d_g_cnt <= 0;
			d_g_lat <= 6 + ($urandom() % 14);   // 6..19 cycles
		end else if (d_g_cnt >= d_g_lat) begin
			d_g_valid <= 1'b1;
			// granule = 4 consecutive 16-bit LUT words, little-endian packed
			d_g_data  <= {lut_mem[{d_g_addr[24:3], 2'd3}], lut_mem[{d_g_addr[24:3], 2'd2}],
							lut_mem[{d_g_addr[24:3], 2'd1}], lut_mem[{d_g_addr[24:3], 2'd0}]};
			d_g_cnt    <= 0;
		end else begin
			d_g_cnt <= d_g_cnt + 1;
		end
	end
	logic d_gfx_req_d;  int d_gfx_cnt;
	always_ff @(posedge clk) begin
		d_gfx_valid <= 1'b0;
		d_gfx_req_d <= d_gfx_req;
		if (d_gfx_req && !d_gfx_req_d) d_gfx_cnt <= 0;
		else if (d_gfx_req && d_gfx_req_d) begin
			if (d_gfx_cnt == D_GFX_LAT - 1) begin
				d_gfx_valid <= 1'b1;
				d_gfx_data  <= {gfx_mem[d_gfx_addr[15:0]+0], gfx_mem[d_gfx_addr[15:0]+1],
								  gfx_mem[d_gfx_addr[15:0]+2], gfx_mem[d_gfx_addr[15:0]+3],
								  gfx_mem[d_gfx_addr[15:0]+4], gfx_mem[d_gfx_addr[15:0]+5],
								  gfx_mem[d_gfx_addr[15:0]+6], gfx_mem[d_gfx_addr[15:0]+7]};
			end else d_gfx_cnt <= d_gfx_cnt + 1;
		end
	end

	// per-line capture
	logic         line_written [0:319];
	logic [3:0]  line_pixel     [0:319];
	logic [4:0]  line_color     [0:319];
	logic [1:0]  line_priority [0:319];
	always @(posedge clk) begin
		if (d_we) begin
			line_written[d_x]  <= 1'b1;
			line_pixel[d_x]     <= d_pixel;
			line_color[d_x]     <= d_color;
			line_priority[d_x] <= d_priority;
		end
	end

	// =====================================================================
	// helpers
	// =====================================================================
	int errors;
	int dl_len;

	task automatic clear_content;
		for (int i = 0; i < 4096; i++) begin dl_mem[i] = 16'h0000; at_mem[i] = 16'h0000; end
		dl_mem[12'hC00] = 16'hFFFF;
		dl_len = 0;
	endtask

	task automatic clear_ref;
		for (int x = 0; x < 320; x++)
			for (int y = 0; y < 224; y++)
				ref_written[x][y] = 1'b0;
	endtask

	// writes one attribute record; appends it to the display list
	task automatic add_sprite(
		int sprite_idx, int x_pos, int y_pos, int nx_m1, int ny_m1,
		int zoom_x_raw, int zoom_y_raw, int flip_x, int flip_y,
		int color, int pri, int code
	);
		at_mem[sprite_idx*4 + 0] = {zoom_y_raw[3:0], ny_m1[2:0], y_pos[8:0]};
		at_mem[sprite_idx*4 + 1] = {zoom_x_raw[3:0], nx_m1[2:0], x_pos[8:0]};
		at_mem[sprite_idx*4 + 2] = {flip_y[0], flip_x[0], 1'b0, color[4:0], pri[1:0], 5'd0, code[16]};
		at_mem[sprite_idx*4 + 3] = code[15:0];
		dl_mem[12'hC00 + dl_len] = sprite_idx[15:0];
		dl_len++;
		dl_mem[12'hC00 + dl_len] = 16'hFFFF;
	endtask

	// Tile content MUST differ between codes that are 16 apart. The obvious
	// generator, (r + 2k + tile_code) % 16, does NOT: it makes every pair of
	// tiles whose codes differ by a multiple of 16 byte-identical. That is
	// precisely the error class produced by a truncated sub-tile ordinal --
	// a 4-bit wrap is always a multiple of 16 -- so the original bench was
	// structurally incapable of seeing the wrong-tile defect that shipped,
	// and reported ALL PASS against a knowingly broken engine (verified by
	// mutation). Folding in tile_code>>4 breaks that periodicity: codes c
	// and c+16 now differ by 17 mod 16 = 1.
	task automatic write_gradient_tile(int tile_code);
		automatic int base = tile_code * 128;
		automatic int h     = (tile_code + (tile_code >> 4)) % 16;
		for (int r = 0; r < 16; r++)
			for (int k = 0; k < 8; k++) begin
				automatic int p0 = (r + 2*k + h) % 16;
				automatic int p1 = (r + 2*k + 1 + h) % 16;
				gfx_mem[base + r*8 + k] = {p0[3:0], p1[3:0]};
			end
	endtask

	task automatic run_golden;
		clear_ref();
		reset = 1;
		@(posedge clk); @(posedge clk);
		reset = 0;
		@(posedge clk);
		g_frame_start = 1;
		@(posedge clk);
		g_frame_start = 0;
		for (int i = 0; i < 2_000_000; i++) begin
			@(posedge clk);
			if (g_frame_done) return;
		end
		$display("TIMEOUT: golden frame_done");
		errors++;
	endtask

	task automatic run_build;
		// golden run left reset released; build from the same content
		d_build_start = 1;
		@(posedge clk);
		d_build_start = 0;
		for (int i = 0; i < 50_000; i++) begin
			@(posedge clk);
			if (d_build_done) return;
		end
		$display("TIMEOUT: build_done");
		errors++;
	endtask

	// Render one line under the REAL per-line budget: line_tick arrives every
	// `period` cycles whether or not the engine has finished, exactly as
	// video_timing drives it. Returns 1 if the line was cut short.
	//
	// This is the regime the rest of the bench cannot reach, because every
	// other case here gives a line unlimited time. On hardware the engine is
	// aborted mid-transaction constantly under load, and an abort that leaves
	// the SDRAM transport out of step would show up as WRONG pixels rather
	// than missing ones -- the reported "some tiles correct, wrong tile
	// numbers for others in large sprites".
	task automatic run_line_budgeted(int line, int period, output bit clipped);
		for (int x = 0; x < 320; x++) line_written[x] = 1'b0;
		clipped = 0;
		d_render_line = line[7:0];
		d_line_start   = 1;
		@(posedge clk);
		d_line_start = 0;
		for (int i = 0; i < period; i++) begin
			@(posedge clk);
			if (!d_busy && i > 2) return;   // finished inside budget
		end
		// budget expired -- fire the resync exactly as video_timing would
		clipped     = 1;
		d_line_tick = 1;
		@(posedge clk);
		d_line_tick = 0;
		for (int i = 0; i < 4000; i++) begin
			@(posedge clk);
			if (!d_busy) return;
		end
		$display("FAIL(budget) line %0d: engine never drained after resync", line);
		errors++;
	endtask

	// A clipped line may be MISSING pixels; it must never contain a WRONG
	// one. Anything written has to match the reference exactly.
	task automatic check_line_no_wrong(string label, int line);
		for (int x = 0; x < 320; x++) begin
			if (line_written[x]) begin
				if (!ref_written[x][line]) begin
					errors++;
					if (errors <= 25)
						$display("FAIL(%s) line %0d x=%0d: wrote a pixel the reference does not have",
								  label, line, x);
				end else if (line_pixel[x] !== ref_pixel[x][line] ||
							 line_color[x] !== ref_color[x][line] ||
							 line_priority[x] !== ref_priority[x][line]) begin
					errors++;
					if (errors <= 25)
						$display("FAIL(%s) line %0d x=%0d WRONG dut=(%0d,%0d,%0d) ref=(%0d,%0d,%0d)",
								  label, line, x, line_pixel[x], line_color[x], line_priority[x],
								  ref_pixel[x][line], ref_color[x][line], ref_priority[x][line]);
				end
			end
		end
	endtask

	task automatic run_line(int line);
		for (int x = 0; x < 320; x++) line_written[x] = 1'b0;
		d_render_line = line[7:0];
		d_line_start   = 1;
		@(posedge clk);
		d_line_start   = 0;
		for (int i = 0; i < 200_000; i++) begin
			@(posedge clk);
			if (!d_busy) return;
		end
		$display("TIMEOUT: line %0d still busy", line);
		errors++;
	endtask

	int cmp_written;   // how many reference pixels were actually compared
	task automatic check_line(string label, int line);
		for (int x = 0; x < 320; x++) begin
			if (ref_written[x][line]) cmp_written++;
			if (line_written[x] !== ref_written[x][line]) begin
				errors++;
				if (errors <= 25)
					$display("FAIL(%s) line %0d x=%0d written: dut=%b ref=%b",
							  label, line, x, line_written[x], ref_written[x][line]);
			end else if (ref_written[x][line] &&
						 (line_pixel[x] !== ref_pixel[x][line] ||
						  line_color[x] !== ref_color[x][line] ||
						  line_priority[x] !== ref_priority[x][line])) begin
				errors++;
				if (errors <= 25)
					$display("FAIL(%s) line %0d x=%0d dut=(%0d,%0d,%0d) ref=(%0d,%0d,%0d)",
							  label, line, x, line_pixel[x], line_color[x], line_priority[x],
							  ref_pixel[x][line], ref_color[x][line], ref_priority[x][line]);
			end
		end
	endtask

	task automatic diff_all_lines(string label);
		cmp_written = 0;
		run_golden();
		run_build();
		for (int line = 0; line < 224; line++) begin
			run_line(line);
			check_line(label, line);
		end
		if (cmp_written == 0 && label != "I" && label != "J") begin
			errors++;
			$display("FAIL(%s) compared ZERO reference pixels -- the case tests nothing", label);
		end
	endtask

	int seed;
	initial begin
		errors = 0;
		g_frame_start = 0;
		d_build_start = 0;
		d_line_tick   = 0;
		d_line_start  = 0;
		d_render_line = 0;
		trans_pen0 = 0;
		trans_pen15 = 0;
		for (int i = 0; i < 131072; i++) lut_mem[i] = 16'h0000;
		for (int i = 0; i < 65536; i++) gfx_mem[i] = 8'h00;
		// identity-ish LUT over the codes the cases use
		for (int i = 0; i < 512; i++) lut_mem[i] = i[15:0];
		for (int i = 0; i < 512; i++) write_gradient_tile(i);

		// ---------------- A: 1x1, no flip ----------------
		clear_content();
		add_sprite(0, 100, 60, 0, 0, 0, 0, 0, 0, 7, 2, 5);
		diff_all_lines("A");

		// ---------------- B: 8x8 large sprite ----------------
		clear_content();
		add_sprite(1, 60, 40, 7, 7, 0, 0, 0, 0, 3, 1, 64);
		diff_all_lines("B");

		// ---------------- C: 8x8 zoomed + flip_y ----------------
		clear_content();
		add_sprite(2, 30, 20, 7, 7, 9, 9, 0, 1, 12, 3, 128);
		diff_all_lines("C");

		// ---------------- D: 4x2, flip_x, zoom_x only ----------------
		clear_content();
		add_sprite(3, 200, 150, 3, 1, 5, 0, 1, 0, 20, 0, 200);
		diff_all_lines("D");

		// ---------------- E: screen edges ----------------
		clear_content();
		add_sprite(4, 10, -8, 1, 1, 0, 0, 0, 0, 9, 1, 300);     // clipped top
		add_sprite(5, 250, 200, 1, 3, 0, 0, 0, 0, 15, 2, 320);  // crosses bottom
		diff_all_lines("E");

		// ---------------- F: trans_pen0 ----------------
		clear_content();
		trans_pen0 = 1;
		add_sprite(6, 80, 100, 1, 1, 0, 0, 0, 0, 11, 2, 340);
		diff_all_lines("F");
		trans_pen0 = 0;

		// ---------------- G: 100 random overlapping sprites ----------------
		clear_content();
		seed = 32'hC0FFEE01;
		for (int k = 0; k < 100; k++) begin
			automatic int xp = ($urandom(seed+k) % 400) - 40;
			automatic int yp = ($urandom() % 300) - 40;
			automatic int nx = $urandom() % 8;
			automatic int ny = $urandom() % 8;
			automatic int zx = $urandom() % 16;
			automatic int zy = $urandom() % 16;
			automatic int fx = $urandom() % 2;
			automatic int fy = $urandom() % 2;
			automatic int co = $urandom() % 32;
			automatic int pr = $urandom() % 4;
			automatic int cd = $urandom() % 448;
			add_sprite(k, xp, yp, nx, ny, zx, zy, fx, fy, co, pr, cd);
		end
		diff_all_lines("G");

		// ---------------- H: abort mid-line, then clean re-render ----------------
		clear_content();
		add_sprite(1, 60, 40, 7, 7, 0, 0, 0, 0, 3, 1, 64);
		run_golden();
		run_build();
		// start line 45 (inside the sprite), abort ~30 cycles in
		for (int x = 0; x < 320; x++) line_written[x] = 1'b0;
		d_render_line = 8'd45;
		d_line_start = 1; @(posedge clk); d_line_start = 0;
		repeat (30) @(posedge clk);
		d_line_tick = 1; @(posedge clk); d_line_tick = 0;
		begin
			automatic int drained = 0;
			for (int i = 0; i < 200; i++) begin
				@(posedge clk);
				if (d_we) begin
					errors++;
					$display("FAIL(H) write after abort");
				end
				if (!d_busy) begin drained = 1; break; end
			end
			if (!drained) begin
				errors++;
				$display("FAIL(H) drain did not complete");
			end
		end
		// the same line must now render perfectly from scratch
		run_line(45);
		check_line("H", 45);

		// ---------------- I: empty list ----------------
		clear_content();
		diff_all_lines("I");

		// ---------------- J: fully off-screen sprite ----------------
		clear_content();
		add_sprite(7, 340, 230, 7, 7, 0, 0, 0, 0, 1, 1, 64);
		diff_all_lines("J");
		if (d_count !== 11'd0) begin
			errors++;
			$display("FAIL(J) off-screen sprite not pruned (count=%0d)", d_count);
		end

		// ---------------- K: real per-line budget, heavy scene ----------------
		// 100 overlapping sprites rendered under the hardware line budget
		// (5472 clk), with the resync firing whenever a line overruns. Every
		// pixel that IS written must still be correct.
		begin
			automatic int clipped_lines = 0;
			automatic bit clipped;
			clear_content();
			seed = 32'hBEEF0042;
			for (int k = 0; k < 100; k++) begin
				automatic int xp = ($urandom(seed+k) % 400) - 40;
				automatic int yp = ($urandom() % 300) - 40;
				automatic int nx = $urandom() % 8;
				automatic int ny = $urandom() % 8;
				automatic int zx = $urandom() % 16;
				automatic int zy = $urandom() % 16;
				automatic int fx = $urandom() % 2;
				automatic int fy = $urandom() % 2;
				automatic int co = $urandom() % 32;
				automatic int pr = $urandom() % 4;
				automatic int cd = $urandom() % 448;
				add_sprite(k, xp, yp, nx, ny, zx, zy, fx, fy, co, pr, cd);
			end
			run_golden();
			run_build();
			for (int line = 0; line < 224; line++) begin
				run_line_budgeted(line, 5472, clipped);
				if (clipped) clipped_lines++;
				check_line_no_wrong("K", line);
			end
			$display("K: %0d/224 lines clipped by the resync at the 5472-clk budget",
					  clipped_lines);
		end

		if (errors == 0) $display("ALL PASS");
		else              $display("%0d ERRORS", errors);
		$finish;
	end

endmodule
