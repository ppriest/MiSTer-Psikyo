// Unit test for adpcma_sample_cache's CLIENT PROTOCOL, against the real
// sdram_phy + sdram + chip model underneath (same "real transport, not a
// stub" posture as every other sdram_*_tb here).
//
// WHY THIS EXISTS
// ---------------
// adpcma_sample_cache replaced sdram_narrow_bridge on arbiter client c4.
// On SH201B/KA302C boards that client is jt10's ADPCM-A fetch, which HOLDS
// req until valid. On SH403/SH404 boards it is the OPL4 wave reader, and
// opl4.sv:181-208 does the opposite -- it clears mem_rd_req unconditionally
// on every clock and raises it for exactly ONE cycle:
//
//     mem_rd_req <= 1'b0;
//     if (!busy_mem) begin
//         if (pcm_mem_req) begin busy_mem <= 1'b1; mem_rd_req <= 1'b1; ... end
//
// A memory side that samples req only in one FSM state will therefore drop
// an OPL4 request outright, and because busy_mem never clears without a
// valid, the wave engine stops for good. sdram_narrow_bridge got away with
// it: on a miss it returned to B_IDLE the cycle after g_valid, so its
// non-listening window was shorter than the client's turnaround. The cache
// added S_PF -- a whole SDRAM round trip spent prefetching the next granule
// after any access to byte 7 -- and a pulse arriving in that window is lost.
//
// Case 1 drives the cache with an exact behavioural copy of opl4.sv's
// arbiter, walking sequential bytes across granule boundaries so that byte 7
// (and therefore the prefetch) is hit repeatedly. Case 2 drives a second
// instance with the held-req pattern from psikyo_top's jt10 glue, so that a
// fix for Case 1 cannot silently break the path this module was written for.

