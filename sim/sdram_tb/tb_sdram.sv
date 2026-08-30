// Verifies rtl/memory/sdram/sdram.sv (the burst-4-read-extended controller,
// see PROVENANCE.md for what changed from Sorgelig's upstream reference)
// against a real command-decoding behavioral chip model
// (sdram_chip_model.sv), not a black-box latency stub -- so a wiring bug in
// the burst extension shows up as a real protocol violation, not just wrong
// data.
//
// Four cases:
//   1. Single burst-4 read on port0: seeds 4 sequential words via the chip
//      model's poke_word_addr backdoor (mirroring sdram.sv's own
//      bank/row/col address decomposition, not assumed), issues a read via
//      the req/ack toggle convention, checks the assembled 64-bit dout0
//      lane-by-lane against the independently-seeded values.
//   2. Single-word write on port0 with byte-lane masking (wrl0 only, then
//      wrh0 only): verifies the chip model's backing store was updated only
//      in the masked lane, the other lane left untouched -- via peek_word_addr,
//      not by reading back through the controller (keeps the write-path
//      check independent of the read-path logic under test elsewhere).
//   3. Two ports (port0 + port1) requesting simultaneously: confirms both
//      get served (priority order port0 then port1, matching the
//      controller's own idle-time priority chain) and each gets its own
//      correct, independently-seeded data -- not a stale/crossed result.
//   4. Latency sanity check: measures req-to-ack cycle count for a single
//      uncontended read and confirms it's small and FIXED (bounded), the
//      actual point of this whole DDRAM->SDRAM pivot (see
//      docs/phase1_sdram_map.md) -- not a specific magic number, just "small
//      and doesn't vary with address," so this check isn't tied to exact
//      RASCAS_DELAY/CAS_LATENCY constants that might reasonably change.
//   5. Isolated reproduction of a real bug found in rtl/psikyo_top.sv
//      integration (docs/ROADMAP.md's "Progress" -- KNOWN OPEN ISSUE):
//      back-to-back single-port reads to DIFFERENT rows, issued with zero
//      gap (the next req toggles the same cycle the previous ack toggle is
//      observed -- exactly what a round-robin arbiter serving two always-
//      pending clients naturally produces, per sim/psikyo_top_tb/
//      tb_psikyo_top.sv's own traced failure). This does NOT need the
//      arbiter or a second real client to reproduce -- a single port,
//      driven directly, is enough, isolating the bug to sdram.sv/the SDR
//      timing model itself. Runs many iterations (not just one pair),
//      since the real failure was intermittent, not on the very first
//      back-to-back pair.

