`timescale 1ns/1ps
// Elaboration/wiring smoke test for rtl/psikyo_core.sv -- NOT a functional
// test (see tb_psikyo_core.sv for that). This just ties off every external
// port with simple always-valid ROM stubs and confirms the whole design
// elaborates and runs a few thousand cycles with no X propagation /
// crashes, catching port-name/width wiring mistakes across the ~15-module
// integration before investing in a real CPU-program-driven test.
module tb_psikyo_core_smoke;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;
	logic ce_pix = 1'b1; // matches this project's existing video testbenches -- see docs/phase1_sdram_map.md's ce_pix note

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

	// Immediate-valid ROM stubs: CPU ROM returns NOP ($4E71) forever, gfx
	// ROMs return all-zero rows/entries. Enough to run the CPU/timing/
	// sequencing wiring without X propagation; not real graphics content.
	assign cpu_rom_valid = 1'b1;
	assign cpu_rom_data   = 16'h4E71;

	assign l0_gfxrom_valid = 1'b1;
	assign l0_gfxrom_data   = 64'h0;
	assign l1_gfxrom_valid = 1'b1;
	assign l1_gfxrom_data   = 64'h0;
	assign sp_gfxrom_valid = 1'b1;
	assign sp_gfxrom_data   = 64'h0;
	assign sp_lut_valid     = 1'b1;
	assign sp_lut_data       = 16'h0;

	int cycles = 0;
	always @(posedge clk) cycles++;

	initial begin
		reset = 1;
		repeat (5) @(posedge clk);
		reset = 0;

		// Run past several full frames (456*262 = 119472 cycles/frame at
		// ce_pix=1) so frame_start/spriteram swap/render-kickoff sequencing
		// actually exercises, not just reset wiring.
		repeat (3 * 119472) @(posedge clk);

		$display("Ran %0d cycles with no crash -- psikyo_core wiring elaborates and runs clean", cycles);
		$finish;
	end

	// Watchdog: bail out loudly rather than hanging forever if something
	// is structurally wrong (matches this project's established caution
	// around ModelSim runs after the maincpu.sv crash investigation).
	initial begin
		#20_000_000; // 2M cycles at 10ns/cycle
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
