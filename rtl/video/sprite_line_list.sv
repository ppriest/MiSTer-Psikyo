// Per-frame sprite list build pass, for the per-scanline sprite renderer.
//
// The parked 2026-08-29 line renderer paid the full display-list cost on
// EVERY line: walk the list, fetch each sprite's 4-word record from the
// snapshot, decode it, and reject it -- ~10 cycles per sprite per line.
// With a busy list (hundreds of live entries) that alone approached the
// 5,472-cycle line budget before a single pixel was drawn, and large
// sprites pushed it over; the deficit then compounded (see
// docs/sprite_buffering.md, "The alternative that was tried"). This module
// is the fix's first half: do the walking, fetching and coarse rejection
// ONCE per frame, in vblank, so the per-line cost collapses to one cycle
// per candidate plus real rendering work.
//
// At build_start (frame_start), it walks the snapshot's display list with
// the same verified walker + record-fetch modules the frame renderer used,
// and stores, in DISPLAY-LIST ORDER (which is depth order -- later entries
// overwrite earlier), one entry per potentially-visible sprite:
//
//   ytest RAM (18 bits): { y_top[9:0] signed, span_y[7:0] }
//   rec RAM   (64 bits): { word_y, word_x, word_attr, word_code_lo }
//
// The y extent is the sprite's whole bounding box, from the same math
// sprite_subtile_step uses: sub-tile iy sits at y_adj + (iy*zoom_y_t)>>1,
// each covering dst_size_y lines, so the box is
// [y_adj, y_adj + ((ny-1)*zoom_y_t)>>1 + dst_size_y). The per-line test
// against it is deliberately COARSE-only -- the engine's FIND_ROW re-does
// the exact per-sub-tile-row math on every hit, so a rare conservative
// false hit costs a few cycles, never a wrong pixel. Entries whose box
// misses the screen entirely (X or Y) are dropped here and never scanned.
//
// Ordering contract with spriteram_dbuf: build_done is the "get_sprites()
// finished with the buffer" moment -- psikyo_core triggers the snapshot
// refresh from it, preserving psikyo_v.cpp's get_sprites()-then-copy()
// generation ordering with the copy still landing at the frame boundary
// (vblank), MAME's capture instant.
//
// Budget: <= 1023 entries x ~9 cycles + terminator ~= 9.5K cycles, against
// vblank's 207,936. The engine never scans while build_busy (psikyo_core
// gates its start), so the table RAMs' read ports are quiet during the
// build and the count/table pairing is always coherent.

