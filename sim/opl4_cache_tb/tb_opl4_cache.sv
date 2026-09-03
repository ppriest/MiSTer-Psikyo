`timescale 1ns/1ps
// Integration test: the REAL opl4 against the REAL adpcma_sample_cache over
// the REAL sdram_phy + sdram + chip model -- the exact chain psikyo_top
// builds on SH403/SH404 boards, where `board_sh404 ? opl4_mem_addr : ...`
// muxes the OPL4 wave reader onto arbiter client c4.
//
// WHY THIS EXISTS SEPARATELY FROM sim/opl4_tb
// -------------------------------------------
// sim/opl4_tb could not have caught the fault this test exists for. Its wave
// ROM is a behavioural model that accepts a request in ANY state (a 5-cycle
// counter armed by mem_rd_req) and therefore always answers. The real memory
// side does not: adpcma_sample_cache sampled req only in S_IDLE, and the
// OPL4 pulses mem_rd_req for exactly one cycle (opl4.sv:181-208 clears it
// unconditionally every clock). An infinitely-accepting stub hides that
// mismatch completely, which is how a total loss of sound on Strikers 1945
// and Tengai got past a passing unit test.
//
// So this test asserts the one thing that matters to the games: with the
// production memory chain underneath, does a wavetable header load actually
// COMPLETE, and does the sample stream keep flowing afterwards.

module tb_opl4_cache;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	// ---- SDRAM transport (all port signals declared before mem_ctrl) ----
	logic [24:1] p_addr;
	logic         p_wrl, p_wrh;
	logic [15:0] p_din;
	logic [63:0] p_dout;
	logic         p_req, p_ack;

	logic [24:1] c_addr_p;
	logic         c_wrl, c_wrh;
	logic [15:0] c_din;
	logic [63:0] c_dout;
	logic         c_req_p, c_ack;

	logic [24:1] u_addr;
	logic         u_wrl, u_wrh;
	logic [15:0] u_din;
	logic [63:0] u_dout;
	logic         u_req, u_ack;

	wire [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic  [1:0] SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	logic         SDRAM_CLK, SDRAM_CKE;

	sdram mem_ctrl (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(1'b0), .clk(clk),
		.addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
		.addr1(c_addr_p), .wrl1(c_wrl), .wrh1(c_wrh), .din1(c_din), .dout1(c_dout), .req1(c_req_p), .ack1(c_ack),
		.addr2(u_addr), .wrl2(u_wrl), .wrh2(u_wrh), .din2(u_din), .dout2(u_dout), .req2(u_req), .ack2(u_ack)
	);

	sdram_chip_model chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// port2 unused
	assign u_addr = 24'd0; assign u_wrl = 1'b0; assign u_wrh = 1'b0;
	assign u_din = 16'd0;  assign u_req = 1'b0;

	// ---- setup write path ----
	logic         w_req, w_we, w_busy, w_valid;
	logic [24:0] w_addr;
	logic [7:0]  w_wdata;
	logic [63:0] w_rdata;

	sdram_phy write_phy (
		.clk(clk), .reset(reset),
		.port_addr(p_addr), .port_wrl(p_wrl), .port_wrh(p_wrh),
		.port_din(p_din), .port_dout(p_dout), .port_req(p_req), .port_ack(p_ack),
		.req(w_req), .we(w_we), .we16(1'b0), .addr(w_addr), .wdata(w_wdata),
		.busy(w_busy), .valid(w_valid), .rdata(w_rdata)
	);

	// ---- the chain under test: opl4 -> adpcma_sample_cache -> sdram ----
	logic        cs, rd, wr;
	logic [2:0] addr;
	logic [7:0] din;
	logic [7:0] dout;
	logic        irq_n;
	logic        mem_rd_req, mem_rd_valid;
	logic [21:0] mem_rd_addr;
	logic [7:0] mem_rd_data;
	logic signed [15:0] snd_l, snd_r;
	logic        dbg_fm_wr, dbg_fm_keyon, dbg_pcm_keyon;

	opl4 u_opl4 (
		.clk(clk), .reset(reset),
		.cs(cs), .rd(rd), .wr(wr), .addr(addr), .din(din), .dout(dout),
		.irq_n(irq_n),
		.mem_rd_req(mem_rd_req), .mem_rd_addr(mem_rd_addr),
		.mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data),
		.snd_l(snd_l), .snd_r(snd_r),
		.dbg_fm_wr(dbg_fm_wr), .dbg_fm_keyon(dbg_fm_keyon),
		.dbg_pcm_keyon(dbg_pcm_keyon)
	);

	logic         c_g_req, c_g_valid;
	logic [24:0] c_g_addr;
	logic [63:0] c_g_data;

	// psikyo_top wires this with ADPCMA_BASE added; base 0 here so wave ROM
	// addresses and SDRAM byte addresses are the same number.
	adpcma_sample_cache #(.ENTRIES(16)) u_cache (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(mem_rd_req), .addr({3'd0, mem_rd_addr}),
		.valid(mem_rd_valid), .data(mem_rd_data),
		.g_req(c_g_req), .g_addr(c_g_addr), .g_valid(c_g_valid), .g_data(c_g_data)
	);

	sdram_phy cache_phy (
		.clk(clk), .reset(reset),
		.port_addr(c_addr_p), .port_wrl(c_wrl), .port_wrh(c_wrh),
		.port_din(c_din), .port_dout(c_dout), .port_req(c_req_p), .port_ack(c_ack),
		.req(c_g_req), .we(1'b0), .we16(1'b0), .addr(c_g_addr), .wdata(16'd0),
		.busy(), .valid(c_g_valid), .rdata(c_g_data)
	);

	// count completed wave-ROM reads -- a stalled engine freezes this
	int reads_done = 0;
	always_ff @(posedge clk) if (mem_rd_valid) reads_done++;

	int errors = 0;

	// ---- wave ROM contents: same wave 0 as sim/opl4_tb ----
	// 8-bit format, base 0x001000, loop 0x0010, end 0x0020 (stored negated),
	// then the five header write-back registers.
	function automatic [7:0] rom_byte(input [21:0] a);
		case (a)
			22'd0:  rom_byte = 8'h00;
			22'd1:  rom_byte = 8'h10;
			22'd2:  rom_byte = 8'h00;
			22'd3:  rom_byte = 8'h00;
			22'd4:  rom_byte = 8'h10;
			22'd5:  rom_byte = 8'hFF;
			22'd6:  rom_byte = 8'hE0;
			22'd7:  rom_byte = 8'h00;   // LFO/VIB
			22'd8:  rom_byte = 8'hF0;   // AR=15 DR=0
			22'd9:  rom_byte = 8'h00;   // SL=0 SR=0
			22'd10: rom_byte = 8'hFF;   // RC=15 RR=15
			22'd11: rom_byte = 8'h00;   // AM
			default: rom_byte = 8'h40;  // sample data
		endcase
	endfunction

	task automatic seed(int byte_addr, logic [7:0] data);
		@(posedge clk); w_req = 1; w_we = 1; w_addr = byte_addr; w_wdata = data;
		@(posedge clk);
		while (w_busy) @(posedge clk);
		w_req = 0; w_we = 0;
		@(posedge clk);
	endtask

	// ---- Z80-paced bus helpers (identical pacing to sim/opl4_tb) ----
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

	task automatic fm_wr(input [8:0] a, input [7:0] d);
		if (a[8]) bwrite(3'd2, a[7:0]); else bwrite(3'd0, a[7:0]);
		bwrite(a[8] ? 3'd3 : 3'd1, d);
	endtask
	task automatic pcm_wr(input [7:0] a, input [7:0] d);
		bwrite(3'd4, a);
		bwrite(3'd5, d);
	endtask
	task automatic pcm_rd(input [7:0] a, output [7:0] d);
		bwrite(3'd4, a);
		bread(3'd5, d);
	endtask

	logic [7:0] rb;
	int reads_at_keyon;

	initial begin
		reset = 1;
		cs = 0; rd = 0; wr = 0; addr = 0; din = 0;
		w_req = 0; w_we = 0; w_addr = 0; w_wdata = 0;
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// header (0..11) plus one granule of sample data at 0x1000
		for (int i = 0; i < 12; i++)     seed(i, rom_byte(i[21:0]));
		for (int i = 0; i < 32; i++)     seed(22'h001000 + i, 8'h40);

		// ---- bring the chip up exactly as the games do ----
		fm_wr(9'h105, 8'h03);            // NEW + NEW2

		// ---- wavetable header load: ch0 selects wave 0 ----
		// This is the moment of truth. The header is 12 CONSECUTIVE bytes,
		// so it crosses byte 7 of granule 0 and therefore triggers the
		// cache's next-granule prefetch mid-load.
		pcm_wr(8'h08, 8'h00);
		repeat (4000) @(posedge clk);

		if (reads_done < 12) begin
			$display("FAIL: wave header load stalled after %0d of 12 byte reads", reads_done);
			$display("      the OPL4 pulses mem_rd_req for one cycle; the memory side dropped it");
			errors++;
		end else begin
			$display("Case 1 done (wave header load completed, %0d byte reads)", reads_done);
		end

		// header write-back registers prove the load actually landed
		pcm_rd(8'hC8, rb);
		if (rb !== 8'hFF) begin
			$display("FAIL: header write-back RC/RR = %02h, expected FF (header never loaded)", rb);
			errors++;
		end else begin
			$display("Case 2 done (header write-back registers populated)");
		end

		// ---- key on and confirm the sample stream keeps flowing ----
		pcm_wr(8'h50, 8'h01);            // TL=0, level direct
		pcm_wr(8'h68, 8'h00);            // key off, pan 0
		pcm_wr(8'h20, 8'h00);
		pcm_wr(8'h38, 8'h00);
		pcm_wr(8'h68, 8'h80);            // key on

		reads_at_keyon = reads_done;
		repeat (20000) @(posedge clk);

		if (reads_done <= reads_at_keyon) begin
			$display("FAIL: no wave-ROM reads at all in 20000 cycles after key-on (engine wedged)");
			errors++;
		end else begin
			$display("Case 3 done (sample stream running, %0d reads after key-on)",
					 reads_done - reads_at_keyon);
		end

		if (errors == 0)
			$display("PASS: real opl4 loads a wavetable header and streams samples through adpcma_sample_cache over real SDRAM");
		else
			$display("FAIL: %0d error(s)", errors);

		$finish;
	end

endmodule
