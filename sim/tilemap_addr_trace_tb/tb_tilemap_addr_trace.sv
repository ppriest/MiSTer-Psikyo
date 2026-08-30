// Targeted regression for the "tile from one VRAM word, palette from
// another" bug reported on real hardware (Gunbird title screen, 2026-08-29):
// poking word 0x081 (0x802102) both corrected the colour of the tile at
// word 0x080 (0x802100) AND made a second, previously-blank tile appear --
// consistent with this engine reading tile_number from one word but color
// from the adjacent one for what should be a single cell's fetch.
//
// Scope: fetch address generation -> VRAM word read -> tile_number/color
// decode, i.e. everything up to and including the palette INDEX
// (pixel_color) that tilemap_line_engine hands off -- not the downstream
// palette RAM lookup itself (pal_addr -> pal_data -> rgb in compositor.sv),
// which is untouched here.
//
// Unlike tb_tilemap_line_engine.sv (which uses an idealized behavioral
// array for VRAM and only end-to-end-checks the final pixel stream), this
// testbench:
//   1. Instantiates the REAL dpram.sv module for VRAM1, wired exactly as
//      psikyo_core.sv wires it (engine's vram_addr -> dpram b_addr,
//      dpram b_rdata -> engine's vram_data) -- not a simplified model.
//   2. Preloads VRAM with a SELF-DESCRIBING pattern: word i holds
//      tile_number=i (its own index, bank=0) and color=(i&7)+LAYER_BASE.
//      A cell's tile_number therefore reveals EXACTLY which word its tile
//      half came from (13 bits, unambiguous), and (color-LAYER_BASE)
//      reveals the LOW 3 BITS of whichever word its color half came from.
//      Adjacent words always differ in their low 3 bits (only words 8
//      apart share them), so this pattern is sufficient to confirm or
//      deny a +-1-word split, without needing external ground truth.
//   3. Sweeps every geometry mode (0-3), a nonzero bank, and a rowscroll-
//      enabled scenario -- the first version of this testbench only ever
//      drove mode=0/bank=0/rowscroll-disabled, so a bug specific to any
//      other mode's addrgen formula, to the bank addition, or to the
//      rowscroll adder would not have been exercised at all.
//   4. Logs, per cell fetched: the address the FSM itself requested
//      (dbg_fetch_vram_addr), the raw word it read (dbg_vram_data), and
//      the decoded tile_number/color -- then checks internal consistency
//      for every cell fetched in every scenario, accumulating one final
//      pass/fail across the whole sweep.

