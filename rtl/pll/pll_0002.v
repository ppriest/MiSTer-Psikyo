`timescale 1ns/10ps
// clk_sys / SDRAM_CLK plan (see rtl/psikyo_top.sv's own header for the
// division-ratio reasoning): 85.909091 MHz = 14.31818 MHz (this hardware's
// real pixel/screen XTAL, docs/phase1_memory_map.md) x 6 -- comfortably
// above rtl/memory/sdram/sdram.sv's own documented ~85 MHz assumption
// (RASCAS_DELAY's "tRCD=20ns -> 2 cycles@85MHz" comment; 85.909 MHz only
// widens that margin) and gives ce_pix an exact 12:1 integer divide ratio
// (85.909091 / 7.159091 = 12 -- avoids a fractional/Bresenham-style pixel
// clock divider entirely). outclk_1 is the SAME frequency, phase-shifted
// for SDRAM_CLK (the chip needs to see its clock edge advanced relative to
// the address/command bus, same reasoning rtl/memory/sdram/sdram.sv's own
// header documents for why that phase generation belongs at this
// top-level integration stage, not in the controller itself). -3000ps was
// the originally intended starting value (copied from the same ballpark
// several other MiSTer-devel SDRAM-equipped cores use for the DE10-nano's
// SDRAM daughterboard), but this altera_pll configuration's Fitter only
// accepts phase_shift in [0ps, one full output period), quantized to
// ~132.275ps steps -- a negative value is flatly illegal here, not just
// unverified (caught by a real `quartus_fit` run: "Error: PLL Output
// Counter parameter 'phase_shift' is set to an illegal value of '-3000
// ps'"). Expressed as the equivalent positive shift instead: one full
// 85.909091MHz period is ~11640.42ps, so -3000ps == +8640.42ps, rounded to
// the nearest legal enumerated step Quartus itself reported, 8598ps. Still
// NOT independently re-derived or hardware-tuned for this specific
// board/layout -- real DE10-nano bring-up should verify this against
// actual SDRAM read/write margin, not just trust it.
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.output_clock_frequency0("85.909091 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("85.909091 MHz"),
		.phase_shift1("5820 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

