// RETIRED FROM SYNTHESIS (2026-08-30): replaced by the per-scanline path
// (sprite_line_list + sprite_line_engine + sprite_line_buffer) and removed
// from both .qsf file lists. Kept in the tree as the verified GOLDEN
// REFERENCE for the line path's differential testbench -- it renders the
// same records through the same decode modules, whole-frame.
// Top-level sprite frame renderer -- chains every already-verified sprite
// module together per docs/phase1_video_engine.md's "Sprite render engine:
// pipeline design". Renders one full display-list pass into a frame buffer
// via a single write port; the actual double-buffered frame buffer memory,
// and the vblank-driven bank-select toggle, live outside this module (kept
// separate and testable independently, same split as the tilemap engine
// treating VRAM as an external BRAM it only has ports into).
//
// Two integration gotchas are load-bearing here and documented in the
// design doc, not repeated in full inline:
//   - tile_row_decode's own flip_x MUST be tied to 0 -- sprite_zoom_src_index
//     already produces a flip-aware source index into the tile's natural
//     (unflipped) pixel order; flipping again here would cancel out.
//   - trans_pen0/trans_pen15 are live per-frame inputs (spriteram control
//     word bits 2/3), not fixed at synthesis time.

module sprite_render_engine (
	input  logic clk,
	input  logic reset,

	input  logic frame_start,   // pulse: begin rendering a frame
	output logic frame_busy,
	output logic frame_done,     // pulse: entire display list processed

	input  logic trans_pen0,    // spriteram control word bit 2
	input  logic trans_pen15,   // spriteram control word bit 3

	// display list BRAM port (word offsets 0xC00-0xFFE)
	output logic [11:0] dl_addr,
	input  logic [15:0] dl_data,

	// attribute table BRAM port (word offsets 0x000-0xBFF) -- independent
	// dual-port read, see sprite_record_fetch.sv
	output logic [11:0] at_addr,
	input  logic [15:0] at_data,

	// spritelut ROM, req/valid (latency-agnostic)
	output logic         lut_req,
	output logic [16:0] lut_addr,
	input  logic         lut_valid,
	input  logic [15:0] lut_data,

	// sprite gfx ROM, req/valid -- byte address, one bit wider than the
	// tilemap engine's gfxrom_addr since sprite gfx ROMs run up to 8MB
	output logic         gfxrom_req,
	output logic [22:0] gfxrom_addr,
	input  logic         gfxrom_valid,
	input  logic [63:0] gfxrom_data,

	// frame buffer write port -- caller owns the actual memory
	output logic         fb_we,
	output logic [8:0]  fb_x,        // 0-319
	output logic [7:0]  fb_y,        // 0-223
	output logic [3:0]  fb_pixel,    // pixel/palette-nibble index 0-15
	output logic [4:0]  fb_color,    // sprite color field 0-31
	output logic [1:0]  fb_priority  // sprite priority field 0-3 (primask derived downstream)
);

	// ---- stage 1: display list walker ----
	logic         dl_start, dl_busy, dl_advance;
	logic         dl_entry_valid, dl_done;
	logic [9:0]  dl_sprite_index;

	sprite_display_list_walker u_walker (
		.clk(clk), .reset(reset),
		.start(dl_start), .busy(dl_busy), .advance(dl_advance),
		.sram_addr(dl_addr), .sram_data(dl_data),
		.entry_valid(dl_entry_valid), .sprite_index(dl_sprite_index), .done(dl_done)
	);

	// ---- stage 2: per-sprite attribute record fetch ----
	logic         rf_start, rf_busy, rf_record_valid;
	logic [15:0] rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo;

	sprite_record_fetch u_record_fetch (
		.clk(clk), .reset(reset),
		.start(rf_start), .sprite_index(dl_sprite_index), .busy(rf_busy),
		.sram_addr(at_addr), .sram_data(at_data),
		.record_valid(rf_record_valid),
		.word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo)
	);

	// ---- stage 3/4/5: combinational decode chain (stable for the whole sprite) ----
	logic [3:0]        rd_zoom_y_raw, rd_zoom_x_raw, rd_ny, rd_nx;
	logic signed [9:0] rd_y_pos, rd_x_pos;
	logic               rd_flip_y, rd_flip_x;
	logic [4:0]        rd_color;
	logic [1:0]        rd_priority_field;
	logic [16:0]       rd_code;

	sprite_record_decode u_record_decode (
		.word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo),
		.zoom_y_raw(rd_zoom_y_raw), .zoom_x_raw(rd_zoom_x_raw), .ny(rd_ny), .nx(rd_nx),
		.y_pos(rd_y_pos), .x_pos(rd_x_pos), .flip_y(rd_flip_y), .flip_x(rd_flip_x),
		.color(rd_color), .priority_field(rd_priority_field), .code(rd_code)
	);

	logic signed [9:0] pt_x_adj, pt_y_adj;
	logic [5:0]        pt_zoom_x_transformed, pt_zoom_y_transformed;

	sprite_pos_transform u_pos_transform (
		.x_pos(rd_x_pos), .y_pos(rd_y_pos), .nx(rd_nx), .ny(rd_ny),
		.zoom_x_raw(rd_zoom_x_raw), .zoom_y_raw(rd_zoom_y_raw),
		.x_adj(pt_x_adj), .y_adj(pt_y_adj),
		.zoom_x_transformed(pt_zoom_x_transformed), .zoom_y_transformed(pt_zoom_y_transformed)
	);

	logic [4:0]  zl_dst_size_x, zl_dst_size_y;   // 9-16, matches sprite_zoom_lut's actual port width
	logic [16:0] zl_dx_x, zl_dx_y;

	sprite_zoom_lut u_zoom_lut_x (.raw_zoom(rd_zoom_x_raw), .dst_size(zl_dst_size_x), .dx(zl_dx_x));
	sprite_zoom_lut u_zoom_lut_y (.raw_zoom(rd_zoom_y_raw), .dst_size(zl_dst_size_y), .dx(zl_dx_y));

	// ---- PIPELINE STAGE A: per-sprite constants, registered once per sprite ----
	// Everything above is a pure function of sprite_record_fetch's rf_word_*
	// outputs, which are constant for a whole sprite -- evaluating it
	// combinationally inside the S_COL inner loop, in series with the
	// sub-tile step and screen-position arithmetic, is the design's worst
	// timing path. Registering costs only latency, at points where the FSM
	// already waits on an SDRAM round-trip.
	logic [3:0]        a_nx, a_ny;
	logic              a_flip_x, a_flip_y;
	logic [4:0]        a_color;
	logic [1:0]        a_priority;
	logic [16:0]       a_code;
	logic signed [9:0] a_x_adj, a_y_adj;
	logic [5:0]        a_zoom_x_t, a_zoom_y_t;
	logic [4:0]        a_dst_size_x, a_dst_size_y;
	logic [16:0]       a_dx_x, a_dx_y;

	// ---- sub-tile / row / column loop counters ----
	logic [3:0] ix, iy;
	logic [5:0] subtile_ordinal;
	logic [3:0] dst_row, dst_col;

	logic signed [9:0] st_sub_x, st_sub_y;
	logic [16:0]       st_sub_code;

	sprite_subtile_step u_subtile_step (
		.ix(ix), .iy(iy), .nx(a_nx), .ny(a_ny), .flip_x(a_flip_x), .flip_y(a_flip_y),
		.x_adj(a_x_adj), .y_adj(a_y_adj),
		.zoom_x_transformed(a_zoom_x_t), .zoom_y_transformed(a_zoom_y_t),
		.subtile_ordinal(subtile_ordinal), .code_base(a_code),
		.sub_x(st_sub_x), .sub_y(st_sub_y), .sub_code(st_sub_code)
	);

	// ---- PIPELINE STAGE B: sub-tile origin, registered ----
	// sub_x/sub_y change only when ix/iy/subtile_ordinal do, i.e. at sub-tile
	// boundaries, and the FSM always passes through S_LUT_WAIT (an SDRAM
	// round-trip) and S_ROW_WAIT before the S_COL loop reads them, so a
	// free-running register is settled well before use.
	//
	// sub_code is deliberately NOT registered: it feeds lut_addr, which must be
	// valid while lut_req is asserted in S_LUT_WAIT. It is only
	// code_base + subtile_ordinal, so it is short anyway.
	logic signed [9:0] st_sub_x_r, st_sub_y_r;
	always_ff @(posedge clk) begin
		st_sub_x_r <= st_sub_x;
		st_sub_y_r <= st_sub_y;
	end

	// ---- spritelut ROM address (trivial, no separate module -- masking
	// is a no-op for Phase 1's 256KB/131072-entry ROM, see phase1_video_engine.md) ----
	assign lut_addr = st_sub_code & 17'h1FFFF;

	// ---- gfx ROM row address / row decode ----
	logic [15:0] tile_code_r;
	logic [3:0]  zsi_src_row, zsi_src_col;

	// sprite_zoom_src_index's dst_size port is 4 bits: safe to pass the low
	// 4 bits of the true 5-bit value here specifically because that module
	// only ever uses dst_size as "dst_size-1-col" inside 4-bit (mod-16)
	// arithmetic, and 16 mod 16 == 0, so the truncated value aliases to the
	// same wrapped result the true 5-bit value would produce. Re-verified
	// this deliberately rather than assuming it -- do not copy this
	// truncation pattern elsewhere without the same mod-16 justification.
	sprite_zoom_src_index u_zsi_y (
		.col(dst_row), .dst_size(a_dst_size_y[3:0]), .dx(a_dx_y), .flip(a_flip_y), .src_index(zsi_src_row)
	);
	sprite_zoom_src_index u_zsi_x (
		.col(dst_col), .dst_size(a_dst_size_x[3:0]), .dx(a_dx_x), .flip(a_flip_x), .src_index(zsi_src_col)
	);

	assign gfxrom_addr = {tile_code_r, zsi_src_row, 3'b000};

	logic [7:0] row_bytes_r [0:7];
	logic [3:0] row_pixel [0:15];

	tile_row_decode u_row_decode (
		.row_bytes(row_bytes_r), .flip_x(1'b0), .pixel(row_pixel)
	);

	logic [3:0] cur_pixel;
	assign cur_pixel = row_pixel[zsi_src_col];

	logic opaque;
	assign opaque = !((cur_pixel == 4'd0 && trans_pen0) || (cur_pixel == 4'd15 && trans_pen15));

	logic signed [10:0] screen_x_full, screen_y_full;
	assign screen_x_full = $signed({st_sub_x_r[9], st_sub_x_r}) + $signed({7'd0, dst_col});
	assign screen_y_full = $signed({st_sub_y_r[9], st_sub_y_r}) + $signed({7'd0, dst_row});

	logic onscreen;
	assign onscreen = (screen_x_full >= 0) && (screen_x_full < 11'sd320) &&
						(screen_y_full >= 0) && (screen_y_full < 11'sd224);

	// ---- FSM ----
	typedef enum logic [2:0] {S_IDLE, S_WALK_WAIT, S_RECORD_WAIT, S_LUT_WAIT, S_ROW_WAIT, S_COL} state_t;
	state_t state;

	assign frame_busy = (state != S_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state           <= S_IDLE;
			dl_start        <= 1'b0;
			dl_advance      <= 1'b0;
			rf_start        <= 1'b0;
			lut_req         <= 1'b0;
			gfxrom_req      <= 1'b0;
			frame_done      <= 1'b0;
			fb_we           <= 1'b0;
			ix              <= 4'd0;
			iy              <= 4'd0;
			subtile_ordinal <= 6'd0;
			dst_row         <= 4'd0;
			dst_col         <= 4'd0;
			tile_code_r     <= 16'd0;
			a_nx <= 4'd1; a_ny <= 4'd1; a_flip_x <= 1'b0; a_flip_y <= 1'b0;
			a_color <= 5'd0; a_priority <= 2'd0; a_code <= 17'd0;
			a_x_adj <= 10'sd0; a_y_adj <= 10'sd0;
			a_zoom_x_t <= 6'd32; a_zoom_y_t <= 6'd32;
			a_dst_size_x <= 5'd16; a_dst_size_y <= 5'd16;
			a_dx_x <= 17'd0; a_dx_y <= 17'd0;
			for (int i = 0; i < 8; i++) row_bytes_r[i] <= 8'd0;
		end else begin
			dl_start   <= 1'b0;
			dl_advance <= 1'b0;
			rf_start   <= 1'b0;
			frame_done <= 1'b0;
			fb_we      <= 1'b0;

			case (state)
				S_IDLE: begin
					if (frame_start) begin
						dl_start <= 1'b1;
						state     <= S_WALK_WAIT;
					end
				end

				S_WALK_WAIT: begin
					if (dl_entry_valid) begin
						rf_start <= 1'b1;
						state     <= S_RECORD_WAIT;
					end else if (dl_done) begin
						frame_done <= 1'b1;
						state       <= S_IDLE;
					end
				end

				S_RECORD_WAIT: begin
					if (rf_record_valid) begin
						ix              <= 4'd0;
						iy              <= 4'd0;
						subtile_ordinal <= 6'd0;
						// stage A: capture everything derived from this
						// sprite's record, once, instead of re-deriving it
						// every cycle of the inner loop
						a_nx         <= rd_nx;
						a_ny         <= rd_ny;
						a_flip_x     <= rd_flip_x;
						a_flip_y     <= rd_flip_y;
						a_color      <= rd_color;
						a_priority   <= rd_priority_field;
						a_code       <= rd_code;
						a_x_adj      <= pt_x_adj;
						a_y_adj      <= pt_y_adj;
						a_zoom_x_t   <= pt_zoom_x_transformed;
						a_zoom_y_t   <= pt_zoom_y_transformed;
						a_dst_size_x <= zl_dst_size_x;
						a_dst_size_y <= zl_dst_size_y;
						a_dx_x       <= zl_dx_x;
						a_dx_y       <= zl_dx_y;
						lut_req          <= 1'b1;
						state             <= S_LUT_WAIT;
					end
				end

				S_LUT_WAIT: begin
					if (lut_valid) begin
						tile_code_r <= lut_data;
						lut_req      <= 1'b0;
						dst_row      <= 4'd0;
						gfxrom_req  <= 1'b1;
						state         <= S_ROW_WAIT;
					end
				end

				S_ROW_WAIT: begin
					if (gfxrom_valid) begin
						row_bytes_r[0] <= gfxrom_data[63:56];
						row_bytes_r[1] <= gfxrom_data[55:48];
						row_bytes_r[2] <= gfxrom_data[47:40];
						row_bytes_r[3] <= gfxrom_data[39:32];
						row_bytes_r[4] <= gfxrom_data[31:24];
						row_bytes_r[5] <= gfxrom_data[23:16];
						row_bytes_r[6] <= gfxrom_data[15:8];
						row_bytes_r[7] <= gfxrom_data[7:0];
						gfxrom_req      <= 1'b0;
						dst_col          <= 4'd0;
						state             <= S_COL;
					end
				end

				S_COL: begin
					if (onscreen && opaque) begin
						fb_we       <= 1'b1;
						fb_x         <= screen_x_full[8:0];
						fb_y         <= screen_y_full[7:0];
						fb_pixel    <= cur_pixel;
						fb_color    <= a_color;
						fb_priority <= a_priority;
					end

					if ({1'b0, dst_col} != a_dst_size_x - 5'd1) begin
						dst_col <= dst_col + 4'd1;
						state    <= S_COL;
					end else if ({1'b0, dst_row} != a_dst_size_y - 5'd1) begin
						dst_row     <= dst_row + 4'd1;
						gfxrom_req <= 1'b1;
						state        <= S_ROW_WAIT;
					end else if (ix != a_nx - 4'd1) begin
						ix               <= ix + 4'd1;
						subtile_ordinal <= subtile_ordinal + 6'd1;
						lut_req          <= 1'b1;
						state             <= S_LUT_WAIT;
					end else if (iy != a_ny - 4'd1) begin
						ix               <= 4'd0;
						iy               <= iy + 4'd1;
						subtile_ordinal <= subtile_ordinal + 6'd1;
						lut_req          <= 1'b1;
						state             <= S_LUT_WAIT;
					end else begin
						// sprite's whole nx*ny grid done -- release the walker
						dl_advance <= 1'b1;
						state       <= S_WALK_WAIT;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