module tb_sdram;

	logic clk = 0;
	always #5 clk = ~clk;

	logic init;

	wire [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic  [1:0] SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	logic         SDRAM_CLK, SDRAM_CKE;

	logic [24:1] addr0, addr1, addr2;
	logic         wrl0, wrh0, wrl1, wrh1, wrl2, wrh2;
	logic [15:0] din0, din1, din2;
	logic [63:0] dout0, dout1, dout2;
	logic         req0, req1, req2;
	logic         ack0, ack1, ack2;

	sdram dut (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(addr0), .wrl0(wrl0), .wrh0(wrh0), .din0(din0), .dout0(dout0), .req0(req0), .ack0(ack0),
		.addr1(addr1), .wrl1(wrl1), .wrh1(wrh1), .din1(din1), .dout1(dout1), .req1(req1), .ack1(ack1),
		.addr2(addr2), .wrl2(wrl2), .wrh2(wrh2), .din2(din2), .dout2(dout2), .req2(req2), .ack2(ack2)
	);

	sdram_chip_model chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	int errors = 0;

	// issue a read on the given port, holding req until ack toggles, return
	// (via ref args) the resulting dout and the number of cycles it took
	task automatic do_read(input int port, input logic [24:1] a, output logic [63:0] data, output int cycles);
		cycles = 0;
		case (port)
			0: begin
				addr0 = a; wrl0 = 0; wrh0 = 0;
				req0 = ~ack0;
				do begin @(posedge clk); cycles++; end while (ack0 !== req0);
				data = dout0;
			end
			1: begin
				addr1 = a; wrl1 = 0; wrh1 = 0;
				req1 = ~ack1;
				do begin @(posedge clk); cycles++; end while (ack1 !== req1);
				data = dout1;
			end
			default: ;
		endcase
	endtask

	task automatic do_write(input int port, input logic [24:1] a, input logic wl, input logic wh, input logic [15:0] d);
		case (port)
			0: begin
				addr0 = a; wrl0 = wl; wrh0 = wh; din0 = d;
				req0 = ~ack0;
				do @(posedge clk); while (ack0 !== req0);
			end
			default: ;
		endcase
	endtask

	initial begin
		logic [63:0] got;
		logic [15:0] before_lo, before_hi, after_lo, after_hi;
		int          cyc;
		logic [63:0] got0, got1;
		int          cyc0, cyc1;

		init  = 1'b0;
		addr0 = 0; wrl0 = 0; wrh0 = 0; din0 = 0; req0 = 0;
		addr1 = 0; wrl1 = 0; wrh1 = 0; din1 = 0; req1 = 0;
		addr2 = 0; wrl2 = 0; wrh2 = 0; din2 = 0; req2 = 0;

		// let the power-up reset/mode-register-load sequence run to
		// completion -- generous headroom over the ~31*9-cycle worst case
		// derived from `reset` counting down 31 times, one STATE_LAST per
		// 9-cycle state loop while mode != MODE_NORMAL.
		repeat (500) @(posedge clk);
		if (dut.mode !== 2'b00) begin
			errors++;
			$display("FAIL: controller did not reach MODE_NORMAL within 500 cycles of reset");
		end
		repeat (10) @(posedge clk);

		// ---- Case 1: burst-4 read assembly + address decode ----
		chip.poke_word_addr(24'h001000, 16'hAAAA);
		chip.poke_word_addr(24'h001001, 16'hBBBB);
		chip.poke_word_addr(24'h001002, 16'hCCCC);
		chip.poke_word_addr(24'h001003, 16'hDDDD);

		do_read(0, 24'h001000, got, cyc);
		if (got !== 64'hDDDD_CCCC_BBBB_AAAA) begin
			errors++;
			$display("FAIL Case1: burst-4 read got=%h expected=DDDDCCCCBBBBAAAA", got);
		end else begin
			$display("Case1 PASS: burst-4 read assembled correctly (%0d cycles)", cyc);
		end

		// ---- Case 2: byte-lane write masking ----
		chip.poke_word_addr(24'h002000, 16'h1234);
		do_write(0, 24'h002000, 1'b1, 1'b0, 16'hFF00);   // wrl only: low byte -> 0x00
		after_lo = chip.peek_word_addr(24'h002000);
		if (after_lo !== 16'h1200) begin
			errors++;
			$display("FAIL Case2a: wrl-only write got=%h expected=1200", after_lo);
		end

		chip.poke_word_addr(24'h002001, 16'h1234);
		do_write(0, 24'h002001, 1'b0, 1'b1, 16'hAB00);   // wrh only: high byte -> 0xAB
		after_hi = chip.peek_word_addr(24'h002001);
		if (after_hi !== 16'hAB34) begin
			errors++;
			$display("FAIL Case2b: wrh-only write got=%h expected=AB34", after_hi);
		end
		if (after_lo === 16'h1200 && after_hi === 16'hAB34)
			$display("Case2 PASS: byte-lane write masking correct (wrl-only and wrh-only)");

		// ---- Case 3: two ports simultaneously ----
		chip.poke_word_addr(24'h003000, 16'h1111);
		chip.poke_word_addr(24'h003001, 16'h2222);
		chip.poke_word_addr(24'h003002, 16'h3333);
		chip.poke_word_addr(24'h003003, 16'h4444);
		chip.poke_word_addr(24'h004000, 16'h5555);
		chip.poke_word_addr(24'h004001, 16'h6666);
		chip.poke_word_addr(24'h004002, 16'h7777);
		chip.poke_word_addr(24'h004003, 16'h8888);

		addr0 = 24'h003000; wrl0 = 0; wrh0 = 0;
		addr1 = 24'h004000; wrl1 = 0; wrh1 = 0;
		fork
			begin
				req0 = ~ack0;
				do @(posedge clk); while (ack0 !== req0);
				got0 = dout0;
			end
			begin
				req1 = ~ack1;
				do @(posedge clk); while (ack1 !== req1);
				got1 = dout1;
			end
		join

		if (got0 !== 64'h4444_3333_2222_1111 || got1 !== 64'h8888_7777_6666_5555) begin
			errors++;
			$display("FAIL Case3: got0=%h got1=%h expected 4444333322221111 / 8888777766665555", got0, got1);
		end else begin
			$display("Case3 PASS: two simultaneous ports both served correctly, no crossed data");
		end

		// ---- Case 4: latency sanity (small, fixed) ----
		chip.poke_word_addr(24'h005000, 16'hAAAA);
		chip.poke_word_addr(24'h005001, 16'hAAAA);
		chip.poke_word_addr(24'h005002, 16'hAAAA);
		chip.poke_word_addr(24'h005003, 16'hAAAA);
		do_read(0, 24'h005000, got, cyc0);

		chip.poke_word_addr(24'h006000, 16'hAAAA);
		chip.poke_word_addr(24'h006001, 16'hAAAA);
		chip.poke_word_addr(24'h006002, 16'hAAAA);
		chip.poke_word_addr(24'h006003, 16'hAAAA);
		do_read(0, 24'h006000, got, cyc1);

		if (cyc0 > 20 || cyc1 > 20 || cyc0 != cyc1) begin
			errors++;
			$display("FAIL Case4: latency not small/fixed -- cyc0=%0d cyc1=%0d", cyc0, cyc1);
		end else begin
			$display("Case4 PASS: uncontended read latency small and fixed (%0d cycles) -- the actual point of the SDRAM pivot, see docs/phase1_sdram_map.md", cyc0);
		end

		// ---- Case 5: back-to-back different-row reads, zero gap, single port ----
		begin
			logic [63:0] rowA_exp, rowB_exp, got5;
			int          cyc5;
			int          fail_iter;
			int          fail_count;

			rowA_exp = 64'h4444_3333_2222_1111;
			rowB_exp = 64'h8888_7777_6666_5555;
			fail_iter = -1;
			fail_count = 0;

			chip.poke_word_addr(24'h000000, 16'h1111);
			chip.poke_word_addr(24'h000001, 16'h2222);
			chip.poke_word_addr(24'h000002, 16'h3333);
			chip.poke_word_addr(24'h000003, 16'h4444);
			// row differs from 24'h000000's (bit 16 set -- see this file's
			// header, "Case 5"): word_addr[16:9] is the chip model's own
			// folded row field, matching sdram.sv's real a[22:10] row split.
			chip.poke_word_addr(24'h010000, 16'h5555);
			chip.poke_word_addr(24'h010001, 16'h6666);
			chip.poke_word_addr(24'h010002, 16'h7777);
			chip.poke_word_addr(24'h010003, 16'h8888);

			for (int i = 0; i < 200; i++) begin
				do_read(0, 24'h000000, got5, cyc5);
				if (got5 !== rowA_exp) begin
					fail_count++;
					if (fail_iter == -1) fail_iter = i;
				end
				do_read(0, 24'h010000, got5, cyc5);
				if (got5 !== rowB_exp) begin
					fail_count++;
					if (fail_iter == -1) fail_iter = i;
				end
			end

			if (fail_count > 0) begin
				errors++;
				$display("FAIL Case5: %0d/%0d back-to-back different-row reads corrupted, first at iteration %0d",
						   fail_count, 400, fail_iter);
			end else begin
				$display("Case5 PASS: 400 back-to-back different-row reads, all correct");
			end
		end

		// ---- Case 6: two REAL independent ports (0 and 1), both
		// continuously re-requesting different-row content, each checking
		// its OWN data every iteration -- Case 5 used one port re-issuing
		// quickly, which passed; this is the closer match to
		// sim/psikyo_top_tb/tb_psikyo_top.sv's actual failing topology
		// (two genuinely independent requestors on the shared controller,
		// sdram.sv's own STATE_IDLE priority chain arbitrating between them
		// every cycle, not one port serialized by a single task call) --
		// sim/sdram_arbiter5_tb/tb_sdram_arbiter5.sv's own Case 2 already
		// checks simultaneous multi-client correctness, but only for a
		// handful of requests, not a sustained hundreds-of-iterations loop.
		begin
			logic [63:0] pA_exp, pB_exp;
			int          failA, failB, first_fail;

			pA_exp = 64'h4444_3333_2222_1111;
			pB_exp = 64'h8888_7777_6666_5555;
			failA = 0; failB = 0; first_fail = -1;

			chip.poke_word_addr(24'h020000, 16'h1111);
			chip.poke_word_addr(24'h020001, 16'h2222);
			chip.poke_word_addr(24'h020002, 16'h3333);
			chip.poke_word_addr(24'h020003, 16'h4444);
			chip.poke_word_addr(24'h030000, 16'h5555);
			chip.poke_word_addr(24'h030001, 16'h6666);
			chip.poke_word_addr(24'h030002, 16'h7777);
			chip.poke_word_addr(24'h030003, 16'h8888);

			addr0 = 24'h020000; wrl0 = 0; wrh0 = 0;
			addr1 = 24'h030000; wrl1 = 0; wrh1 = 0;

			for (int i = 0; i < 1000; i++) begin
				logic [63:0] got0, got1;
				req0 = ~ack0;
				req1 = ~ack1;
				// Capture each port's dout INSIDE its own branch, the
				// instant ITS OWN ack toggles -- dout0/dout1/dout2 are all
				// the same shared `dout` register (`assign dout0 = dout;`
				// etc, sdram.sv itself), not independently latched per
				// port, so a caller MUST sample on its own valid/ack cycle,
				// never later (a subsequent port's transaction overwrites
				// the shared register). Case 6's first version read dout0/
				// dout1 only after BOTH forked branches (i.e. both ports)
				// had finished -- a real testbench bug, not an RTL one: by
				// then port1's transaction had already overwritten the
				// shared dout, so dout0 was showing port1's data. Real
				// consumers (sdram_phy.sv's rdata, sdram_narrow_bridge.sv's
				// data) already follow this same-cycle-capture contract
				// correctly; this was this test's own mistake.
				fork
					begin
						do @(posedge clk); while (ack0 !== req0);
						got0 = dout0;
					end
					begin
						do @(posedge clk); while (ack1 !== req1);
						got1 = dout1;
					end
				join
				if (got0 !== pA_exp) begin
					failA++;
					if (first_fail == -1) begin
						first_fail = i;
						$display("DIAG Case6 iter=%0d got0=%h expected=%h got1=%h expected=%h", i, got0, pA_exp, got1, pB_exp);
					end
				end
				if (got1 !== pB_exp) begin
					failB++;
					if (first_fail == -1) first_fail = i;
				end
			end

			if (failA > 0 || failB > 0) begin
				errors++;
				$display("FAIL Case6: port0 wrong %0d/1000, port1 wrong %0d/1000, first at iteration %0d",
						   failA, failB, first_fail);
			end else begin
				$display("Case6 PASS: 1000 iterations, two independent ports continuously contending, all correct");
			end
		end

		if (errors == 0)
			$display("PASS: tb_sdram -- burst-4 read, byte-lane write, multi-port, latency, and back-to-back different-row reads all correct");
		else
			$display("FAIL: %0d error(s)", errors);

		$finish;
	end

endmodule
