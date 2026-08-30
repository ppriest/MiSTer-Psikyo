`timescale 1ns/1ps
// Functional test for rtl/sound/opl4/ (docs/phase2_ymf278b.md milestone 1)
// against the behaviors traced from MAME's ymfm reference: bus protocol
// (chip ID, NEW2 gating), timer period and IRQ, the memory window with
// autoincrement, wavetable header loading (addresses and register
// write-back), keyon -> audible output, release -> silence, and sample
// addressing/looping.
module tb_opl4;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	logic        cs, rd, wr;
	logic [2:0] addr;
	logic [7:0] din;
	logic [7:0] dout;
	logic        irq_n;
	logic        mem_rd_req, mem_rd_valid;
	logic [21:0] mem_rd_addr;
	logic [7:0] mem_rd_data;
	logic signed [15:0] snd_l, snd_r;
	// FM-usage instrumentation outputs (see opl4.sv); not checked here
	logic        dbg_fm_wr, dbg_fm_keyon, dbg_pcm_keyon;

	opl4 dut (.*);

	int errors = 0;

	// ---- behavioral wave ROM ----
	// wave 0 header at 0..11: 8-bit format, base 0x001000, loop 0x0010,
	// end 0x0020 (stored negated). Bytes 7-11 (write-back registers):
	// LFO/VIB=0, AR=15/DR=0, SL=0/SR=0, RC=15/RR=15, AM=0.
	function automatic [7:0] rom_byte(input [21:0] a);
		case (a)
			22'd0:  rom_byte = 8'h00;   // fmt=0, base[21:16]=0
			22'd1:  rom_byte = 8'h10;   // base[15:8]
			22'd2:  rom_byte = 8'h00;   // base[7:0]
			22'd3:  rom_byte = 8'h00;   // loop hi
			22'd4:  rom_byte = 8'h10;   // loop lo
			22'd5:  rom_byte = 8'hFF;   // -end hi   (-0x20 = 0xFFE0)
			22'd6:  rom_byte = 8'hE0;   // -end lo
			22'd7:  rom_byte = 8'h00;   // LFO/VIB
			22'd8:  rom_byte = 8'hF0;   // AR=15 DR=0
			22'd9:  rom_byte = 8'h00;   // SL=0 SR=0
			22'd10: rom_byte = 8'hFF;   // RC=15 RR=15
			22'd11: rom_byte = 8'h00;   // AM
			default: begin
				if (a >= 22'h001000 && a < 22'h001100) rom_byte = 8'h40; // sample data
				else rom_byte = a[7:0];   // addressing checks elsewhere
			end
		endcase
	endfunction

	// SDRAM-ish latency: valid a few cycles after req
	logic [21:0] pend_addr;
	logic [2:0] pend_cnt;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pend_cnt      <= 3'd0;
			mem_rd_valid <= 1'b0;
			mem_rd_data  <= 8'd0;
		end else begin
			mem_rd_valid <= 1'b0;
			if (mem_rd_req) begin
				pend_addr <= mem_rd_addr;
				pend_cnt  <= 3'd5;
			end else if (pend_cnt != 0) begin
				pend_cnt <= pend_cnt - 3'd1;
				if (pend_cnt == 3'd1) begin
					mem_rd_data  <= rom_byte(pend_addr);
					mem_rd_valid <= 1'b1;
				end
			end
		end
	end

	// record fetch addresses for the header/sample addressing checks
	logic [21:0] fetch_log [$];
	always_ff @(posedge clk) if (mem_rd_req) fetch_log.push_back(mem_rd_addr);

	// ---- bus helpers (Z80-paced: strobes held several clocks) ----
	task automatic bwrite(input [2:0] a, input [7:0] d);
		@(posedge clk);
		addr = a; din = d; cs = 1; wr = 1;
		repeat (6) @(posedge clk);
		wr = 0; cs = 0;
		repeat (6) @(posedge clk);
	endtask

	task automatic bread(input [2:0] a, output [7:0] d);
		@(posedge clk);
		addr = a; cs = 1; rd = 1;
		repeat (3) @(posedge clk);
		d = dout;
		repeat (3) @(posedge clk);
		rd = 0; cs = 0;
		repeat (6) @(posedge clk);
	endtask

	// FM register write: address then data
	task automatic fm_wr(input [8:0] a, input [7:0] d);
		if (a[8]) bwrite(3'd2, a[7:0]); else bwrite(3'd0, a[7:0]);
		bwrite(a[8] ? 3'd3 : 3'd1, d);
	endtask
	// PCM register write: address then data
	task automatic pcm_wr(input [7:0] a, input [7:0] d);
		bwrite(3'd4, a);
		bwrite(3'd5, d);
	endtask
	task automatic pcm_rd(input [7:0] a, output [7:0] d);
		bwrite(3'd4, a);
		bread(3'd5, d);
	endtask

	task automatic check8(input [7:0] got, input [7:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%02h expected=%02h", name, got, exp);
		end
	endtask

	// wait n output samples (~1948 clk each)
	task automatic wait_samples(input int n);
		repeat (n * 2000) @(posedge clk);
	endtask

	logic [7:0] rb;
	int t0, t1, t2;
	int found;

	initial begin
		reset = 1; cs = 0; rd = 0; wr = 0; addr = 0; din = 0;
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// ---- chip ID / NEW2 ----
		bread(3'd0, rb); check8(rb, 8'h06, "initial status ID (no NEW)");
		bread(3'd0, rb); check8(rb & 8'hE0, 8'h00, "status after ID consumed");
		fm_wr(9'h105, 8'h03);            // NEW + NEW2
		bread(3'd0, rb); check8(rb, 8'h02, "status ID after NEW2 0->1");

		// ---- timer B: value 0xFC -> 16*4 = 64 FM samples ----
		fm_wr(9'h003, 8'hFC);
		fm_wr(9'h004, 8'h02);            // load B
		// measure two IRQ falling edges
		@(negedge irq_n); t0 = $time;
		bread(3'd0, rb);
		if ((rb & 8'hA0) !== 8'hA0) begin errors++; $display("FAIL timer B status: %02h", rb); end
		fm_wr(9'h004, 8'h80);            // RST: clear flags
		if (irq_n !== 1'b1) begin errors++; $display("FAIL IRQ not cleared by RST"); end
		fm_wr(9'h004, 8'h02);            // reload B
		@(negedge irq_n); t1 = $time;
		fm_wr(9'h004, 8'h80);
		fm_wr(9'h004, 8'h02);
		@(negedge irq_n); t2 = $time;
		// expected: 64 FM samples = 64*684 chip clocks = 43776 / (8624/21875)
		// clk cycles = ~111040 clk = ~1110400 ns; allow +-5% (bus latency)
		if (t2 - t1 < 1054000 || t2 - t1 > 1167000) begin
			errors++;
			$display("FAIL timer B period: %0d ns (expected ~1110400)", t2 - t1);
		end
		fm_wr(9'h004, 8'h80);            // stop/clear

		// ---- memory window: reads with autoincrement ----
		pcm_wr(8'h02, 8'h01);            // memory access mode
		pcm_wr(8'h03, 8'h00);
		pcm_wr(8'h04, 8'h20);
		pcm_wr(8'h05, 8'h00);            // address 0x002000
		wait_samples(1);                  // let the prefetch land
		pcm_rd(8'h06, rb); check8(rb, 8'h00, "mem window byte @2000");
		wait_samples(1);
		pcm_rd(8'h06, rb); check8(rb, 8'h01, "mem window byte @2001 (autoinc)");
		pcm_wr(8'h02, 8'h00);            // back to sound-generation mode

		// ---- wavetable load: header addressing + write-back ----
		fetch_log.delete();
		pcm_wr(8'h08, 8'h00);            // ch0 selects wave 0 -> header load
		wait_samples(2);
		found = 0;
		foreach (fetch_log[i]) if (fetch_log[i] == 22'd0) found = 1;
		if (!found) begin errors++; $display("FAIL header fetch at addr 0 not seen"); end
		found = 0;
		foreach (fetch_log[i]) if (fetch_log[i] == 22'd11) found = 1;
		if (!found) begin errors++; $display("FAIL header fetch at addr 11 not seen"); end
		// write-back check: RC/RR register (0xC8+ch) took byte 10 = 0xFF
		pcm_rd(8'hC8, rb); check8(rb, 8'hFF, "header write-back RC/RR");

		// ---- channel setup: TL=0 direct, pan 0, oct 0, fnum 0 ----
		pcm_wr(8'h50, 8'h01);            // TL=0, level direct
		pcm_wr(8'h68, 8'h00);            // key off, no damp, pan 0
		pcm_wr(8'h20, 8'h00);            // fnum lo, wave hi=0
		pcm_wr(8'h38, 8'h00);            // oct 0, fnum hi 0

		// ---- key on -> audible ----
		fetch_log.delete();
		pcm_wr(8'h68, 8'h80);            // key on
		wait_samples(20);
		if (snd_l == 0 && snd_r == 0) begin
			errors++;
			$display("FAIL no output after key on (snd_l=%0d)", snd_l);
		end
		if (snd_l < 0) begin errors++; $display("FAIL polarity: 0x40 samples gave %0d", snd_l); end
		// sample fetches must come from the wave data region
		found = 0;
		foreach (fetch_log[i]) if (fetch_log[i] >= 22'h001000 && fetch_log[i] < 22'h001020) found = 1;
		if (!found) begin errors++; $display("FAIL no sample fetches in wave data region"); end

		// ---- loop wrap: step=0.5/sample, end=0x20 -> stays under 0x1020 ----
		wait_samples(100);
		foreach (fetch_log[i])
			if (fetch_log[i] >= 22'h001020 && fetch_log[i] < 22'h001100) begin
				errors++;
				$display("FAIL fetch past end position: %06h", fetch_log[i]);
				break;
			end

		// ---- key off -> silence. RR=15 is rate 63: +8 attenuation per
		// sample (the reference's max), so full silence takes ~128 samples
		pcm_wr(8'h68, 8'h00);
		wait_samples(200);
		if (snd_l != 0 || snd_r != 0) begin
			errors++;
			$display("FAIL not silent after key off (snd_l=%0d snd_r=%0d)", snd_l, snd_r);
		end

		if (errors == 0) $display("ALL TESTS PASSED");
		else $display("%0d TEST(S) FAILED", errors);
		$finish;
	end

	initial begin
		#20_000_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end

endmodule
