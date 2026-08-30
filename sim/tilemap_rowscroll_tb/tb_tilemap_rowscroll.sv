`timescale 1ns/1ps
// Row-scroll (linescroll) indexing test for tilemap_line_engine.
//
// tb_tilemap_line_engine covers the fetch/align/display sequencer but runs
// with rowscroll_enable=0 throughout, so the row-scroll table read was never
// exercised by any testbench. Two divergences from MAME's psikyo_v.cpp live
// on that path; both are checked here.
//
// 1. WHICH ENTRY a line uses. MAME indexes the table by SCREEN line:
//        for (i = 0; i < 256; i++)
//            x0 = vregs[base + (i >> tile_rowscroll)];
//            set_scrollx((i + scrolly) & 0x7ff, scrollx + x0);
//    so the line whose tilemap row is (i + scrolly) is scrolled by entry i.
//    The engine latches rowscroll_addr and reads a 1-cycle synchronous RAM
//    (the port's own contract, and rtl/memory/dpram.sv's port B), so the
//    entry is only valid TWO cycles after the address is registered.
//
// 2. WHEN row-scroll is active. MAME enables it on either control bit:
//    `if (layer_ctrl[layer] & 0x0300)`, with bit 9 additionally selecting
//    per-tile granularity. Bit 9 set with bit 8 clear is therefore a valid
//    per-tile row-scroll mode, not "disabled".
//
// The observable is the engine's latched fetch_eff_x: with base_x_scroll=0
// and table entry v, line_x_scroll = v + 1 (the hardware-verified one-pixel
// bias), so fetch_eff_x == (v + 1) & ~15. Entries are multiples of 16 here,
// making fetch_eff_x read back the entry that was actually used.
module tb_tilemap_rowscroll;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	logic [7:0] vcnt;
	logic       ce_pix, h_active, line_start;
	logic [1:0] mode, bank;
	logic [15:0] base_x_scroll, base_y_scroll;
	logic        rowscroll_enable, rowscroll_pertile;
	logic [7:0]  rowscroll_addr;
	logic [15:0] rowscroll_data;
	logic [11:0] vram_addr;
	logic [15:0] vram_data;
	logic        gfxrom_req;
	logic [21:0] gfxrom_addr;
	logic        gfxrom_valid;
	logic [63:0] gfxrom_data;
	logic        pixel_valid, fetch_overrun;
	logic [3:0]  pixel_index;
	logic [6:0]  pixel_color;

	assign ce_pix = 1'b1;

	// Row-scroll table: entry i = i*16, so the entry in use is readable
	// directly off fetch_eff_x. Modelled with the SAME 1-cycle registered
	// read as rtl/memory/dpram.sv port B, which is the whole point.
	logic [15:0] rowscroll_mem [0:255];
	always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

	// VRAM/gfx ROM are not under test here; keep them quiet and valid.
	logic [15:0] vram_mem [0:4095];
	always_ff @(posedge clk) vram_data <= vram_mem[vram_addr];
	always_ff @(posedge clk) gfxrom_valid <= gfxrom_req;
	assign gfxrom_data = 64'h0123_4567_89AB_CDEF;

	tilemap_line_engine dut (
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll),
		.bank(bank),
		.rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile),
		.rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr),
		.gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
		.pixel_valid(pixel_valid), .pixel_index(pixel_index),
		.pixel_color(pixel_color), .fetch_overrun(fetch_overrun)
	);

	int errors = 0;

	// Start a line the way video_timing does and return once the engine has
	// latched its per-line scroll, then report the entry it actually used.
	task automatic run_line(input [7:0] line, output [15:0] used_entry);
		vcnt = line;
		@(posedge clk);
		line_start = 1'b1;
		@(posedge clk);
		line_start = 1'b0;
		// Address registers on this edge, RAM data lands one edge later;
		// allow both plus the state that consumes it.
		repeat (4) @(posedge clk);
		used_entry = dut.fetch_eff_x;
	endtask

	task automatic check(input [15:0] got, input [15:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: engine used entry %0d, expected %0d", name, got, exp);
		end
	endtask

	initial begin
		logic [15:0] used;

		for (int i = 0; i < 256; i++) rowscroll_mem[i] = 16'(i * 16);
		for (int i = 0; i < 4096; i++) vram_mem[i] = 16'h0000;

		reset = 1;
		mode = 2'd0; bank = 2'd0;
		base_x_scroll = 16'd0; base_y_scroll = 16'd0;
		rowscroll_enable = 1'b1; rowscroll_pertile = 1'b0;
		vcnt = 8'd0; h_active = 1'b0; line_start = 1'b0;
		repeat (4) @(posedge clk);
		reset = 0;
		repeat (4) @(posedge clk);

		// ---- per-line row-scroll: line N must use entry N ----
		// Consecutive lines, as a real frame drives them: a stale-read bug
		// shows up as each line carrying its predecessor's entry.
		foreach_line: begin
			for (int n = 1; n <= 6; n++) begin
				run_line(8'(n), used);
				check(used, 16'(n * 16), $sformatf("per-line entry (vcnt=%0d)", n));
			end
		end

		// A non-adjacent jump: distinguishes "off by one" from "always the
		// previously addressed entry, whatever it was".
		run_line(8'd100, used);
		check(used, 16'd1600, "per-line entry (vcnt=100 after jump)");

		// ---- per-tile row-scroll: line N uses entry N>>4 ----
		rowscroll_pertile = 1'b1;
		run_line(8'd35, used);   // 35>>4 = 2
		check(used, 16'(2 * 16), "per-tile entry (vcnt=35 -> index 2)");
		run_line(8'd80, used);   // 80>>4 = 5
		check(used, 16'(5 * 16), "per-tile entry (vcnt=80 -> index 5)");
		rowscroll_pertile = 1'b0;

		// ---- disabled: no row-scroll contribution at all ----
		rowscroll_enable = 1'b0;
		run_line(8'd7, used);
		check(used, 16'd0, "row-scroll disabled (vcnt=7)");
		rowscroll_enable = 1'b1;

		if (errors == 0) $display("ALL TESTS PASSED");
		else             $display("%0d TEST(S) FAILED", errors);
		$finish;
	end

	initial begin
		#200_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end

endmodule
