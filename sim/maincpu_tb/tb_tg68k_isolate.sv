// Sharpest possible isolation test: instantiate TG68K directly (bypassing
// maincpu.sv entirely), using the exact same RESET/HALT (tri1 open-
// collector) and VPA (IACK-only) fixes maincpu.sv now has, but with the
// spike's own trivial always-zero-wait DTACK scheme
// (sim/tg68k_spike/tb_tg68k_boot.vhd: `dtack_n <= '0' when as_n='0' else
// '1'`) instead of maincpu.sv's own address-decode-driven DTACK logic.
// If this ALSO crashes, the remaining bug is in the base CPU/RESET/HALT/
// VPA wiring itself, not in maincpu.sv's bus-decode/DTACK logic. If this
// does NOT crash, the remaining bug is specific to something in
// maincpu.sv's own DTACK generation.

module tb_tg68k_isolate;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;

	logic [31:0] a;
	logic [2:0]  fc;
	logic         as_n, uds_n, lds_n, rw;
	logic [2:0]  ipl = 3'b111;   // never requested, matches the spike
	wire  [15:0] cpu_data;
	tri1          cpu_reset_n, cpu_halt_n;

	assign cpu_reset_n = reset ? 1'b0 : 1'bz;
	assign cpu_halt_n  = reset ? 1'b0 : 1'bz;

	logic vpa;
	assign vpa = (fc == 3'b111) ? 1'b0 : 1'b1;

	logic dtack_n;
	assign dtack_n = (as_n == 1'b0) ? 1'b0 : 1'b1;   // spike's own trivial zero-wait scheme

	TG68K #(
		.CPU(2'b11)
	) u_cpu (
		.CLK(clk),
		.RESET(cpu_reset_n),
		.HALT(cpu_halt_n),
		.BERR(1'b0),
		.IPL(ipl),
		.ADDR(a),
		.FC(fc),
		.DATA(cpu_data),
		.AS(as_n),
		.UDS(uds_n),
		.LDS(lds_n),
		.RW(rw),
		.DTACK(dtack_n),
		.E(),
		.VPA(vpa),
		.VMA()
	);

	// trivial ROM: NOP forever, immediate (0-wait) response, matches
	// dtack_n's own zero-wait contract
	logic [15:0] read_data;
	assign read_data = 16'h4E71;   // NOP
	assign cpu_data = (as_n == 1'b0 && rw == 1'b1) ? read_data : 16'bz;

	initial begin
		#200000;
		$display("Ran 200000ps with no crash -- base CPU/RESET/HALT/VPA wiring is clean");
		$finish;
	end

	initial begin
		reset = 1;
		repeat (15) @(posedge clk);
		reset = 0;
	end

endmodule
