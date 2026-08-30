`timescale 1ns/1ps

// Real audio-domain functional test for jt10 (YM2610 wrapper), not just a
// compile-clean check -- see rtl/sound/jt10/PROVENANCE.md's "Status"
// checklist, which explicitly called out that a compile-only pass should
// not be reported as "verified."
//
// Scope: the SSG (AY-3-8910-compatible tone generator, jt49) only. This is
// the first real jt10 verification of any kind in this project, and jt49
// itself was only discovered to be MISSING from the vendored tree while
// building this test (jt12_top.v instantiates a module named `jt49` that
// PROVENANCE.md's original vendoring pass excluded as "scaffolding" --
// it's actually jt12's own submodule dependency, github.com/jotego/jt49,
// fetched separately into rtl/sound/jt49/ at commit 47301ed). FM channel
// and ADPCM-A/B ROM-interface verification are explicitly NOT covered here
// -- tracked as follow-up work in PROVENANCE.md, not silently assumed fine
// because "the SSG worked."
//
// What this proves: drives jt10 through its real CPU register-write
// protocol (the same addr[1:0] latch/data, part I/II scheme a real 68k/Z80
// sound driver would use) to configure SSG channel A for two different
// known tone periods, then measures the actual generated square wave on
// the real `psg_A` output port and checks it against the period frequency
// AY-3-8910/jt49 formula derived directly from reading jt49_cen.v/
// jt49_div.v/jt12_div.v (not assumed from a datasheet): with cen tied high,
//   clk_en_ssg  = clk / 4   (jt12_div, div_setting reset value 2'b10)
//   cen16       = clk_en_ssg / 8   (jt49_cen, CLKDIV=3, sel=1)
//   bitA toggle = cen16 / period   (jt49_div)
//   => one full square-wave period = 64 * period raw clk cycles.
// Two independent period values (256 and 128) are checked, both against
// the absolute formula AND against each other's 2:1 ratio -- a relative
// check that catches a formula mistake a single lucky absolute match could
// hide.

module tb_jt10_ssg;

reg clk = 0;
always #5 clk = ~clk; // 100MHz sim clock -- arbitrary, not meant to match
					   // any real Psikyo board clock; see PROVENANCE.md,
					   // this is an isolated functional check of jt10/jt49
					   // themselves, independent of top-level clock wiring.

reg cen = 1'b1;
reg rst = 1'b1;
reg  [7:0] din;
reg  [1:0] addr;
reg        cs_n = 1'b1;
reg        wr_n = 1'b1;

wire [7:0] dout;
wire       irq_n;
wire [19:0] adpcma_addr;
wire [4:0]  adpcma_bank;
wire        adpcma_roe_n;
wire [23:0] adpcmb_addr;
wire        adpcmb_roe_n;
wire [7:0]  psg_A, psg_B, psg_C;
wire signed [15:0] fm_snd;
wire [9:0]  psg_snd;
wire signed [15:0] snd_right, snd_left;
wire        snd_sample;

jt10 dut(
	.rst            ( rst           ),
	.clk            ( clk           ),
	.cen            ( cen           ),
	.din            ( din           ),
	.addr           ( addr          ),
	.cs_n           ( cs_n          ),
	.wr_n           ( wr_n          ),
	.dout           ( dout          ),
	.irq_n          ( irq_n         ),
	.adpcma_addr    ( adpcma_addr   ),
	.adpcma_bank    ( adpcma_bank   ),
	.adpcma_roe_n   ( adpcma_roe_n  ),
	.adpcma_data    ( 8'h00         ),
	.adpcmb_addr    ( adpcmb_addr   ),
	.adpcmb_roe_n   ( adpcmb_roe_n  ),
	.adpcmb_data    ( 8'h00         ),
	.psg_A          ( psg_A         ),
	.psg_B          ( psg_B         ),
	.psg_C          ( psg_C         ),
	.fm_snd         ( fm_snd        ),
	.psg_snd        ( psg_snd       ),
	.snd_right      ( snd_right     ),
	.snd_left       ( snd_left      ),
	.snd_sample     ( snd_sample    ),
	.ch_enable      ( 6'b111111     )
);

task automatic ssg_reg_write(input [7:0] regno, input [7:0] data);
begin
	// Part I address latch (addr[1]=0 selects part I, where the SSG's
	// register file lives; addr[0]=0 selects latch-not-data).
	@(posedge clk); #1;
	addr = 2'b00; din = regno; cs_n = 1'b0; wr_n = 1'b0;
	@(posedge clk); #1;
	cs_n = 1'b1; wr_n = 1'b1;
	@(posedge clk); #1; // one idle bus cycle between latch and data

	// Part I data write.
	addr = 2'b01; din = data; cs_n = 1'b0; wr_n = 1'b0;
	@(posedge clk); #1;
	cs_n = 1'b1; wr_n = 1'b1;

	// busy lasts 32 clk_en (OPN-domain) cycles; with div_setting's reset
	// value clk_en = clk/6, that's <=192 clk cycles -- wait comfortably
	// longer before the next write.
	repeat (250) @(posedge clk);
end
endtask

// Configure SSG channel A only, mixer set to pass tone A / block
// everything else, per jt49.v's Amix/Bmix/Cmix derivation (read directly,
// not assumed): reg7 bit0=0 enables tone A, bit3=1 disables noise A,
// bits1/2/4/5=1 disable tone B/C and noise B/C so the combined psg_snd/
// psg_A output is unambiguously channel A alone.
task automatic configure_tone_a(input [11:0] period);
begin
	ssg_reg_write(8'h07, 8'hFE);                    // mixer
	ssg_reg_write(8'h00, period[7:0]);               // tone A period, fine
	ssg_reg_write(8'h01, {4'h0, period[11:8]});      // tone A period, coarse
	ssg_reg_write(8'h08, 8'h0F);                     // volume A = max, no envelope
end
endtask

// Measures one full psg_A square-wave period in raw clk cycles: a single
// clk-synchronized loop that finds two consecutive off->on (rising)
// transitions of (psg_A != 0) and counts the clk edges between them --
// exactly one full period, by construction, with no race between a
// separate `wait` and the counting loop (an earlier version used two
// independent `wait` statements straddling only one edge, which measured
// a half period -- caught because both test cases came back at almost
// exactly half their expected value, with the 2:1 ratio between them
// still intact, pointing at the testbench's measurement window rather
// than jt10/jt49's actual behavior).
task automatic measure_period(output integer period_cycles);
	integer cyc;
	integer rising_edges;
	reg     prev_on;
begin
	cyc = 0;
	rising_edges = 0;
	prev_on = (psg_A != 8'h00);
	forever begin
		@(posedge clk);
		cyc = cyc + 1;
		if (!prev_on && (psg_A != 8'h00)) begin
			rising_edges = rising_edges + 1;
			if (rising_edges == 1) begin
				cyc = 0;
			end else begin
				period_cycles = cyc;
				return;
			end
		end
		prev_on = (psg_A != 8'h00);
	end
end
endtask

integer errors = 0;
integer meas256, meas128;

initial begin
	repeat (30) @(posedge clk); // rst >= 6 clk&cen cycles, generous margin
	rst = 1'b0;
	repeat (10) @(posedge clk);

	// Case 1: period = 256 -> expected full period = 64*256 = 16384 clk cycles
	configure_tone_a(12'd256);
	measure_period(meas256);
	$display("[jt10_ssg] period=256: measured %0d clk cycles (expected 16384)", meas256);
	if (meas256 < 16384-64 || meas256 > 16384+64) begin
		$display("[jt10_ssg] FAIL: period=256 case out of tolerance");
		errors = errors + 1;
	end

	// Case 2: period = 128 -> expected full period = 64*128 = 8192 clk cycles
	configure_tone_a(12'd128);
	measure_period(meas128);
	$display("[jt10_ssg] period=128: measured %0d clk cycles (expected 8192)", meas128);
	if (meas128 < 8192-64 || meas128 > 8192+64) begin
		$display("[jt10_ssg] FAIL: period=128 case out of tolerance");
		errors = errors + 1;
	end

	// Relative check: halving the period register should almost exactly
	// halve the measured period, independent of the absolute formula.
	if (meas128 < (meas256/2 - 64) || meas128 > (meas256/2 + 64)) begin
		$display("[jt10_ssg] FAIL: period=128 measurement is not ~half of period=256 measurement");
		errors = errors + 1;
	end

	if (errors == 0)
		$display("[jt10_ssg] ALL TESTS PASSED");
	else
		$display("[jt10_ssg] %0d TEST(S) FAILED", errors);

	$finish;
end

initial begin
	#50_000_000; // 50ms safety timeout
	$display("[jt10_ssg] FAIL: simulation timeout, psg_A never toggled as expected");
	$finish;
end

endmodule