module tb_adpcma_sample_cache;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;

	// All port signals declared before mem_ctrl references them -- this
	// toolchain does not resolve a `logic` first used structurally above its
	// declaration (see tb_sdram_narrow_bridge's note).
	logic [24:1] p_addr;
	logic         p_wrl, p_wrh;
	logic [15:0] p_din;
	logic [63:0] p_dout;
	logic         p_req, p_ack;

	logic [24:1] c1p_addr;
	logic         c1p_wrl, c1p_wrh;
	logic [15:0] c1p_din;
	logic [63:0] c1p_dout;
	logic         c1p_req, c1p_ack;

	logic [24:1] c2p_addr;
	logic         c2p_wrl, c2p_wrh;
	logic [15:0] c2p_din;
	logic [63:0] c2p_dout;
	logic         c2p_req, c2p_ack;

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
		.addr1(c1p_addr), .wrl1(c1p_wrl), .wrh1(c1p_wrh), .din1(c1p_din), .dout1(c1p_dout), .req1(c1p_req), .ack1(c1p_ack),
		.addr2(c2p_addr), .wrl2(c2p_wrl), .wrh2(c2p_wrh), .din2(c2p_din), .dout2(c2p_dout), .req2(c2p_req), .ack2(c2p_ack)
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

	// ================= Case 1: pulsed client (the OPL4) =================
	logic         c1_req, c1_valid;
	logic [24:0] c1_addr;
	logic [7:0]  c1_data;
	logic         c1_g_req, c1_g_valid;
	logic [24:0] c1_g_addr;
	logic [63:0] c1_g_data;

	adpcma_sample_cache #(.ENTRIES(16)) cache_pulsed (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(c1_req), .addr(c1_addr), .valid(c1_valid), .data(c1_data),
		.g_req(c1_g_req), .g_addr(c1_g_addr), .g_valid(c1_g_valid), .g_data(c1_g_data)
	);

	sdram_phy c1_phy (
		.clk(clk), .reset(reset),
		.port_addr(c1p_addr), .port_wrl(c1p_wrl), .port_wrh(c1p_wrh),
		.port_din(c1p_din), .port_dout(c1p_dout), .port_req(c1p_req), .port_ack(c1p_ack),
		.req(c1_g_req), .we(1'b0), .we16(1'b0), .addr(c1_g_addr), .wdata(16'd0),
		.busy(), .valid(c1_g_valid), .rdata(c1_g_data)
	);

	// Behavioural copy of opl4.sv:181-208. Do not "improve" it -- the point
	// of this model is that it matches the real client exactly, including
	// the unconditional `c1_req <= 1'b0` that makes req a one-cycle pulse.
	logic        pc_busy;
	logic        pc_want;
	logic [24:0] pc_want_addr;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pc_busy <= 1'b0;
			c1_req  <= 1'b0;
			c1_addr <= 25'd0;
		end else begin
			c1_req <= 1'b0;
			if (!pc_busy) begin
				if (pc_want) begin
					pc_busy <= 1'b1;
					c1_req  <= 1'b1;
					c1_addr <= pc_want_addr;
				end
			end else if (c1_valid) begin
				pc_busy <= 1'b0;
			end
		end
	end

	// ================= Case 2: held client (jt10's ADPCM-A) =================
	logic         c2_req, c2_valid;
	logic [24:0] c2_addr;
	logic [7:0]  c2_data;
	logic         c2_g_req, c2_g_valid;
	logic [24:0] c2_g_addr;
	logic [63:0] c2_g_data;

	adpcma_sample_cache #(.ENTRIES(16)) cache_held (
		.clk(clk), .reset(reset), .inval(1'b0),
		.req(c2_req), .addr(c2_addr), .valid(c2_valid), .data(c2_data),
		.g_req(c2_g_req), .g_addr(c2_g_addr), .g_valid(c2_g_valid), .g_data(c2_g_data)
	);

	sdram_phy c2_phy (
		.clk(clk), .reset(reset),
		.port_addr(c2p_addr), .port_wrl(c2p_wrl), .port_wrh(c2p_wrh),
		.port_din(c2p_din), .port_dout(c2p_dout), .port_req(c2p_req), .port_ack(c2p_ack),
		.req(c2_g_req), .we(1'b0), .we16(1'b0), .addr(c2_g_addr), .wdata(16'd0),
		.busy(), .valid(c2_g_valid), .rdata(c2_g_data)
	);

	// psikyo_top's jt10 glue: raise req on the start pulse, hold it until
	// valid, latch the byte.
	logic        hc_start;
	logic [24:0] hc_addr;
	logic [7:0]  hc_data_r;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			c2_req <= 1'b0;
			c2_addr <= 25'd0;
		end else begin
			if (hc_start) begin
				c2_req  <= 1'b1;
				c2_addr <= hc_addr;
			end else if (c2_valid) begin
				c2_req    <= 1'b0;
				hc_data_r <= c2_data;
			end
		end
	end

	// ================= stimulus =================
	int errors = 0;

	localparam int BASE  = 25'h0_0100;   // granule-aligned test region base
	localparam int NREAD = 24;            // 3 whole granules -- hits byte 7 x3

	// position-identifying seed: every byte in the region is distinct
	function automatic logic [7:0] seed_of(input int a);
		seed_of = 8'((a * 7) + 8'h5A);
	endfunction

	task automatic write_phy_write(int byte_addr, logic [7:0] data);
		@(posedge clk); w_req = 1; w_we = 1; w_addr = byte_addr; w_wdata = data;
		@(posedge clk);
		while (w_busy) @(posedge clk);
		w_req = 0; w_we = 0;
		@(posedge clk);
	endtask

	// Read one byte through the PULSED client, with a timeout. Returns 0 on
	// timeout so the caller can report exactly which access wedged.
	task automatic pulsed_read(input int byte_addr, output logic [7:0] d, output bit ok);
		int guard;
		ok = 1'b1;
		@(posedge clk);
		pc_want      = 1'b1;
		pc_want_addr = byte_addr;
		guard = 0;
		while (!c1_valid) begin
			@(posedge clk);
			guard++;
			if (guard > 2000) begin
				ok = 1'b0;
				break;
			end
		end
		d = c1_data;
		pc_want = 1'b0;
		@(posedge clk);
	endtask

	task automatic held_read(input int byte_addr, output logic [7:0] d, output bit ok);
		int guard;
		ok = 1'b1;
		@(posedge clk);
		hc_addr  = byte_addr;
		hc_start = 1'b1;
		@(posedge clk);
		hc_start = 1'b0;
		guard = 0;
		while (!c2_valid) begin
			@(posedge clk);
			guard++;
			if (guard > 2000) begin
				ok = 1'b0;
				break;
			end
		end
		d = c2_data;
		@(posedge clk);
	endtask

	logic [7:0] got;
	bit          ok;

	initial begin
		reset    = 1;
		w_req    = 0; w_we = 0; w_addr = 0; w_wdata = 0;
		pc_want  = 0; pc_want_addr = 0;
		hc_start = 0; hc_addr = 0;
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// seed the region through the controller's own write path
		for (int i = 0; i < NREAD; i++)
			write_phy_write(BASE + i, seed_of(BASE + i));

		// ---- Case 1: the OPL4's one-cycle req pulse ----
		for (int i = 0; i < NREAD; i++) begin
			pulsed_read(BASE + i, got, ok);
			if (!ok) begin
				$display("FAIL: pulsed client wedged at byte offset %0d (addr %h) -- req pulse dropped, no valid ever returned",
						 i, BASE + i);
				errors++;
				break;
			end
			if (got !== seed_of(BASE + i)) begin
				$display("FAIL: pulsed read offset %0d (addr %h) got %h expected %h",
						 i, BASE + i, got, seed_of(BASE + i));
				errors++;
			end
		end
		if (errors == 0) $display("Case 1 done (pulsed/OPL4-style client, %0d sequential bytes across 3 granules)", NREAD);

		// ---- Case 2: jt10's held req (must not regress) ----
		begin
			int c2errors = 0;
			for (int i = 0; i < NREAD; i++) begin
				held_read(BASE + i, got, ok);
				if (!ok) begin
					$display("FAIL: held client wedged at byte offset %0d (addr %h)", i, BASE + i);
					errors++; c2errors++;
					break;
				end
				if (got !== seed_of(BASE + i)) begin
					$display("FAIL: held read offset %0d (addr %h) got %h expected %h",
							 i, BASE + i, got, seed_of(BASE + i));
					errors++; c2errors++;
				end
			end
			if (c2errors == 0) $display("Case 2 done (held-req/jt10-style client, %0d sequential bytes)", NREAD);
		end

		if (errors == 0)
			$display("PASS: adpcma_sample_cache serves both a pulsed (OPL4) and a held (jt10) client across granule boundaries, against real SDRAM transport");
		else
			$display("FAIL: %0d error(s)", errors);

		$finish;
	end

endmodule