module tb_tilemap_addr_trace;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;
	logic [7:0] vcnt;
	logic       h_active, line_start, ce_pix;

	logic [1:0]  mode;
	logic [15:0] base_x_scroll, base_y_scroll;
	logic [1:0]  bank;
	logic        rowscroll_enable, rowscroll_pertile;

	logic [7:0]  rowscroll_addr;
	logic [15:0] rowscroll_data;

	logic [11:0] vram_addr;
	logic [15:0] vram_data;

	logic        gfxrom_req;
	logic [21:0] gfxrom_addr;
	logic        gfxrom_valid;
	logic [63:0] gfxrom_data;

	logic        pixel_valid;
	logic [3:0]  pixel_index;
	logic [6:0]  pixel_color;
	logic        fetch_overrun;

	// DEBUG_ISSP must be passed on the vlog command line (+define+DEBUG_ISSP)
	// for BOTH this file and tilemap_line_engine.sv -- a `define here would
	// only affect this compilation unit, not the separately-compiled DUT.
	logic [11:0] dbg_fetch_vram_addr;
	logic [15:0] dbg_vram_data;
	logic [14:0] dbg_cell_tile_number;
	logic [6:0]  dbg_cell_color;
	logic [1:0]  dbg_mode_latched;
	logic [1:0]  dbg_bank_latched;
	logic [11:0] dbg_pixel_src_addr;
	logic [15:0] dbg_pixel_src_word;

	assign ce_pix = 1'b1;   // matches every other TB in this project; the
							 // engine has no ce_pix awareness of its own

	tilemap_line_engine #(.LAYER(1)) dut (
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll), .bank(bank),
		.rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile),
		.rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr),
		.gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
		.pixel_valid(pixel_valid), .pixel_index(pixel_index), .pixel_color(pixel_color),
		.fetch_overrun(fetch_overrun),
		.dbg_fetch_vram_addr(dbg_fetch_vram_addr), .dbg_vram_data(dbg_vram_data),
		.dbg_cell_tile_number(dbg_cell_tile_number), .dbg_cell_color(dbg_cell_color),
		.dbg_mode_latched(dbg_mode_latched), .dbg_bank_latched(dbg_bank_latched),
		.dbg_pixel_src_addr(dbg_pixel_src_addr), .dbg_pixel_src_word(dbg_pixel_src_word)
	);

	// ---- REAL vram1, wired exactly as psikyo_core.sv wires it: engine's
	// fetch address drives port b, port b's registered output feeds back
	// as vram_data. Port a (CPU write side) is tied off -- nothing writes
	// during this test, matching the CPU being fully paused on real
	// hardware when the poke test was performed. ----
	logic [11:0] vram1_a_addr;
	logic [15:0] vram1_a_wdata, vram1_a_rdata;

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
		.clk(clk),
		.a_addr(vram1_a_addr), .a_wel(1'b0), .a_weh(1'b0),
		.a_wdata(vram1_a_wdata), .a_rdata(vram1_a_rdata),
		.b_addr(vram_addr), .b_rdata(vram_data)
	);
	assign vram1_a_addr  = 12'd0;
	assign vram1_a_wdata = 16'd0;

	// ---- behavioral row-scroll table: preloaded with a nonzero, varying
	// pattern so the rowscroll-enabled scenario actually exercises the
	// adder with real data, not just zero. ----
	logic [15:0] rowscroll_mem [0:255];
	always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

	// ---- behavioral gfx ROM: fixed 3-cycle latency, content irrelevant
	// to this test (only addressing/decode is under test, not pixel
	// bitmap correctness -- tile_row_decode_tb already covers that) ----
	int gfxrom_delay;
	always_ff @(posedge clk) begin
		if (reset) begin
			gfxrom_valid <= 1'b0;
			gfxrom_delay <= 0;
		end else begin
			gfxrom_valid <= 1'b0;
			if (gfxrom_req && gfxrom_delay == 0) begin
				gfxrom_delay <= 3;
			end else if (gfxrom_delay > 0) begin
				if (gfxrom_delay == 1) begin
					gfxrom_data  <= 64'h0;
					gfxrom_valid <= 1'b1;
				end
				gfxrom_delay <= gfxrom_delay - 1;
			end
		end
	end

	// ---- preload VRAM: word i -> tile_number=i, color=(i&7)+LAYER_BASE.
	// Hierarchical access to the real dpram's own storage array, sim-only
	// (matches how a synthesizable RAM model is normally preloaded in this
	// style of testbench -- no synthesizable initial-value assumption is
	// made about real hardware). Runs once at t=0; VRAM content itself
	// never needs to change between scenarios since bank/mode only change
	// which word gets FETCHED, not what's stored. ----
	localparam int unsigned LAYER_BASE = 64;   // LAYER=1 per tile_cell_decode.sv

	initial begin
		for (int i = 0; i < 4096; i++)
			u_vram1.mem[i] = {3'(i[2:0]), 13'(i)};
		for (int i = 0; i < 256; i++)
			rowscroll_mem[i] = 16'((i + 1) * 7);   // nonzero even at index 0 (vcnt=0 -> rowscroll_addr=0)
	end

	// ---- trace every S_CELLDEC commit (tile_number_reg/color_reg latch
	// cycle) by watching for the DUT sitting in that state, and log
	// alongside dbg_fetch_vram_addr/dbg_vram_data at that instant. Runs
	// continuously across every scenario; scenario_name is updated by the
	// driver task so each log line is attributable. ----
	int          entry_count;
	int          mismatch_count;
	logic [2:0]  color_implied_low3, tile_own_low3;
	string       scenario_name;

	always_ff @(posedge clk) begin
		if (reset) begin
			// entry_count/mismatch_count intentionally NOT cleared on
			// reset -- they accumulate across the whole scenario sweep so
			// the final report covers everything driven, not just the
			// last scenario.
		end else if (dut.state == dut.S_CELLDEC) begin
			color_implied_low3 = dbg_cell_color[2:0] - LAYER_BASE[2:0];
			tile_own_low3       = dbg_cell_tile_number[2:0];
			entry_count <= entry_count + 1;
			$display("[%s cell %0d] fetch_addr=0x%03X vram_word=0x%04X -> tile_number=%0d (word 0x%03X) color=%0d (implied low3=%0d, tile low3=%0d) %s",
					  scenario_name, entry_count, dbg_fetch_vram_addr, dbg_vram_data,
					  dbg_cell_tile_number, dbg_cell_tile_number,
					  dbg_cell_color, color_implied_low3, tile_own_low3,
					  (dbg_fetch_vram_addr !== dbg_cell_tile_number[11:0]) ? "<-- FETCH ADDR != TILE_NUMBER" :
					  (color_implied_low3 !== tile_own_low3) ? "<-- COLOR/TILE SOURCE-WORD MISMATCH" : "ok");
			if (dbg_fetch_vram_addr !== dbg_cell_tile_number[11:0])
				mismatch_count <= mismatch_count + 1;
			else if (color_implied_low3 !== tile_own_low3)
				mismatch_count <= mismatch_count + 1;
		end
	end

	// ---- DISPLAY-side check, a genuinely different code path from the
	// fetch-side tracer above: pixel_color/pixel_index come out of the
	// PREFETCH RING BUFFER via buf_color[display_sel]/buf_pixels[display_sel]
	// (a separate index, separate fetch_tog/disp_tog handshake, from the
	// fetch side's fetch_target). dbg_pixel_src_addr/dbg_pixel_src_word
	// (buf_src_addr/buf_src_word[display_sel]) were added earlier this
	// session specifically to make this checkable: for the pixel CURRENTLY
	// being displayed, does the buffered word's OWN tile bits match its
	// claimed source address, and does the CURRENTLY OUTPUT pixel_color
	// match that SAME buffered word's color bits? A ring-buffer indexing
	// bug (display_sel desyncing from which slot was actually last
	// written, e.g. on wraparound) would show up here even though the
	// fetch-side check above is clean, because fetch-side only proves
	// buf_color/buf_src_addr/buf_src_word were WRITTEN consistently, not
	// that display_sel correctly reads them back. ----
	int          disp_entry_count;
	int          disp_mismatch_count;

	always_ff @(posedge clk) begin
		if (!reset && pixel_valid) begin
			disp_entry_count <= disp_entry_count + 1;
			$display("[%s disp %0d] pixel_src_addr=0x%03X pixel_src_word=0x%04X pixel_color=%0d pixel_index=%0d %s",
					  scenario_name, disp_entry_count, dbg_pixel_src_addr, dbg_pixel_src_word,
					  pixel_color, pixel_index,
					  (dbg_pixel_src_word[12:0] !== {1'b0, dbg_pixel_src_addr}) ? "<-- BUFFERED WORD != ITS OWN CLAIMED SOURCE ADDR" :
					  ((pixel_color[2:0] - LAYER_BASE[2:0]) !== dbg_pixel_src_word[15:13]) ? "<-- DISPLAYED COLOR != BUFFERED WORD'S OWN COLOR BITS" : "ok");
			if (dbg_pixel_src_word[12:0] !== {1'b0, dbg_pixel_src_addr})
				disp_mismatch_count <= disp_mismatch_count + 1;
			else if ((pixel_color[2:0] - LAYER_BASE[2:0]) !== dbg_pixel_src_word[15:13])
				disp_mismatch_count <= disp_mismatch_count + 1;
		end
	end

	// ---- reusable scenario driver: configure mode/bank/scroll/rowscroll,
	// reset the DUT cleanly, run one full active line, and let the tracer
	// above log+check every cell fetched during it. ----
	task automatic run_scenario(
		string name, logic [1:0] m, logic [15:0] bx, logic [15:0] by,
		logic [1:0] bk, logic rs_en, logic rs_pertile
	);
		scenario_name = name;
		reset = 1;
		mode = m;
		base_x_scroll = bx;
		base_y_scroll = by;
		bank = bk;
		rowscroll_enable = rs_en;
		rowscroll_pertile = rs_pertile;
		vcnt = 8'd0;
		h_active = 1'b0;
		line_start = 1'b0;

		repeat (4) @(posedge clk);
		reset = 0;
		repeat (4) @(posedge clk);

		line_start = 1'b1;
		@(posedge clk);
		line_start = 1'b0;

		repeat (100) @(posedge clk);

		h_active = 1'b1;
		repeat (320) @(posedge clk);
		h_active = 1'b0;

		repeat (10) @(posedge clk);
	endtask

	// ---- scenario sweep. Target addresses per mode chosen so tile_col=0
	// (or, for mode 2, tile_col=128) lands the FIRST fetched cell exactly
	// on vram_index=128 (0x080) -- the same word from the real-hardware
	// report -- in every mode, via tilemap_coord's uniform tile_row =
	// masked_y[10:4] bit-slice (only the wrap MASK differs per mode, so a
	// given base_y_scroll maps to the same tile_row in every mode):
	//   mode 0 (row*64+col):  row=2 (base_y=32), col=0  -> 2*64+0=128
	//   mode 1 (row*128+col): row=1 (base_y=16), col=0  -> 1*128+0=128
	//   mode 2 (row*256+col): row=0 (base_y=0),  col=128 (base_x=2048) -> 128
	//   mode 3 (row*32+col):  row=4 (base_y=64), col=0  -> 4*32+0=128
	initial begin
		run_scenario("mode0/bank0",       2'd0, 16'd0,    16'd32, 2'd0, 1'b0, 1'b0);
		run_scenario("mode1/bank0",       2'd1, 16'd0,    16'd16, 2'd0, 1'b0, 1'b0);
		run_scenario("mode2/bank0",       2'd2, 16'd2048, 16'd0,  2'd0, 1'b0, 1'b0);
		run_scenario("mode3/bank0",       2'd3, 16'd0,    16'd64, 2'd0, 1'b0, 1'b0);
		// same address, nonzero banks -- bank only adds to tile_number
		// post-fetch (tile_cell_decode.sv), so it must NOT change which
		// word gets fetched or how color derives from it.
		run_scenario("mode0/bank1",       2'd0, 16'd0,    16'd32, 2'd1, 1'b0, 1'b0);
		run_scenario("mode0/bank3",       2'd0, 16'd0,    16'd32, 2'd3, 1'b0, 1'b0);
		// rowscroll enabled (line-based, not per-tile) -- exercises the
		// base_x_scroll + rowscroll_data adder feeding fetch_eff_x, a
		// control path every prior scenario left disabled entirely.
		run_scenario("mode0/rowscroll",   2'd0, 16'd0,    16'd32, 2'd0, 1'b1, 1'b0);
		// rowscroll enabled, per-tile addressing mode (rowscroll_addr
		// derives from vcnt[7:4] instead of vcnt directly).
		run_scenario("mode0/rs_pertile",  2'd0, 16'd0,    16'd32, 2'd0, 1'b1, 1'b1);
		// Real Gunbird title-screen layer-1 config, decoded from the live
		// control word 0x04D0 read off real hardware: bits[7:6]=11 -> mode
		// 3, bit10=1 -> bank 1 (KA302C live banking), rowscroll off. Not
		// covered by any scenario above -- mode 3 was only tried with
		// bank 0, and bank 1 was only tried with mode 0.
		run_scenario("mode3/bank1 (REAL gunbird title cfg)", 2'd3, 16'd0, 16'd64, 2'd1, 1'b0, 1'b0);

		$display("---- sweep done ----");
		$finish;
	end

	final begin
		if (mismatch_count > 0)
			$display("FAIL (fetch side): %0d/%0d fetched cells (across the whole sweep) show a tile/color source-word mismatch or a fetch-address/tile_number disagreement", mismatch_count, entry_count);
		else if (entry_count == 0)
			$display("FAIL (fetch side): no S_CELLDEC cycles observed at all -- testbench didn't drive the DUT far enough");
		else
			$display("PASS (fetch side): all %0d fetched cells self-consistent across every scenario (4 modes, 3 banks, rowscroll on/off, per-tile on/off) -- tile_number and color always trace back to the SAME VRAM word", entry_count);

		if (disp_mismatch_count > 0)
			$display("FAIL (display side): %0d/%0d displayed pixels show the ring buffer returning a color that doesn't match its own buffered word, or a buffered word that doesn't match its own claimed source address", disp_mismatch_count, disp_entry_count);
		else if (disp_entry_count == 0)
			$display("FAIL (display side): no pixel_valid pulses observed at all -- testbench didn't drive the DUT far enough");
		else
			$display("PASS (display side): all %0d displayed pixels self-consistent -- the prefetch ring buffer never desyncs color from the tile it belongs to", disp_entry_count);
	end

endmodule
