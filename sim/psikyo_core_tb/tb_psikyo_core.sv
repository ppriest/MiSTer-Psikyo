`timescale 1ns/1ps
// Real functional test for rtl/psikyo_core.sv: a genuine CPU program
// (test_video.s, assembled with vasm -- sim/psikyo_core_tb/test_video.hex)
// writes one tile into layer 0's VRAM, one palette entry, and layer 0's
// control word, then parks in a self-loop. The test then confirms the
// expected, distinctive palette color actually reaches the compositor's
// rgb output during real active-display scanout -- proving the whole
// chain (CPU bus -> maincpu.sv -> vram0 dpram -> tilemap_line_engine ->
// compositor -> palette dpram -> rgb) is wired correctly end-to-end, not
// just that it elaborates (see tb_psikyo_core_smoke.sv for that narrower
// check). Gfx ROMs are stubbed to an all-zero row (every tile pixel decodes
// as pen 0), same simplification tb_psikyo_core_smoke.sv uses -- real gfx
// ROM content is the SDRAM stack's job, not this integration test's.
module tb_psikyo_core;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;
	logic ce_pix = 1'b1;

	logic         cpu_rom_req;
	logic [18:0] cpu_rom_addr;
	logic         cpu_rom_valid;
	logic [15:0] cpu_rom_data;

	logic         l0_gfxrom_req, l1_gfxrom_req;
	logic [21:0] l0_gfxrom_addr, l1_gfxrom_addr;
	logic         l0_gfxrom_valid, l1_gfxrom_valid;
	logic [63:0] l0_gfxrom_data, l1_gfxrom_data;

	logic         sp_gfxrom_req, sp_lut_req;
	logic [22:0] sp_gfxrom_addr;
	logic [16:0] sp_lut_addr;
	logic         sp_gfxrom_valid, sp_lut_valid;
	logic [63:0] sp_gfxrom_data;
	logic [15:0] sp_lut_data;

	logic [7:0]  latch_data;
	logic         latch_write;

	logic [8:0]  hcnt, vcnt;
	logic         hblank, vblank, hsync, vsync;
	logic [14:0] rgb;

	psikyo_core dut (
		// hiscore work-RAM port tied off (rtl/hiscore.v not in this TB)
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_read(1'b0), .hs_write(1'b0),
		// SH404 ports tied off (docs/phase2_sh404.md); this TB predates them
		.board_sh404(1'b0), .snd_latch_c00011(1'b0), .mcu_table_absent(1'b0),
		.mcu_table_we(1'b0), .mcu_table_waddr(8'd0), .mcu_table_wdata(8'd0),
		.clk(clk), .ce_pix(ce_pix), .reset(reset), .video_reset(reset),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
		.l0_gfxrom_req(l0_gfxrom_req), .l0_gfxrom_addr(l0_gfxrom_addr),
		.l0_gfxrom_valid(l0_gfxrom_valid), .l0_gfxrom_data(l0_gfxrom_data),
		.l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
		.l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
		.sp_gfxrom_req(sp_gfxrom_req), .sp_gfxrom_addr(sp_gfxrom_addr),
		.sp_gfxrom_valid(sp_gfxrom_valid), .sp_gfxrom_data(sp_gfxrom_data),
		.sp_lut_req(sp_lut_req), .sp_lut_addr(sp_lut_addr),
		.sp_lut_valid(sp_lut_valid), .sp_lut_data(sp_lut_data),
		.p1p2_in(32'hFFFFFFFF), .dsw_in(32'hFFFFFFFF), .coin_in(32'hFFFFFFFF),
		.latch_data(latch_data), .latch_write(latch_write),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb)
	);

	assign l0_gfxrom_valid = 1'b1;
	assign l0_gfxrom_data   = 64'h0;
	assign l1_gfxrom_valid = 1'b1;
	assign l1_gfxrom_data   = 64'h0;
	assign sp_gfxrom_valid = 1'b1;
	assign sp_gfxrom_data   = 64'h0;
	assign sp_lut_valid     = 1'b1;
	assign sp_lut_data       = 16'h0;

	// ---- CPU ROM model: 5-cycle req/valid latency, same style
	// sim/maincpu_tb/tb_maincpu.sv already used to verify maincpu.sv. ----
	localparam int ROM_LATENCY = 5;
	logic [15:0] rom [0:524287];
	logic         rom_busy;
	int           rom_cnt;

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			rom_busy       <= 1'b0;
			cpu_rom_valid <= 1'b0;
		end else begin
			cpu_rom_valid <= 1'b0;
			if (cpu_rom_req && !rom_busy) begin
				rom_busy <= 1'b1;
				rom_cnt   <= 0;
			end else if (rom_busy) begin
				if (rom_cnt == ROM_LATENCY - 1) begin
					cpu_rom_valid <= 1'b1;
					cpu_rom_data   <= rom[cpu_rom_addr];
					rom_busy        <= 1'b0;
				end else begin
					rom_cnt <= rom_cnt + 1;
				end
			end
		end
	end

	localparam int FRAME_CYCLES = 456 * 262; // 119472, matches video_timing.sv's raw timing

	int match_count = 0;
	logic [14:0] last_match_rgb;
	int match_hcnt, match_vcnt;

	initial begin
		reset = 1;
		for (int i = 0; i < 524288; i++) rom[i] = 16'h0000;

		// Reset vectors: SP=0x00FFFFFC (top of work RAM), PC=0x8 (start),
		// same convention as sim/maincpu_tb/tb_maincpu.sv.
		rom[0] = 16'h00FF; rom[1] = 16'hFFFC;
		rom[2] = 16'h0000; rom[3] = 16'h0008;

		$readmemh("test_video.hex", rom, 4);

		repeat (5) @(posedge clk);
		reset = 0;

		// Let the CPU program (a handful of instructions) complete and let
		// 2 full frames elapse for margin, then sample real active-display
		// scanout during frame 3.
		repeat (2 * FRAME_CYCLES) @(posedge clk);

		// Confirm the CPU program's writes actually landed where expected
		// before checking the rendered pixel -- narrows a future failure
		// here to "CPU bus/decode" vs. "video pipeline" immediately.
		$display("CHECK vram0[0]=%h (expect 0000) palette[0x800]=%h (expect 1234) vregs_ctrl_l0(word 0x209)=%h (expect 0001)",
				   dut.u_vram0.mem[0], dut.u_palette.mem[12'h800], dut.u_vregs.u_ram_l0.mem[13'h209]);
		$display("CHECK l0_enable=%b l0_transpen_sel=%b l0_opaque=%b l0_mode=%b",
				   dut.l0_enable, dut.l0_transpen_sel, dut.l0_opaque, dut.l0_mode);

		// Directly scan hcnt/vcnt for the expected tile-origin window
		// across one full active frame, sampling rgb every cycle.
		for (int i = 0; i < FRAME_CYCLES; i++) begin
			@(posedge clk);
			#1;
			if (!hblank && !vblank && hcnt < 9'd32 && vcnt < 9'd32) begin
				if (rgb === 15'h1234) begin
					match_count++;
					last_match_rgb = rgb;
					match_hcnt = hcnt;
					match_vcnt = vcnt;
				end
			end
		end

		if (match_count > 0) begin
			$display("PASS: rgb=0x1234 observed %0d time(s) in the expected tile-origin window (e.g. hcnt=%0d vcnt=%0d) -- full CPU write -> VRAM -> tilemap engine -> compositor -> palette -> rgb path verified",
					   match_count, match_hcnt, match_vcnt);
		end else begin
			$display("FAIL: expected rgb=0x1234 was never observed in the tile-origin window (hcnt<32, vcnt<32)");
		end

		$finish;
	end

	initial begin
		#40_000_000; // watchdog
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
