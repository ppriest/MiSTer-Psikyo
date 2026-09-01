// Per-scanline sprite renderer, second attempt (first parked 2026-08-29,
// recovered from git history and reworked -- see docs/sprite_buffering.md).
//
// Renders only the sprites intersecting one scanline into a 320-pixel line
// buffer, instead of rendering every sprite's full height into a whole-frame
// buffer. This is the shape real arcade hardware used and the shape the rest
// of the MiSTer ecosystem uses (JTFRAME's JTFRAME_LF_BUFFER, including
// JTFRAME_LF_ZOOM for zoomed sprites).
//
// The two defects that sank the first attempt, and what replaced them:
//
// 1. It re-walked the display list and re-fetched every sprite's 4-word
//    record from the snapshot on EVERY line (~10 cycles per sprite per
//    line). Busy lists burned most of the 5,472-cycle line budget before
//    drawing anything, and large sprites (~500+ cycles each per line)
//    pushed it over. Now sprite_line_list builds a compact table once per
//    frame in vblank, and the per-line cost is ONE cycle per candidate
//    (a pipelined read of an 18-bit y-test word) plus real rendering.
//
// 2. line_start was only consumed in S_IDLE, so an engine still busy at the
//    line boundary ATE the pulse: it finished the old line's sprites into
//    the freshly swapped bank, then idled a full line. One overrun corrupted
//    every line below it -- the "correct at the top, degrading downward"
//    hardware result. Now line_tick (the raw per-line pulse) hard-resyncs
//    the engine: rendering aborts immediately (writes stop the same cycle),
//    any in-flight SDRAM request is drained per the req/valid contract
//    during the line buffer's 320-cycle clear, and the next line starts
//    clean. An overrun now clips at worst the TAIL (topmost) sprites of one
//    line and pulses ovr_ev so the debug overlay can count it.
//
// Every decode/render stage is the same already-verified module the frame
// engine used -- sprite_record_decode, sprite_pos_transform,
// sprite_zoom_lut, sprite_subtile_step, sprite_zoom_src_index,
// tile_row_decode. The coarse y-test can produce a conservative false hit;
// S_FIND_ROW re-does the exact per-sub-tile-row math and rejects it, so
// coarseness costs cycles, never pixels.

