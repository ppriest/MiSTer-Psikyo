// Unit test for sdram_narrow_bridge: real sdram_phy + sdram + chip model
// underneath (same "real transport, not a stub" posture as every other
// sdram_*_tb in this project), checking the word/byte extraction logic the
// module's header derives from sdram.sv's own read-capture order and
// sdram_chip_model.sv's write-mask decode -- not just trusting that
// derivation, verifying it: seed one distinct, position-identifying byte
// value at EVERY byte offset (0-7) of a single 8-byte granule via the real
// controller's own write path, then read every byte back through a
// WORD_BYTES=1 bridge instance and every word back through a WORD_BYTES=2
// instance, confirming each lands at the address the client asked for, not
// some other position in the granule (a swapped-lane bug would show up as
// two positions reading each other's value, not as a crash).

module tb_sdram_narrow_bridge;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;

	// ---- physical transport: port0 for direct test-setup writes, port1 for
	// the byte-wide bridge under test, port2 for the word-wide bridge under
	// test -- all three are real ports of the SAME sdram controller
	// instance below. All three ports' signals are declared up front, before
	// mem_ctrl's instantiation references them -- this toolchain (vlog
	// -sv) does not resolve a `logic` declared textually AFTER its first
	// structural use the way plain-scope SV normally allows (same family of
	// forward-reference issue already hit elsewhere in this project, e.g.
	// rtl/memory/sdram/sdram.sv's mode/reset reordering).
	logic [24:1] p_addr;
	logic         p_wrl, p_wrh;
	logic [15:0] p_din;
	logic [63:0] p_dout;
	logic         p_req, p_ack;

	logic [24:1] b1p_addr;
	logic         b1p_wrl, b1p_wrh;
	logic [15:0] b1p_din;
	logic [63:0] b1p_dout;
	logic         b1p_req, b1p_ack;

	logic [24:1] b2p_addr;
	logic         b2p_wrl, b2p_wrh;
	logic [15:0] b2p_din;
	logic [63:0] b2p_dout;
	logic         b2p_req, b2p_ack;

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
		.addr1(b1p_addr), .wrl1(b1p_wrl), .wrh1(b1p_wrh), .din1(b1p_din), .dout1(b1p_dout), .req1(b1p_req), .ack1(b1p_ack),
		.addr2(b2p_addr), .wrl2(b2p_wrl), .wrh2(b2p_wrh), .din2(b2p_din), .dout2(b2p_dout), .req2(b2p_req), .ack2(b2p_ack)
	);

	sdram_chip_model chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- phy for direct writes (test setup only) ----
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

	// ---- byte-wide bridge under test (WORD_BYTES=1), own dedicated
	// physical port (port1 of the shared sdram controller) ----
	logic         b1_req, b1_valid;
	logic [24:0] b1_addr;
	logic [7:0]  b1_data;
	logic         b1_g_req, b1_g_valid;
	logic [24:0] b1_g_addr;
	logic [63:0] b1_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(1)) bridge_byte (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(b1_req), .addr(b1_addr), .valid(b1_valid), .data(b1_data),
		.g_req(b1_g_req), .g_addr(b1_g_addr), .g_valid(b1_g_valid), .g_data(b1_g_data)
	);

	sdram_phy byte_phy (
		.clk(clk), .reset(reset),
		.port_addr(b1p_addr), .port_wrl(b1p_wrl), .port_wrh(b1p_wrh),
		.port_din(b1p_din), .port_dout(b1p_dout), .port_req(b1p_req), .port_ack(b1p_ack),
		.req(b1_g_req), .we(1'b0), .we16(1'b0), .addr(b1_g_addr), .wdata(16'd0),
		.busy(), .valid(b1_g_valid), .rdata(b1_g_data)
	);

	// ---- word-wide bridge under test (WORD_BYTES=2), own dedicated
	// physical port (port2 of the shared sdram controller) ----
	logic         b2_req, b2_valid;
	logic [24:0] b2_addr;
	logic [15:0] b2_data;
	logic         b2_g_req, b2_g_valid;
	logic [24:0] b2_g_addr;
	logic [63:0] b2_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(2)) bridge_word (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(b2_req), .addr(b2_addr), .valid(b2_valid), .data(b2_data),
		.g_req(b2_g_req), .g_addr(b2_g_addr), .g_valid(b2_g_valid), .g_data(b2_g_data)
	);

	sdram_phy word_phy (
		.clk(clk), .reset(reset),
		.port_addr(b2p_addr), .port_wrl(b2p_wrl), .port_wrh(b2p_wrh),
		.port_din(b2p_din), .port_dout(b2p_dout), .port_req(b2p_req), .port_ack(b2p_ack),
		.req(b2_g_req), .we(1'b0), .we16(1'b0), .addr(b2_g_addr), .wdata(16'd0),
		.busy(), .valid(b2_g_valid), .rdata(b2_g_data)
	);

	// NOTE: bridge_byte and bridge_word each get their OWN sdram_phy
	// instance (port1/port2 of the shared controller) so they can be
	// exercised independently without needing an arbiter in this unit test
	// -- sdram_arbiter5 (tested separately in sim/sdram_arbiter5_tb/) is
	// what would normally sit in front of a bridge in the real Port 2
	// consumer group.

	int errors = 0;

	task automatic write_phy_write(int byte_addr, logic [7:0] data);
		@(posedge clk); w_req = 1; w_we = 1; w_addr = byte_addr; w_wdata = data;
		@(posedge clk);
		while (w_busy) @(posedge clk);
		w_req = 0; w_we = 0;
		@(posedge clk);
	endtask

	initial begin
		#3000000;
		$display("TIMEOUT: simulation did not finish in time");
		$finish;
	end

	initial begin
		reset = 1;
		w_req = 0; w_we = 0;
		b1_req = 0; b2_req = 0;
		repeat (15) @(posedge clk);
		reset = 0;
		repeat (500) @(posedge clk);

		// Seed granule at byte address 0 with 8 distinct, position-
		// identifying values: byte i = 8'hA0+i.
		for (int i = 0; i < 8; i++)
			write_phy_write(i, 8'hA0 + i[7:0]);

		// ---- byte-wide bridge: every one of the 8 byte offsets must read
		// back its own distinct value, confirming word_sel (addr[2:1]) and
		// byte_sel (addr[0]) both select the right position ----
		for (int i = 0; i < 8; i++) begin
			@(posedge clk); b1_req = 1; b1_addr = 25'(i);
			do @(posedge clk); while (!b1_valid);
			b1_req = 0;
			if (b1_data !== 8'hA0 + i[7:0]) begin
				errors++;
				$display("FAIL(byte bridge) addr=%0d got=%h expected=%h", i, b1_data, 8'hA0+i[7:0]);
			end
			@(posedge clk);
		end
		$display("Case 1 done (byte-wide bridge, all 8 offsets correct)");

		// ---- word-wide bridge: every one of the 4 word offsets (byte
		// addresses 0,2,4,6) must read back {high_byte,low_byte} in the
		// right order -- word at byte addr 2*k should be
		// {0xA0+2k+1, 0xA0+2k} (little-endian: low byte = even address) ----
		for (int k = 0; k < 4; k++) begin
			// Explicit 8-bit intermediates before concatenation -- {}'s
			// operands are self-determined width, so `8'hA0 + (2*k+1)`
			// (int, 32-bit) would silently widen to 32 bits and get
			// truncated wrong when packed into a 16-bit `expected` (caught
			// by this test's own first run: got=a1a0, a genuinely correct
			// bridge result, against a wrongly-computed expected=00a0).
			automatic logic [7:0] hi = 8'hA0 + (2*k+1);
			automatic logic [7:0] lo = 8'hA0 + (2*k);
			automatic logic [15:0] expected = {hi, lo};
			@(posedge clk); b2_req = 1; b2_addr = 25'(2*k);
			do @(posedge clk); while (!b2_valid);
			b2_req = 0;
			if (b2_data !== expected) begin
				errors++;
				$display("FAIL(word bridge) addr=%0d got=%h expected=%h", 2*k, b2_data, expected);
			end
			@(posedge clk);
		end
		$display("Case 2 done (word-wide bridge, all 4 offsets correct)");

		// ---- Case 3: second granule (byte address 64-71), confirms
		// g_addr's 8-byte-align math (addr[24:3],3'b000) works for a
		// non-zero granule base, not just address 0 ----
		for (int i = 0; i < 8; i++)
			write_phy_write(64 + i, 8'hB0 + i[7:0]);

		for (int i = 0; i < 8; i++) begin
			@(posedge clk); b1_req = 1; b1_addr = 25'(64 + i);
			do @(posedge clk); while (!b1_valid);
			b1_req = 0;
			if (b1_data !== 8'hB0 + i[7:0]) begin
				errors++;
				$display("FAIL(case3) addr=%0d got=%h expected=%h", 64+i, b1_data, 8'hB0+i[7:0]);
			end
			@(posedge clk);
		end
		$display("Case 3 done (non-zero granule base address)");

		if (errors == 0)
			$display("PASS: sdram_narrow_bridge correctly extracts every byte/word position for both WORD_BYTES configs, against real SDRAM transport");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