module sprite_line_list (
	input  logic clk,
	input  logic reset,

	input  logic         build_start,   // pulse: rebuild the table from the snapshot
	output logic         build_busy,
	output logic         build_done,     // pulse: table + count are coherent

	// snapshot display-list port (word offsets 0xC00-0xFFE)
	output logic [11:0] dl_addr,
	input  logic [15:0] dl_data,

	// snapshot attribute-table port (word offsets 0x000-0xBFF)
	output logic [11:0] at_addr,
	input  logic [15:0] at_data,

	// engine-facing table read ports (1-cycle sync reads)
	input  logic [9:0]  scan_addr,
	output logic [17:0] scan_ytest,    // { y_top[9:0] signed, span_y[7:0] }
	input  logic [9:0]  rec_addr,
	output logic [63:0] rec_data,       // { word_y, word_x, word_attr, word_code_lo }

	output logic [10:0] count            // entries stored by the last completed build
);

	// ---- display list walker + record fetch: same verified modules the
	// frame renderer used ----
	logic        dl_start, dl_busy, dl_advance;
	logic        dl_entry_valid, dl_done;
	logic [9:0] dl_sprite_index;

	sprite_display_list_walker u_walker (
		.clk(clk), .reset(reset),
		.start(dl_start), .busy(dl_busy), .advance(dl_advance),
		.sram_addr(dl_addr), .sram_data(dl_data),
		.entry_valid(dl_entry_valid), .sprite_index(dl_sprite_index), .done(dl_done)
	);

	logic        rf_start, rf_busy, rf_record_valid;
	logic [15:0] rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo;

	sprite_record_fetch u_record_fetch (
		.clk(clk), .reset(reset),
		.start(rf_start), .sprite_index(dl_sprite_index), .busy(rf_busy),
		.sram_addr(at_addr), .sram_data(at_data),
		.record_valid(rf_record_valid),
		.word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo)
	);

	// ---- combinational decode, only as far as the bounding box needs ----
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

	// Bounding box. (ny-1)*zoom_y_t is at most 7*32=224; >>1 is 112; plus
	// dst_size_y (<=16) gives span <= 128, comfortably 8 bits. Same for X
	// against its 9-bit span.
	logic [7:0] span_y_c;
	logic [8:0] span_x_c;
	assign span_y_c = 8'((({4'd0, rd_ny - 4'd1} * {2'd0, pt_zoom_y_t}) >> 1) + {3'd0, zl_dst_size_y});
	assign span_x_c = 9'((({4'd0, rd_nx - 4'd1} * {2'd0, pt_zoom_x_t}) >> 1) + {4'd0, zl_dst_size_x});

	logic signed [10:0] y_bot_c, x_rgt_c;
	assign y_bot_c = $signed({pt_y_adj[9], pt_y_adj}) + $signed({3'd0, span_y_c});
	assign x_rgt_c = $signed({pt_x_adj[9], pt_x_adj}) + $signed({2'd0, span_x_c});

	wire box_visible = (y_bot_c > 0) && ($signed({pt_y_adj[9], pt_y_adj}) < 11'sd224)
	                 && (x_rgt_c > 0) && ($signed({pt_x_adj[9], pt_x_adj}) < 11'sd320);

	// ---- table RAMs ----
	logic [17:0] ytest_ram [0:1023];
	logic [63:0] rec_ram   [0:1023];

	logic         wr_en;
	logic [9:0]  wr_idx;
	logic [17:0] wr_ytest;
	logic [63:0] wr_rec;

	always_ff @(posedge clk) begin
		if (wr_en) ytest_ram[wr_idx] <= wr_ytest;
		scan_ytest <= ytest_ram[scan_addr];
	end

	always_ff @(posedge clk) begin
		if (wr_en) rec_ram[wr_idx] <= wr_rec;
		rec_data <= rec_ram[rec_addr];
	end

	// ---- build FSM ----
	// One registered stage between record_valid and the table write keeps
	// the whole decode chain out of the RAM-write timing path.
	typedef enum logic [1:0] {S_IDLE, S_WALK, S_FETCH, S_STORE} state_t;
	state_t state;

	assign build_busy = (state != S_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state       <= S_IDLE;
			dl_start    <= 1'b0;
			dl_advance <= 1'b0;
			rf_start    <= 1'b0;
			build_done <= 1'b0;
			wr_en        <= 1'b0;
			wr_idx      <= 10'd0;
			wr_ytest    <= 18'd0;
			wr_rec       <= 64'd0;
			count        <= 11'd0;
		end else begin
			dl_start    <= 1'b0;
			dl_advance <= 1'b0;
			rf_start    <= 1'b0;
			build_done <= 1'b0;
			wr_en        <= 1'b0;

			case (state)
				S_IDLE: begin
					if (build_start) begin
						dl_start <= 1'b1;
						wr_idx    <= 10'd0;
						state     <= S_WALK;
					end
				end

				S_WALK: begin
					if (dl_entry_valid) begin
						rf_start <= 1'b1;
						state     <= S_FETCH;
					end else if (dl_done) begin
						count       <= {1'b0, wr_idx};
						build_done <= 1'b1;
						state        <= S_IDLE;
					end
				end

				S_FETCH: begin
					if (rf_record_valid) begin
						// decode chain settles from the just-latched rf_word_*
						// registers during this cycle; capture its verdict
						wr_ytest <= {pt_y_adj, span_y_c};
						wr_rec    <= {rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo};
						wr_en     <= box_visible;
						state      <= S_STORE;
					end
				end

				S_STORE: begin
					// wr_en wrote (or skipped) this entry on the edge entering
					// this state; advance the walker either way
					if (wr_en) wr_idx <= wr_idx + 10'd1;
					dl_advance <= 1'b1;
					state       <= S_WALK;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
