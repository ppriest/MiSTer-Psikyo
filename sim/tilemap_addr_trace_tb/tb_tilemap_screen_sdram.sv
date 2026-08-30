// tb_tilemap_screen.sv's maximum-fidelity variant: identical screen-path
// render of the Gunbird title case (real video_timing -> vreg_decode ->
// tilemap_line_engine LAYER=1 -> compositor + palette dpram, real captured
// VRAM/vregs/palette), but with the behavioral 3-cycle gfxrom model
// replaced by the ENTIRE production SDRAM transport, verbatim:
// rtl/memory/psikyo_sdram_top.sv (sdram_phy port 1 -> sdram.sv burst-4
// controller -> gfxrom_byte_reorder, the exact modules and wiring the
// deployed .rbf runs) talking to the verified sdram_chip_model, preloaded
// with the real tiles ROM (u33) at TILES_BASE.
//
// Purpose (docs/TILEMAP_BUG.md): the behavioral model's fixed 3-cycle
// latency is shorter than the engine's ~4-cycle line_start restart window,
// so a response to a request abandoned at line_start can never be
// mistaken for the next line's first fetch in that sim -- but the real
// controller's 15-35 cycle latencies CAN cross that window, and
// sdram_phy.sv completes and pulses valid for an abandoned transaction
// unconditionally. If that protocol seam is the bug's mechanism, THIS sim
// reproduces the one-tile displacement; if it renders clean, the remaining
// deltas vs hardware are concurrent port-0/port-2 traffic and synthesis.
//
// Compile with +define+REAL_CE_PIX for the production 1-in-12 pixel-clock
// gating (recommended -- cadence affects when fetches are in flight).

module tb_tilemap_screen_sdram;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;
	logic ce_pix;
`ifdef REAL_CE_PIX
	// Production ce_pix, copied verbatim from Psikyo.sv:236-242.
	logic [3:0] ce_pix_cnt = 0;
	assign ce_pix = (ce_pix_cnt == 0);
	always_ff @(posedge clk)
		ce_pix_cnt <= (ce_pix_cnt == 11) ? 4'd0 : ce_pix_cnt + 4'd1;
`else
	assign ce_pix = 1'b1;
