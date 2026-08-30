// Extends the tilemap+compositor integration one stage further: both
// tilemap layers' gfx ROM ports now go through the REAL DDRAM transport
// stack (ddram_arbiter -> ddram_phy -> ddram_model) instead of each
// having its own independent synthetic per-layer model
// (tb_video_pipeline_compositor.sv). This is new integration territory --
// the first time two real video consumers have been driven simultaneously
// through the arbiter under sustained, continuous multi-line operation
// (ddram_arbiter_tb's own tests used hand-driven req pulses, not a real
// tilemap_line_engine's actual access pattern).
//
// Address translation: tilemap_line_engine's gfxrom_addr is region-
// relative (tile_number*128+fine_y*8, per its own port comment) -- this
// testbench adds docs/phase1_ddram_map.md's real "tiles" region base
// (0xA40000) before handing addresses to the arbiter, exactly matching
// what the eventual real top-level will need to do. Both layers share the
// SAME physical tile ROM region (as real Psikyo hardware does -- one
// "tiles" ROM serves both tilemap layers), which this test exploits: with
// both layers' VRAM pointing at tile 0 (see tb_video_pipeline_compositor.sv
// for why only the color field differs, not tile_number), gfxrom_addr is
// identical for both layers, so seeding the shared DDRAM region once
// (via ddram_model's poke_byte backdoor -- a testbench-only backdoor, not
// exercising the download path, which is already verified separately in
// tb_ddram_download.sv) correctly serves both.
//
// Only c0/c1 are used (tilemap layer 0/1 gfxrom); c2/c3 (sprite gfxrom/
// spritelut) and the download path are tied off -- sprite integration is
// a separate, larger step (needs sprite_render_engine's own display-list/
// attribute-record setup, not just an address translation).
//
// Intended pass criteria: same composited-output correctness as
// tb_video_pipeline_compositor.sv (layer 1 wins when both draw), but now
// proving it holds when the gfx ROM data path is the real, arbitrated,
// variable-latency DDRAM transport -- not a per-layer synthetic model.
//
// ACTUAL RESULT: this test currently FAILS, and -- unlike the earlier
// tilemap sustained-operation investigation in tb_video_pipeline.sv,
// which turned out to be a false alarm -- this is a REAL, CONFIRMED
// instance of an already-documented, known limitation, not a new
// surprise: docs/phase1_ddram_map.md's "Known open item: throughput, not
// just correctness" flagged, before any of this integration RTL existed,
// that "real DDR3 round-trip latency... applied to a shared port with up
// to 6+ consumers is a genuine bandwidth/latency budget question this doc
// does not attempt to answer yet." This test is the first concrete
// evidence of exactly that: with only TWO consumers (not 6+) and a
// realistic 10-cycle model latency (docs/phase1_ddram_map.md's
// READ_LATENCY choice, closer to real DDR3 than the smaller values used
// in ddram_phy_tb/ddram_arbiter_tb's own unit tests), both tilemap layers
// requesting a new tile at the same moment (which they routinely do,
// being driven by the same line_start/h_active timing) forces
// ddram_arbiter to fully serialize them -- one consumer's ~13-cycle
// round trip, THEN the other's ~13-cycle round trip, ~26 cycles total
// against a 16-cycle-per-tile display budget PER LAYER. Confirmed via
// waveform-equivalent tracing (dut.state/arbiter state, in lieu of a real
// waveform viewer): layer 1's fetch sits correctly-but-unproductively
// blocked in S_GFXROM_WAIT for 20+ cycles while the arbiter finishes
// serving layer 0 first, and eventually falls behind its own display
// consumption -- exactly the predicted mechanism, not a wiring mistake.
//
// This is v1's real, honest ceiling -- ddram_phy's own header already
// says "correctness first, throughput later... no multi-beat bursting
// yet." Committed deliberately still failing, as concrete, reproducible
// evidence for whenever that throughput pass happens (wider bursts to
// amortize DDR3 latency across the shared port, or some prefetch-ahead
// scheduling scheme), not silently dropped or loosened to "pass."

