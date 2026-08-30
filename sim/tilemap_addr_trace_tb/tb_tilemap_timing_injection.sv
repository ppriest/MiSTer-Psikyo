// Tests whether an address-path timing violation (fetch_vram_addr arriving
// late at VRAM1's read port) CAN plausibly produce the specific symptom
// reported on real hardware: tile_number correct (from word 0x080) but
// color wrong (matching the ADJACENT word 0x081's color bits), rather than
// the two shifting together or producing generic corruption.
//
// The structural argument against timing being able to do this: cell_
// tile_number and cell_color (tile_cell_decode.sv) are both PLAIN BIT-
// SELECTS of the exact same registered vram_data word (vram_cell[12:0] and
// vram_cell[15:13]) -- no additional logic, no extra register stage,
// between them. A late/violating address at the memory's own read port
// can only change WHICH WORD gets captured, and that word feeds BOTH
// fields identically -- there is no path by which only the top 3 bits
// could reflect a different word than the bottom 13 bits reflect, since
// both are slices of ONE register with IDENTICAL arrival time. This
// testbench demonstrates that empirically rather than asserting it:
// inject a growing delay on the address reaching VRAM1's port, and log
// whether tile_number and color ever DISAGREE about which word they came
// from, across a range of delays from none up to nearly a full clock
// period (i.e. up to and beyond outright address corruption).
//
// Reuses tb_tilemap_real_data.sv's exact real VRAM content, real config,
// and real target cell (word 0x080 = 0x2010) -- same DUT, same data, only
// difference is the injected delay on the path into the memory's read
// port.

module tb_tilemap_timing_injection;

	logic clk = 0;
	always #5 clk = ~clk;   // 10ns period, matching every other TB here

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

	logic [11:0] dbg_fetch_vram_addr;
	logic [15:0] dbg_vram_data;
	logic [14:0] dbg_cell_tile_number;
	logic [6:0]  dbg_cell_color;
	logic [1:0]  dbg_mode_latched;
	logic [1:0]  dbg_bank_latched;
	logic [11:0] dbg_pixel_src_addr;
	logic [15:0] dbg_pixel_src_word;

	assign ce_pix = 1'b1;

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

	// ---- INJECTED DELAY: the address the DUT computes (vram_addr) is
	// correct and immediate; what VRAM1 actually SEES at its read port is
	// a delayed copy, modeling a routing/logic delay that eats into setup
	// margin. DELAY_NS is swept across scenarios below, from 0 (no
	// violation) up past a full 10ns clock period (guaranteed corruption,
	// an upper-bound sanity check that the injection mechanism itself
	// works). ----
	real delay_ns;
	logic [11:0] vram1_b_addr_delayed;
	always @(vram_addr) vram1_b_addr_delayed <= #(delay_ns) vram_addr;

	logic [11:0] vram1_a_addr;
	logic [15:0] vram1_a_wdata, vram1_a_rdata;

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
		.clk(clk),
		.a_addr(vram1_a_addr), .a_wel(1'b0), .a_weh(1'b0),
		.a_wdata(vram1_a_wdata), .a_rdata(vram1_a_rdata),
		.b_addr(vram1_b_addr_delayed), .b_rdata(vram_data)
	);
	assign vram1_a_addr  = 12'd0;
	assign vram1_a_wdata = 16'd0;

	logic [15:0] rowscroll_mem [0:255];
	always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

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

	initial begin
		$readmemh("real_vram1_dump.hex", u_vram1.mem);
		for (int i = 0; i < 256; i++)
			rowscroll_mem[i] = 16'h0000;
	end

	task automatic run_one(real d);
		delay_ns = d;
		reset = 1;
		mode = 2'd3;
		base_x_scroll = 16'h0140;
		base_y_scroll = 16'h0000;
		bank = 2'd1;
		rowscroll_enable = 1'b0;
		rowscroll_pertile = 1'b0;
		vcnt = 8'd64;
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

	int selective_mismatch_count;   // tile correct, color alone wrong
	int uniform_shift_count;        // both tile AND color reflect a different word together
	int total_at_080;
	bit tile_correct, color_correct;

	always_ff @(posedge clk) begin
		if (!reset && dut.state == dut.S_CELLDEC && dbg_fetch_vram_addr == 12'h080) begin
			total_at_080 <= total_at_080 + 1;
			tile_correct  = (dbg_cell_tile_number == 15'd8208);
			color_correct = (dbg_cell_color == 7'd65);
			$display("[delay=%0.2fns] raw_word=0x%04X tile_number=%0d color=%0d  tile_%s color_%s",
					  delay_ns, dbg_vram_data, dbg_cell_tile_number, dbg_cell_color,
					  tile_correct ? "OK" : "WRONG", color_correct ? "OK" : "WRONG");
			if (tile_correct && !color_correct) begin
				selective_mismatch_count <= selective_mismatch_count + 1;
				$display("  *** SELECTIVE: tile correct, color alone wrong -- matches the reported hardware symptom ***");
			end else if (!tile_correct && !color_correct) begin
				uniform_shift_count <= uniform_shift_count + 1;
				$display("  -- uniform corruption: both fields wrong together (reading a different word entirely)");
			end
		end
	end

	initial begin
		// Sweep from no delay up past a full 10ns clock period. The real
		// hardware's own measured worst-case setup slack was -2.83ns on an
		// unrelated path (sprite engine) against an 11.64ns period; 2.5-3ns
		// is included here as the directly comparable magnitude, plus much
		// larger values as an upper-bound check that the injection
		// mechanism itself is capable of provoking SOME failure.
		real delays[] = '{0.0, 1.0, 2.0, 2.5, 2.83, 4.0, 6.0, 8.0, 9.5, 12.0,
						  15.0, 18.0, 20.0, 25.0, 30.0, 40.0, 50.0, 70.0, 100.0};
		foreach (delays[i]) run_one(delays[i]);

		$display("---- sweep done: %0d fetches of addr 0x080 across %0d delay values ----", total_at_080, delays.size());
		$display("selective mismatches (tile OK, color alone wrong -- matches hardware symptom): %0d", selective_mismatch_count);
		$display("uniform-shift corruptions (both fields wrong together): %0d", uniform_shift_count);
		if (selective_mismatch_count > 0)
			$display("RESULT: a pure address-timing violation CAN reproduce the selective symptom -- timing remains a live hypothesis");
		else if (uniform_shift_count > 0)
			$display("RESULT: address-timing violations only ever corrupt tile_number and color TOGETHER (uniform word shift), never selectively -- consistent with the structural argument (both fields are plain bit-selects of one shared register) and INCONSISTENT with the reported hardware symptom. Timing on THIS specific path does not explain the bug.");
		else
			$display("RESULT: no corruption observed at any tested delay -- this path may simply have more real margin than assumed, or the injection point doesn't stress the actual failing path");
		$finish;
	end

endmodule