`endif

	// ---- video timing (real) ----
	logic [8:0] hcnt, vcnt;
	logic [7:0] vcnt_active;
	logic        h_active, v_active, hblank, vblank, hsync, vsync;
	logic        line_start, frame_start;

	video_timing u_timing (
		.clk(clk), .ce_pix(ce_pix), .reset(reset),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_active(vcnt_active),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start)
	);

	// ---- vreg decode (real) ----
	logic [12:0] vregs_cpu_addr;
	logic         vregs_cpu_wel, vregs_cpu_weh;
	logic [15:0] vregs_cpu_wdata, vregs_cpu_rdata;

	logic [7:0]  l0_rowscroll_addr, l1_rowscroll_addr;
	logic [15:0] l0_rowscroll_data, l1_rowscroll_data;
	logic [1:0]  l0_mode, l1_mode;
	logic [15:0] l0_base_x, l0_base_y, l1_base_x, l1_base_y;
	logic [1:0]  l0_bank, l1_bank;
	logic         l0_enable, l1_enable;
	logic         l0_opaque, l1_opaque;
	logic         l0_transpen_sel, l1_transpen_sel;
	logic         l0_rs_en, l1_rs_en;
	logic         l0_rs_pertile, l1_rs_pertile;

	vreg_decode u_vregs (
		.sh404_banking(1'b0), .mcu_bctrl(8'd0),
		.clk(clk), .reset(reset),
		.cpu_addr(vregs_cpu_addr), .cpu_wel(vregs_cpu_wel), .cpu_weh(vregs_cpu_weh),
		.cpu_wdata(vregs_cpu_wdata), .cpu_rdata(vregs_cpu_rdata),
		.layer0_rowscroll_addr(l0_rowscroll_addr), .layer0_rowscroll_data(l0_rowscroll_data),
		.layer1_rowscroll_addr(l1_rowscroll_addr), .layer1_rowscroll_data(l1_rowscroll_data),
		.layer0_mode(l0_mode), .layer0_base_x_scroll(l0_base_x), .layer0_base_y_scroll(l0_base_y),
		.layer0_bank(l0_bank), .layer0_enable(l0_enable), .layer0_opaque(l0_opaque),
		.layer0_transpen_sel(l0_transpen_sel),
		.layer0_rowscroll_enable(l0_rs_en), .layer0_rowscroll_pertile(l0_rs_pertile),
		.layer1_mode(l1_mode), .layer1_base_x_scroll(l1_base_x), .layer1_base_y_scroll(l1_base_y),
		.layer1_bank(l1_bank), .layer1_enable(l1_enable), .layer1_opaque(l1_opaque),
		.layer1_transpen_sel(l1_transpen_sel),
		.layer1_rowscroll_enable(l1_rs_en), .layer1_rowscroll_pertile(l1_rs_pertile),
		.ka302c_banking(1'b1),
		.dbg_dump_en(1'b0), .dbg_dump_addr(13'd0), .dbg_dump_data()
	);
	assign l0_rowscroll_addr = 8'd0;

	// ---- layer-1 tilemap engine (real) ----
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

	tilemap_line_engine #(.LAYER(1)) u_layer1 (
		.clk(clk), .reset(reset),
		.vcnt(vcnt_active), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(l1_mode), .base_x_scroll(l1_base_x), .base_y_scroll(l1_base_y), .bank(l1_bank),
		.rowscroll_enable(l1_rs_en), .rowscroll_pertile(l1_rs_pertile),
		.rowscroll_addr(l1_rowscroll_addr), .rowscroll_data(l1_rowscroll_data),
		.vram_addr(l1_vram_addr), .vram_data(l1_vram_data),
		.gfxrom_req(l1_gfxrom_req), .gfxrom_addr(l1_gfxrom_addr),
		.gfxrom_valid(l1_gfxrom_valid), .gfxrom_data(l1_gfxrom_data),
		.pixel_valid(l1_pixel_valid), .pixel_index(l1_pixel_index), .pixel_color(l1_pixel_color),
		.fetch_overrun(l1_fetch_overrun)
`ifdef DEBUG_ISSP
		,
		.dbg_fetch_vram_addr(), .dbg_vram_data(),
		.dbg_cell_tile_number(), .dbg_cell_color(),
		.dbg_mode_latched(), .dbg_bank_latched(),
		.dbg_pixel_src_addr(), .dbg_pixel_src_word()