module tb_video_pipeline_ddram;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset_vt, reset_l0, reset_l1, reset_ddram;

	localparam logic [27:0] TILES_BASE = 28'h0A40000;

	// ---- video_timing ----
	logic ce_pix;
	logic [8:0] hcnt, vcnt_raw;
	logic [7:0] vcnt_active;
	logic h_active, v_active, hblank, vblank, hsync, vsync;
	logic line_start, frame_start;

	assign ce_pix = 1'b1;

	video_timing vt (
		.clk(clk), .ce_pix(ce_pix), .reset(reset_vt),
		.hcnt(hcnt), .vcnt(vcnt_raw), .vcnt_active(vcnt_active),
		.h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start)
	);

	// ---- tilemap layer 0 ----
	logic [1:0]  l0_mode;
	logic [15:0] l0_base_x_scroll, l0_base_y_scroll;
	logic [1:0]  l0_bank;
	logic         l0_rowscroll_enable, l0_rowscroll_pertile;
	logic [7:0]  l0_rowscroll_addr;
	logic [15:0] l0_rowscroll_data;
	logic [11:0] l0_vram_addr;
	logic [15:0] l0_vram_data;
	logic         l0_gfxrom_req;
	logic [21:0] l0_gfxrom_addr;
	logic         l0_gfxrom_valid;
	logic [63:0] l0_gfxrom_data;
	logic         l0_pixel_valid;
	logic [3:0]  l0_pixel_index;
	logic [6:0]  l0_pixel_color;
	logic         l0_fetch_overrun;

	assign l0_mode = 2'd0;
	assign l0_base_x_scroll = 16'd0;
	assign l0_base_y_scroll = 16'd0;
	assign l0_bank = 2'd0;
	assign l0_rowscroll_enable = 1'b0;
	assign l0_rowscroll_pertile = 1'b0;

	tilemap_line_engine #(.LAYER(0)) tle0 (
		.clk(clk), .reset(reset_l0),
		.vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
		.mode(l0_mode), .base_x_scroll(l0_base_x_scroll), .base_y_scroll(l0_base_y_scroll), .bank(l0_bank),
		.rowscroll_enable(l0_rowscroll_enable), .rowscroll_pertile(l0_rowscroll_pertile),
		.rowscroll_addr(l0_rowscroll_addr), .rowscroll_data(l0_rowscroll_data),
		.vram_addr(l0_vram_addr), .vram_data(l0_vram_data),
		.gfxrom_req(l0_gfxrom_req), .gfxrom_addr(l0_gfxrom_addr), .gfxrom_valid(l0_gfxrom_valid), .gfxrom_data(l0_gfxrom_data),
		.pixel_valid(l0_pixel_valid), .pixel_index(l0_pixel_index), .pixel_color(l0_pixel_color), .fetch_overrun(l0_fetch_overrun)
	);

	logic [15:0] l0_vram [0:4095];
	always_ff @(posedge clk) l0_vram_data <= l0_vram[l0_vram_addr];
	logic [15:0] l0_rowscroll_mem [0:255];
	always_ff @(posedge clk) l0_rowscroll_data <= l0_rowscroll_mem[l0_rowscroll_addr];

	// ---- tilemap layer 1 ----
	logic [1:0]  l1_mode;
	logic [15:0] l1_base_x_scroll, l1_base_y_scroll;
	logic [1:0]  l1_bank;
	logic         l1_rowscroll_enable, l1_rowscroll_pertile;
	logic [7:0]  l1_rowscroll_addr;
	logic [15:0] l1_rowscroll_data;
	logic [11:0] l1_vram_addr;
	logic [15:0] l1_vram_data;
	logic         l1_gfxrom_req;
	logic [21:0] l1_gfxrom_addr;
	logic         l1_gfxrom_valid;
	logic [63:0] l1_gfxrom_data;
	logic         l1_pixel_valid;
	logic [3:0]  l1_pixel_index;
	logic [6:0]  l1_pixel_color;
	logic         l1_fetch_overrun;

	assign l1_mode = 2'd0;
	assign l1_base_x_scroll = 16'd0;
	assign l1_base_y_scroll = 16'd0;
	assign l1_bank = 2'd0;
	assign l1_rowscroll_enable = 1'b0;
	assign l1_rowscroll_pertile = 1'b0;

	tilemap_line_engine #(.LAYER(1)) tle1 (
		.clk(clk), .reset(reset_l1),
		.vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
		.mode(l1_mode), .base_x_scroll(l1_base_x_scroll), .base_y_scroll(l1_base_y_scroll), .bank(l1_bank),
		.rowscroll_enable(l1_rowscroll_enable), .rowscroll_pertile(l1_rowscroll_pertile),
		.rowscroll_addr(l1_rowscroll_addr), .rowscroll_data(l1_rowscroll_data),
		.vram_addr(l1_vram_addr), .vram_data(l1_vram_data),
		.gfxrom_req(l1_gfxrom_req), .gfxrom_addr(l1_gfxrom_addr), .gfxrom_valid(l1_gfxrom_valid), .gfxrom_data(l1_gfxrom_data),
		.pixel_valid(l1_pixel_valid), .pixel_index(l1_pixel_index), .pixel_color(l1_pixel_color), .fetch_overrun(l1_fetch_overrun)
	);

	logic [15:0] l1_vram [0:4095];
	always_ff @(posedge clk) l1_vram_data <= l1_vram[l1_vram_addr];
	logic [15:0] l1_rowscroll_mem [0:255];
	always_ff @(posedge clk) l1_rowscroll_data <= l1_rowscroll_mem[l1_rowscroll_addr];

	// ---- DDRAM transport: ddram_arbiter -> ddram_phy -> ddram_model ----
	logic         c0_req, c1_req, c2_req, c3_req;
	logic [27:0] c0_addr, c1_addr, c2_addr, c3_addr;
	logic         c0_valid, c1_valid, c2_valid, c3_valid;
	logic [63:0] c0_data, c1_data, c2_data, c3_data;

	assign c0_req  = l0_gfxrom_req;
	assign c0_addr = TILES_BASE + {6'd0, l0_gfxrom_addr};
	assign l0_gfxrom_valid = c0_valid;
	assign l0_gfxrom_data  = c0_data;

	assign c1_req  = l1_gfxrom_req;
	assign c1_addr = TILES_BASE + {6'd0, l1_gfxrom_addr};
	assign l1_gfxrom_valid = c1_valid;
	assign l1_gfxrom_data  = c1_data;

	assign c2_req = 1'b0;
	assign c2_addr = 28'd0;
	assign c3_req = 1'b0;
	assign c3_addr = 28'd0;

	logic         dl_req, dl_busy;
	logic [27:0] dl_addr;
	logic [7:0]  dl_data;
	assign dl_req = 1'b0;
	assign dl_addr = 28'd0;
	assign dl_data = 8'd0;

	logic         phy_req, phy_we, phy_busy, phy_valid;
	logic [27:0] phy_addr;
	logic [7:0]  phy_wdata;
	logic [63:0] phy_rdata;

	ddram_arbiter arb (
		.clk(clk), .reset(reset_ddram),
		.phy_req(phy_req), .phy_we(phy_we), .phy_addr(phy_addr), .phy_wdata(phy_wdata),
		.phy_busy(phy_busy), .phy_valid(phy_valid), .phy_rdata(phy_rdata),
		.c0_req(c0_req), .c0_addr(c0_addr), .c0_valid(c0_valid), .c0_data(c0_data),
		.c1_req(c1_req), .c1_addr(c1_addr), .c1_valid(c1_valid), .c1_data(c1_data),
		.c2_req(c2_req), .c2_addr(c2_addr), .c2_valid(c2_valid), .c2_data(c2_data),
		.c3_req(c3_req), .c3_addr(c3_addr), .c3_valid(c3_valid), .c3_data(c3_data),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy)
	);

	logic         m_busy, m_dout_ready, m_rd, m_we;
	logic [7:0]  m_burstcnt, m_be;
	logic [28:0] m_addr;
	logic [63:0] m_dout, m_din;

	ddram_phy phy (
		.clk(clk), .reset(reset_ddram),
		.DDRAM_BUSY(m_busy), .DDRAM_BURSTCNT(m_burstcnt), .DDRAM_ADDR(m_addr),
		.DDRAM_DOUT(m_dout), .DDRAM_DOUT_READY(m_dout_ready), .DDRAM_RD(m_rd),
		.DDRAM_DIN(m_din), .DDRAM_BE(m_be), .DDRAM_WE(m_we),
		.req(phy_req), .we(phy_we), .addr(phy_addr), .wdata(phy_wdata),
		.busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
	);

	// longer latency than earlier tests (10 cycles vs 6/13 in ddram_phy_tb)
	// -- deliberately closer to real DDR3 round-trip cost, to make sure
	// the arbiter's fairness/timing holds under a more realistic load
	ddram_model #(.READ_LATENCY(10), .BUSY_CYCLES(2)) model (
		.clk(clk), .reset(reset_ddram),
		.DDRAM_BUSY(m_busy), .DDRAM_BURSTCNT(m_burstcnt), .DDRAM_ADDR(m_addr),
		.DDRAM_DOUT(m_dout), .DDRAM_DOUT_READY(m_dout_ready), .DDRAM_RD(m_rd),
		.DDRAM_DIN(m_din), .DDRAM_BE(m_be), .DDRAM_WE(m_we)
	);

	// ---- compositor ----
	logic l1_ctrl_enable_live;
	logic [11:0] pal_addr;
	logic [15:0] pal_data;
	logic [14:0] rgb;

	compositor comp (
		.l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
		.l0_ctrl_enable(1'b1), .l0_ctrl_opaque(1'b1), .l0_ctrl_transpen_sel(1'b1),
		.l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
		.l1_ctrl_enable(l1_ctrl_enable_live), .l1_ctrl_opaque(1'b1), .l1_ctrl_transpen_sel(1'b1),
		.sp_present(1'b0), .sp_pixel(4'd0), .sp_color(5'd0), .sp_priority(2'd0),
		.pal_addr(pal_addr), .pal_data(pal_data),
		.rgb(rgb)
	);

	always_ff @(posedge clk) pal_data <= {3'd0, pal_addr};

	int errors;
	int pixel_checked_count;

	initial begin
		#30000000;
		$display("TIMEOUT: simulation did not finish in time");
		$finish;
	end

	initial begin
		errors = 0;
		pixel_checked_count = 0;

		for (int i = 0; i < 4096; i++) l0_vram[i] = 16'h0000;   // tile 0, color 0
		for (int i = 0; i < 4096; i++) l1_vram[i] = 16'h2000;   // tile 0, color 65
		for (int i = 0; i < 256; i++) begin
			l0_rowscroll_mem[i] = 16'h0000;
			l1_rowscroll_mem[i] = 16'h0000;
		end

		l1_ctrl_enable_live = 1'b1;

		reset_vt = 1; reset_l0 = 1; reset_l1 = 1; reset_ddram = 1;
		repeat (15) @(posedge clk);
		reset_vt = 0; reset_l0 = 0; reset_l1 = 0; reset_ddram = 0;
		@(posedge clk);

		// Seed the shared "tiles" DDRAM region with a fixed, known 0x00
		// pattern at every granule tile 0's 16 rows can address
		// (gfxrom_addr = 0 + fine_y*8, fine_y 0-15 -> byte offsets
		// 0,8,16,...,120 within the region) -- same reasoning as
		// tb_video_pipeline_compositor.sv for why a fixed, address-
		// independent-in-effect pattern (all zero here) is the right
		// choice: keeps decoded pixel content constant across every row,
		// which is what this test needs to check a single expected value
		// through the whole frame.
		for (int fine_y = 0; fine_y < 16; fine_y++) begin
			for (int lane = 0; lane < 8; lane++) begin
				model.poke_byte(TILES_BASE + fine_y*8 + lane, 8'h00);
			end
		end

		repeat (3) begin
			do @(posedge clk); while (!line_start);
		end
		@(posedge clk);

		// ---- Case 1: both layers enabled, served through the real DDRAM
		// arbiter/phy -- layer 1 must always win ----
		repeat (456 * 3) begin
			@(posedge clk);
			if (h_active && hcnt >= 9'd2) begin
				// Same pipeline-startup margin as
				// tb_video_pipeline_compositor.sv (hcnt<2 excluded) --
				// adjusted below if the real arbiter/phy's longer round
				// trip turns out to need more.
				pixel_checked_count++;
				if (rgb !== 15'h0C10) begin
					errors++;
					$display("FAIL(case1) hcnt=%0d vcnt=%0d expected rgb=0C10 got=%h", hcnt, vcnt_raw, rgb);
				end
			end
		end
		$display("Case 1 done (%0d active pixels checked, layer 1 always wins, via real DDRAM arbiter/phy)", pixel_checked_count);

		if (errors == 0)
			$display("PASS: both tilemap layers correctly served through the real ddram_arbiter/ddram_phy under sustained operation");
		else
			$display("FAIL: %0d mismatches -- EXPECTED for now, see this file's header: confirms docs/phase1_ddram_map.md's already-documented throughput/bandwidth open item, not a new bug. Do not loosen these checks to force a PASS -- fix the underlying throughput budget instead (wider ddram_phy bursts and/or a prefetch-ahead scheduling scheme), then this test should start passing on its own.", errors);

		$finish;
	end

endmodule