module sprite_line_engine (
	input  logic clk,
	input  logic reset,

	input  logic         line_tick,     // raw per-line pulse (every line): hard resync point
	input  logic         line_start,    // gated pulse: begin rendering `render_line`
	input  logic [7:0]  render_line,   // 0-223, sampled at line_start
	output logic         busy,
	output logic         ovr_ev,         // pulse: a line was cut short by the resync

	input  logic trans_pen0,
	input  logic trans_pen15,

	// compact table ports (sprite_line_list, 1-cycle sync reads)
	output logic [9:0]  scan_addr,
	input  logic [17:0] scan_ytest,    // { y_top[9:0] signed, span_y[7:0] }
	output logic [9:0]  rec_addr,
	input  logic [63:0] rec_data,       // { word_y, word_x, word_attr, word_code_lo }
	input  logic [10:0] count,

	// spritelut ROM
	output logic         lut_req,
	output logic [16:0] lut_addr,
	input  logic         lut_valid,
	input  logic [15:0] lut_data,

	// sprite gfx ROM
	output logic         gfxrom_req,
	output logic [22:0] gfxrom_addr,
	input  logic         gfxrom_valid,
	input  logic [63:0] gfxrom_data,

	// line buffer write port
	output logic         fb_we,
	output logic [8:0]  fb_x,
	output logic [3:0]  fb_pixel,
	output logic [4:0]  fb_color,
	output logic [1:0]  fb_priority
);

	logic [7:0] line_r;   // the line being rendered

	// ---- record register + combinational decode chain ----
	// rec_q re-registers the record RAM's output before the decode chain.
	// The frame engine ran the same chain from rf_word_* FABRIC registers,
	// which the fitter places next to the decode logic; an M10K's Q has a
	// fixed location and pays its routing BEFORE the same logic depth --
	// running the chain straight off rec_data was a ~400-path failing group.
	// The hop costs no time: S_REC_WAIT already exists for the RAM read, so
	// rec_q loads there and S_CAPTURE decodes from it, same two cycles.
	logic [63:0] rec_q;
	always_ff @(posedge clk) rec_q <= rec_data;

	logic [15:0] rw_y, rw_x, rw_attr, rw_code_lo;
	assign {rw_y, rw_x, rw_attr, rw_code_lo} = rec_q;

	logic [3:0]        rd_zoom_y_raw, rd_zoom_x_raw, rd_ny, rd_nx;
	logic signed [9:0] rd_y_pos, rd_x_pos;
	logic               rd_flip_y, rd_flip_x;
	logic [4:0]        rd_color;
	logic [1:0]        rd_priority_field;
	logic [16:0]       rd_code;

	sprite_record_decode u_record_decode (
		.word_y(rw_y), .word_x(rw_x), .word_attr(rw_attr), .word_code_lo(rw_code_lo),
		.zoom_y_raw(rd_zoom_y_raw), .zoom_x_raw(rd_zoom_x_raw), .ny(rd_ny), .nx(rd_nx),
		.y_pos(rd_y_pos), .x_pos(rd_x_pos), .flip_y(rd_flip_y), .flip_x(rd_flip_x),
		.color(rd_color), .priority_field(rd_priority_field), .code(rd_code)
	);

	logic signed [9:0] pt_x_adj, pt_y_adj;
	logic [5:0]        pt_zoom_x_t, pt_zoom_y_t;

	sprite_pos_transform u_pos_transform (
		.x_pos(rd_x_pos), .y_pos(rd_y_pos), .nx(rd_nx), .ny(rd_ny),
		.zoom_x_raw(rd_zoom_x_raw), .zoom_y_raw(rd_zoom_y_raw),
		.x_adj(pt_x_adj), .y_adj(pt_y_adj),
		.zoom_x_transformed(pt_zoom_x_t), .zoom_y_transformed(pt_zoom_y_t)
	);

	logic [4:0]  zl_dst_size_x, zl_dst_size_y;
	logic [16:0] zl_dx_x, zl_dx_y;

	sprite_zoom_lut u_zoom_lut_x (.raw_zoom(rd_zoom_x_raw), .dst_size(zl_dst_size_x), .dx(zl_dx_x));
	sprite_zoom_lut u_zoom_lut_y (.raw_zoom(rd_zoom_y_raw), .dst_size(zl_dst_size_y), .dx(zl_dx_y));

	// ---- per-sprite constants, registered once per hit ----
	logic [3:0]        a_nx, a_ny;
	logic              a_flip_x, a_flip_y;
	logic [4:0]        a_color;
	logic [1:0]        a_priority;
	logic [16:0]       a_code;
	logic signed [9:0] a_x_adj, a_y_adj;
	logic [5:0]        a_zoom_x_t, a_zoom_y_t;
	logic [4:0]        a_dst_size_x, a_dst_size_y;
	logic [16:0]       a_dx_x, a_dx_y;

	// ---- sub-tile stepping (identical to the parked engine) ----
	logic [3:0] ix, iy;
	logic [5:0] subtile_ordinal;
	logic [3:0] dst_row, dst_col;

	logic signed [9:0] st_sub_x, st_sub_y;
	logic [16:0]       st_sub_code;

	// Visitation is row-major, so the ordinal for an arbitrary (ix,iy) is
	// iy*nx + ix -- the frame engine could just count because it visited
	// every sub-tile; here we jump straight to the row containing the line.
	//
	// ord_prod is 8 bits and BOTH operands are widened to 8 before the
	// multiply, deliberately. This was written as
	//     6'({iy * a_nx}) + 6'({2'd0, ix})
	// which is wrong: the operands of a concatenation are self-determined,
	// so `iy * a_nx` was evaluated at max(4,4) = 4 BITS and wrapped mod 16
	// before the 6' cast ever saw it. The outer cast looks like it sets the
	// width and does not. Large sprites therefore re-used tile codes from
	// their own top rows -- nx=8 gave ordinals 0,8,0,8,... (a two-row
	// repeat), nx=6 gave 0,6,12,2,8,14,4,10 (everything inside the top ~2.7
	// rows) -- while any sprite with iy*nx < 16 was unaffected, which is why
	// small sprites looked perfect. Seen on hardware as large sprites drawing
	// similar-but-wrong tiles. Max value is 7*8+7 = 63, so 8 bits is ample
	// and the [5:0] slice cannot lose anything.
	// subtile_ordinal is a REGISTER, not a combinational product. Computing
	// it as iy*a_nx + ix in the same cycle it is used put the multiply
	// directly into lut_addr's path, which runs off-module to the spritelut
	// SDRAM bridge -- 582 failing paths (a_nx -> u_lut_bridge|tag_inflight)
	// in the first build after the width fix. The frame engine never had
	// this problem because it only ever incremented a counter; the line
	// engine additionally has to JUMP to the start of the hit row, so the
	// multiply is kept but retimed: ord_prod is evaluated off the registered
	// iy/a_nx and loaded into the ordinal at the S_FIND_ROW hit (a plain
	// register-to-register path for a 4x4 multiply), and the S_COL walk then
	// just increments, exactly like the frame engine.
	logic [7:0] ord_prod;
	assign ord_prod = {4'd0, iy} * {4'd0, a_nx};

	sprite_subtile_step u_subtile_step (
		.ix(ix), .iy(iy), .nx(a_nx), .ny(a_ny), .flip_x(a_flip_x), .flip_y(a_flip_y),
		.x_adj(a_x_adj), .y_adj(a_y_adj),
		.zoom_x_transformed(a_zoom_x_t), .zoom_y_transformed(a_zoom_y_t),
		.subtile_ordinal(subtile_ordinal), .code_base(a_code),
		.sub_x(st_sub_x), .sub_y(st_sub_y), .sub_code(st_sub_code)
	);

	// STAGE-B REGISTER, ported from the frame engine: st_sub_x feeds the
	// S_COL onscreen check through the sub-tile multiply, and consuming it
	// raw put that whole cone in series with the fb_* write enables -- the
	// entire failing-path population of the first line-path build. ix (and
	// the a_* it multiplies with) settle at least four cycles before S_COL
	// re-reads them (S_LUT_WAIT + S_ROW_WAIT always intervene), so a
	// free-running register is settled well before use. st_sub_y stays RAW:
	// S_FIND_ROW consumes it in the same cycle iy changes.
	logic signed [9:0] st_sub_x_r;
	always_ff @(posedge clk) st_sub_x_r <= st_sub_x;

	assign lut_addr = st_sub_code & 17'h1FFFF;

	// Does this sub-tile row cover the line being rendered?
	//
	// The search must not contain the sub-tile multiply: iy changes every
	// cycle of S_FIND_ROW, and iy -> (dy_grid*zoom)>>1 -> compare -> next-iy
	// is a single-cycle feedback loop that was the worst path of the second
	// line-path build. sub_y steps by exactly +/-zoom_y_t per row (the >>1
	// happens after accumulation, so this is bit-exact against the
	// multiply), so acc_y tracks dy_grid*zoom_y_t with one add per step;
	// the one real multiply runs once per sprite in S_FIND_INIT, off
	// registered operands. dy_grid*zoom <= 7*32 = 224, so 8 bits.
	logic [7:0] acc_y;
	logic signed [9:0] sub_y_search;
	assign sub_y_search = a_y_adj + $signed({3'd0, acc_y[7:1]});
	logic signed [10:0] row_off;
	assign row_off = $signed({line_r[7], 3'd0, line_r}) - $signed({sub_y_search[9], sub_y_search});
	wire row_hit = (row_off >= 0) && (row_off < $signed({6'd0, a_dst_size_y}));

	// ---- gfx row fetch / decode ----
	logic [15:0] tile_code_r;
	logic [3:0]  zsi_src_row, zsi_src_col;

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

	logic signed [10:0] screen_x_full;
	assign screen_x_full = $signed({st_sub_x_r[9], st_sub_x_r}) + $signed({7'd0, dst_col});
	wire onscreen = (screen_x_full >= 0) && (screen_x_full < 11'sd320);

	// ---- scan pipeline ----
	// scan_addr issues one index per cycle; scan_ytest answers for the index
	// issued the PREVIOUS cycle (registered BRAM read). idx_d/idx_d_valid
	// track which index the current scan_ytest word describes.
	logic [9:0]  idx;        // next index to issue
	logic [9:0]  idx_d;      // index scan_ytest currently describes
	logic         idx_d_valid;

	assign scan_addr = idx;
	assign rec_addr   = idx_d;

	logic signed [10:0] scan_off;
	assign scan_off = $signed({3'd0, line_r}) - $signed({scan_ytest[17], scan_ytest[17:8]});
	wire scan_hit = idx_d_valid && (scan_off >= 0)
	              && (scan_off < $signed({3'd0, scan_ytest[7:0]}));

	// ---- FSM ----
	typedef enum logic [3:0] {
		S_IDLE, S_SCAN, S_REC_WAIT, S_CAPTURE, S_FIND_INIT, S_FIND_ROW, S_LUT_WAIT, S_ROW_WAIT, S_COL
	} state_t;
	state_t state;

	assign busy = (state != S_IDLE);

	// Hard resync: line_tick while rendering aborts the line. `aborting`
	// suppresses writes the same cycle it sets; the FSM then drains any
	// in-flight req/valid (the response for a request already issued MUST be
	// consumed, or it would pair with the NEXT line's first request) and
	// parks in S_IDLE before the gated line_start arrives (~320 cycles later,
	// after the line buffer's clear).
	logic aborting;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state       <= S_IDLE;
			lut_req     <= 1'b0;
			gfxrom_req  <= 1'b0;
			fb_we        <= 1'b0;
			ovr_ev       <= 1'b0;
			aborting    <= 1'b0;
			line_r       <= 8'd0;
			idx           <= 10'd0;
			idx_d         <= 10'd0;
			idx_d_valid <= 1'b0;
			ix            <= 4'd0;
			iy            <= 4'd0;
			subtile_ordinal <= 6'd0;
			dst_row      <= 4'd0;
			dst_col      <= 4'd0;
			tile_code_r <= 16'd0;
			a_nx <= 4'd1; a_ny <= 4'd1; a_flip_x <= 1'b0; a_flip_y <= 1'b0;
			a_color <= 5'd0; a_priority <= 2'd0; a_code <= 17'd0;
			a_x_adj <= 10'sd0; a_y_adj <= 10'sd0;
			a_zoom_x_t <= 6'd32; a_zoom_y_t <= 6'd32;
			a_dst_size_x <= 5'd16; a_dst_size_y <= 5'd16;
			a_dx_x <= 17'd0; a_dx_y <= 17'd0;
			for (int i = 0; i < 8; i++) row_bytes_r[i] <= 8'd0;
		end else begin
			fb_we   <= 1'b0;
			ovr_ev <= 1'b0;

			if (line_tick && state != S_IDLE) begin
				// the line under construction is cut short
				ovr_ev    <= 1'b1;
				aborting <= 1'b1;
			end

			if (aborting || (line_tick && state != S_IDLE)) begin
				// drain: hold an outstanding request until its response
				// arrives, consume it, then park. States without a request
				// in flight park immediately.
				if (lut_req) begin
					if (lut_valid) begin
						lut_req  <= 1'b0;
						aborting <= 1'b0;
						state     <= S_IDLE;
					end
				end else if (gfxrom_req) begin
					if (gfxrom_valid) begin
						gfxrom_req <= 1'b0;
						aborting    <= 1'b0;
						state        <= S_IDLE;
					end
				end else begin
					aborting <= 1'b0;
					state     <= S_IDLE;
				end
			end else begin
				case (state)
					S_IDLE: begin
						if (line_start) begin
							line_r       <= render_line;
							idx           <= 10'd0;
							idx_d_valid <= 1'b0;
							state         <= S_SCAN;
						end
					end

					// One candidate per cycle: test the ytest word for idx_d
					// while issuing idx. On a hit the scan has already issued
					// idx, so idx is exactly the resume point.
					S_SCAN: begin
						if (scan_hit) begin
							// rec_addr = idx_d is already presented; the
							// record word arrives after S_REC_WAIT
							idx_d_valid <= 1'b0;
							state         <= S_REC_WAIT;
						end else if ({1'b0, idx} == count) begin
							// count==0 arrives here immediately (idx_d_valid
							// still clear suppresses any phantom hit)
							idx_d_valid <= 1'b0;
							state         <= S_IDLE;
						end else begin
							idx_d         <= idx;
							idx_d_valid <= 1'b1;
							idx           <= idx + 10'd1;
						end
					end

					S_REC_WAIT: begin
						// rec_data valid next cycle
						state <= S_CAPTURE;
					end

					S_CAPTURE: begin
						a_nx          <= rd_nx;
						a_ny          <= rd_ny;
						a_flip_x      <= rd_flip_x;
						a_flip_y      <= rd_flip_y;
						a_color       <= rd_color;
						a_priority    <= rd_priority_field;
						a_code        <= rd_code;
						a_x_adj       <= pt_x_adj;
						a_y_adj       <= pt_y_adj;
						a_zoom_x_t    <= pt_zoom_x_t;
						a_zoom_y_t    <= pt_zoom_y_t;
						a_dst_size_x <= zl_dst_size_x;
						a_dst_size_y <= zl_dst_size_y;
						a_dx_x        <= zl_dx_x;
						a_dx_y        <= zl_dx_y;
						ix             <= 4'd0;
						state          <= S_FIND_INIT;
					end

					// One cycle for the per-sprite multiply to settle into acc_y
				// (top-down search: dy_grid starts at ny-1 unflipped, 0
				// flipped -- see sprite_subtile_step's dy_grid mapping).
				S_FIND_INIT: begin
					iy     <= a_ny - 4'd1;
					acc_y <= a_flip_y ? 8'd0
					        : 8'(({4'd0, a_ny - 4'd1} * {2'd0, a_zoom_y_t}));
					state  <= S_FIND_ROW;
				end

				// Exact search for the sub-tile row covering line_r,
					// walked from the HIGHEST row down: with zoom, adjacent
					// sub-tile rows can overlap by a line (row step
					// zoom_y_t>>1 can be one less than dst_size_y), and the
					// frame engine draws both with the higher row's pixels
					// overwriting on the shared line -- so the higher row is
					// the one that must render here. (No line can be covered
					// by three rows: 2*step >= 16 >= dst_size_y.) The coarse
					// scan can also be conservatively wrong; a full miss here
					// just resumes the scan.
					S_FIND_ROW: begin
						if (row_hit) begin
							dst_row          <= row_off[3:0];
							ix                <= 4'd0;
							subtile_ordinal <= ord_prod[5:0];   // iy*nx + 0
							lut_req          <= 1'b1;
							state             <= S_LUT_WAIT;
						end else if (iy == 4'd0) begin
							state <= S_SCAN;   // false hit -- resume scan at idx
						end else begin
							iy     <= iy - 4'd1;
							// iy down => dy_grid down (unflipped) / up (flipped)
							acc_y <= a_flip_y ? acc_y + {2'd0, a_zoom_y_t}
							                   : acc_y - {2'd0, a_zoom_y_t};
						end
					end

					S_LUT_WAIT: begin
						if (lut_valid) begin
							tile_code_r <= lut_data;
							lut_req      <= 1'b0;
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
							fb_we        <= 1'b1;
							fb_x          <= screen_x_full[8:0];
							fb_pixel     <= cur_pixel;
							fb_color     <= a_color;
							fb_priority <= a_priority;
						end

						if ({1'b0, dst_col} != a_dst_size_x - 5'd1) begin
							dst_col <= dst_col + 4'd1;
						end else if (ix != a_nx - 4'd1) begin
							ix                <= ix + 4'd1;   // next sub-tile column, same row
							subtile_ordinal <= subtile_ordinal + 6'd1;
							lut_req          <= 1'b1;
							state             <= S_LUT_WAIT;
						end else begin
							state <= S_SCAN;          // sprite done -- resume scan
						end
					end

					default: state <= S_IDLE;
				endcase
			end
		end
	end

endmodule