`endif
	);

	// ---- VRAM1 + palette (real dprams, real captured content) ----
	logic [15:0] vram1_a_rdata_unused;
	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
		.clk(clk),
		.a_addr(12'd0), .a_wel(1'b0), .a_weh(1'b0),
		.a_wdata(16'd0), .a_rdata(vram1_a_rdata_unused),
		.b_addr(l1_vram_addr), .b_rdata(l1_vram_data)
	);

	logic [11:0] pal_addr;
	logic [15:0] pal_b_rdata;
	logic [15:0] pal_a_rdata_unused;
	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
		.clk(clk),
		.a_addr(12'd0), .a_wel(1'b0), .a_weh(1'b0),
		.a_wdata(16'd0), .a_rdata(pal_a_rdata_unused),
		.b_addr(pal_addr), .b_rdata(pal_b_rdata)
	);

	// ---- compositor (real) ----
	logic [14:0] rgb;
	compositor u_compositor (
		.l0_valid(1'b0), .l0_pixel(4'd0), .l0_color(7'd0),
		.l0_ctrl_enable(1'b0), .l0_ctrl_opaque(l0_opaque), .l0_ctrl_transpen_sel(l0_transpen_sel),
		.l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
		.l1_ctrl_enable(l1_enable), .l1_ctrl_opaque(l1_opaque), .l1_ctrl_transpen_sel(l1_transpen_sel),
		.sp_present(1'b0), .sp_pixel(4'd0), .sp_color(5'd0), .sp_priority(2'd0),
		.pal_addr(pal_addr), .pal_data(pal_b_rdata),
		.rgb(rgb)
	);

	// ---- PRODUCTION SDRAM TRANSPORT, verbatim: psikyo_sdram_top with
	// every consumer except l1 gfxrom tied off, exactly the module the
	// deployed .rbf runs ----
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic [1:0]  SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	logic         SDRAM_CLK, SDRAM_CKE;
	wire  [15:0] SDRAM_DQ;

	psikyo_sdram_top u_sdram (
		.clk(clk), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
		.ioctl_addr(25'd0), .ioctl_dout(8'd0), .ioctl_wait(),
		.l0_gfxrom_req(1'b0), .l0_gfxrom_addr(22'd0),
		.l0_gfxrom_valid(), .l0_gfxrom_data(),
		.l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
		.l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
		.sp_gfxrom_req(1'b0), .sp_gfxrom_addr(23'd0),
		.sp_gfxrom_valid(), .sp_gfxrom_data(),
		.sp_lut_req(1'b0), .sp_lut_addr(17'd0),
		.sp_lut_valid(), .sp_lut_data(),
		.cpu_rom_req(1'b0), .cpu_rom_addr(19'd0),
		.cpu_rom_valid(), .cpu_rom_data(),
		.audiocpu_rom_req(1'b0), .audiocpu_rom_addr(18'd0),
		.audiocpu_rom_valid(), .audiocpu_rom_data(),
		.adpcma_rom_req(1'b0), .adpcma_rom_addr(20'd0),
		.adpcma_rom_valid(), .adpcma_rom_data()
	);

	// The _wide variant: full 24-bit {bank,row[12:0],col} address space.
	// The base sdram_chip_model folds rows to 8 bits and ALIASES any
	// footprint above ~256KB -- the 2MB tiles preload at TILES_BASE
	// (0x0A40000) corrupts itself in it (first run of this TB proved so:
	// a garbage frame with 49952 stray green pixels, purely a testbench
	// artifact -- same trap tb_psikyo_top_realrom.sv hit, see the wide
	// model's own header).
	sdram_chip_model_wide chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- content preload ----
	localparam logic [24:0] TILES_BASE = 25'h0A40000;
	logic [7:0] u33 [0:2097151];

	initial begin
		$readmemh("real_vram1_dump.hex",   u_vram1.mem);
		$readmemh("real_palette_dump.hex", u_palette.mem);
		$readmemh("real_vregs_dump.hex", u_vregs.u_ram_l0.mem);
		$readmemh("real_vregs_dump.hex", u_vregs.u_ram_l1.mem);
		// tiles ROM into the SDRAM chip model at TILES_BASE: ascending byte
		// stream packed little-endian into 16-bit words, the same layout
		// the real HPS download produces (sdram.sv's ascending-address ->
		// ascending-bit convention; gfxrom_byte_reorder flips to the
		// MSB-first order the engine needs, all inside psikyo_sdram_top).
		$readmemh("u33_swapped.hex", u33);
		for (int i = 0; i < 1048576; i++)
			chip.poke_word_addr(24'((TILES_BASE >> 1) + i), {u33[2*i+1], u33[2*i]});
	end

	// ---- CPU-port vreg write task ----
	task automatic vreg_write(logic [12:0] addr, logic [15:0] data);
		@(posedge clk);
		vregs_cpu_addr  <= addr;
		vregs_cpu_wdata <= data;
		vregs_cpu_wel   <= 1'b1;
		vregs_cpu_weh   <= 1'b1;
		@(posedge clk);
		vregs_cpu_wel   <= 1'b0;
		vregs_cpu_weh   <= 1'b0;
	endtask

	// ---- frame capture (identical to tb_tilemap_screen.sv) ----
	logic [8:0] hcnt_d, vcnt_d;
	logic        active_d;
	int          frame_num;
	integer      fcap;

	always_ff @(posedge clk) begin
		if (reset) begin
			active_d  <= 1'b0;
			frame_num <= 0;
		end else begin
			hcnt_d    <= hcnt;
			vcnt_d    <= vcnt;
			active_d  <= ce_pix && h_active && v_active;
			if (frame_start) frame_num <= frame_num + 1;
			if (active_d && frame_num == 3 && fcap != 0)
				$fwrite(fcap, "%0d %0d %04h\n", vcnt_d, hcnt_d, rgb);
		end
	end

	// ---- mechanism trace (test-only, hierarchical monitors, no RTL
	// change): around line boundaries in frame 3, log line_start with the
	// phy's in-flight state, every gfxrom_valid with BOTH the address the
	// data actually came from (phy1.port_addr -- still the completed
	// transaction's address during the valid pulse, latched anew only at
	// the end of that cycle) and the address the engine currently thinks
	// it is waiting for (l1_gfxrom_addr). A mismatch between the two at a
	// consumed valid is the smoking gun. ----
	localparam logic [24:0] TRC_TILES_BASE = 25'h0A40000;
	wire trace_on = (frame_num == 3) && (vcnt >= 9'd99) && (vcnt <= 9'd102);

	always_ff @(posedge clk) begin
		if (trace_on && line_start)
			$display("[%0t] LINE_START vcnt=%0d: phy1_busy=%0d engine_state=%0d gfxrom_req=%0d (in-flight addr=0x%06X)",
					  $time, vcnt, u_sdram.phy1.busy, u_layer1.state, l1_gfxrom_req,
					  {u_sdram.phy1.port_addr, 1'b0});
		if (trace_on && l1_gfxrom_valid)
			$display("[%0t] VALID: data from byte 0x%06X (tile %0d) -- engine in state %0d waiting for gfxrom_addr 0x%06X (tile %0d) fetch_target=%0d %s",
					  $time,
					  {u_sdram.phy1.port_addr, 1'b0} - TRC_TILES_BASE,
					  ({u_sdram.phy1.port_addr, 1'b0} - TRC_TILES_BASE) >> 7,
					  u_layer1.state, l1_gfxrom_addr, l1_gfxrom_addr >> 7,
					  u_layer1.fetch_target,
					  (({u_sdram.phy1.port_addr, 1'b0} - TRC_TILES_BASE) != {3'd0, l1_gfxrom_addr})
						? "<-- STALE/MISMATCHED RESPONSE" : "ok");
	end

	initial begin
		fcap = 0;
		reset = 1;
		vregs_cpu_addr = '0; vregs_cpu_wdata = '0;
		vregs_cpu_wel = 0; vregs_cpu_weh = 0;
		repeat (15) @(posedge clk);
		reset = 0;
		// sdram.sv's power-up mode-register-load sequence (same 500-cycle
		// headroom as tb_sdram.sv / tb_video_pipeline_sdram.sv); the
		// engines run during it and simply stall on their first fetch.
		repeat (500) @(posedge clk);

		vreg_write(13'h201, 16'h0000);
		vreg_write(13'h203, 16'h0000);
		vreg_write(13'h205, 16'h0000);
		vreg_write(13'h207, 16'h0140);
		vreg_write(13'h209, 16'h00D0);
		vreg_write(13'h20B, 16'h04D0);

		fcap = $fopen("screen_dump_sdram.txt", "w");
		if (fcap == 0) begin $display("FAIL: cannot open screen_dump_sdram.txt"); $finish; end

		wait (frame_num == 4);
		$fclose(fcap);
		fcap = 0;
		$display("PASS: captured frame 3 to screen_dump_sdram.txt");
		if (l1_fetch_overrun)
			$display("NOTE: l1_fetch_overrun sticky flag was set at least once (may be from the init-stall frames)");
		$finish;
	end

endmodule
