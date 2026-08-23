//
// sdram.sv
//
// SDR SDRAM controller, adapted from Sorgelig's sdram.v (Copyright (c)
// 2018 Sorgelig, GPL-3.0-or-later) -- see PROVENANCE.md in this directory
// for exactly what was changed from upstream (sdram_upstream_reference.sv)
// and why: burst-of-4 read support, so a 64-bit gfx-ROM granule (this
// project's tile-row unit) comes back as one transaction instead of four.
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

module sdram
(
	// interface to the MT48LC16M16 chip
	inout       [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus -- driven via
	                                // dq_oe/dq_out below (plain `inout reg`, as
	                                // upstream declares it, isn't accepted the same
	                                // way under vlog -sv; behavior is unchanged)
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,        // init signal after FPGA config to initialize RAM
	input             clk,         // sdram is accessed at up to 128MHz

	// port 0 -- addr is the WORD address of the first of 4 sequential words
	// making up one 64-bit read granule (low 2 bits of the word address
	// should be 00 for reads -- see docs/phase1_sdram_map.md). Writes are
	// still single-word (wrl0/wrh0 select byte lanes of din0), unaffected
	// by the burst-4 read extension.
	input      [24:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [63:0] dout0,
	input             req0,
	output reg        ack0 = 1'b0,   // see PROVENANCE.md -- simulation-fidelity fix,
	                                  // matches ack1/ack2 and `state` below

	input      [24:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [63:0] dout1,
	input             req1,
	output reg        ack1 = 1'b0,

	input      [24:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [63:0] dout2,
	input             req2,
	output reg        ack2 = 1'b0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@85MHz
localparam BURST_LENGTH   = 3'd2; // 0=1, 1=2, 2=4, 3=8, 7=full page -- 4, for one 64-bit granule
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved -- sequential: burst returns
                                   // words in ascending address order, matching gfx ROM layout
localparam CAS_LATENCY    = 3'd2; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write --
                                   // writes stay single-word; only the HPS byte-at-a-time
                                   // download path writes, no burst needed there

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

// STATE_LAST now covers 4 read-capture cycles (STATE_READ0..STATE_READ3)
// after CAS latency elapses, not just 1 -- see PROVENANCE.md.
localparam STATE_IDLE   = 4'd0;                // state to check the requests
localparam STATE_START  = STATE_IDLE+4'd1;     // state in which a new command is started
localparam STATE_CONT   = STATE_START+RASCAS_DELAY;
localparam STATE_READ0  = STATE_CONT+CAS_LATENCY+4'd1;   // +1: matches upstream's own
                                                          // STATE_READY=STATE_CONT+CAS_LATENCY+1
                                                          // margin, unchanged from upstream --
                                                          // see PROVENANCE.md
localparam STATE_READ1  = STATE_READ0+4'd1;
localparam STATE_READ2  = STATE_READ0+4'd2;
localparam STATE_READ3  = STATE_READ0+4'd3;
localparam STATE_LAST   = STATE_READ3;         // last state in cycle

reg  [3:0] state = 4'd0;   // upstream relies on Quartus's zero-power-up default for
                            // FPGA registers (real hardware); explicit here since plain
                            // ModelSim simulation leaves an uninitialized reg X instead,
                            // which would otherwise wedge the whole state machine (state==X
                            // never equals STATE_LAST, so `reset`/`mode` never advance)
reg [22:1] a;
reg [15:0] data;
reg        we;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg        active = 0;
reg  [2:0] ram_req = 0;
wire [2:0] wr = {wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

// rfs_cnt/rfs/rfs2 (access-manager block below) and init_old
// (initialization block further down) both used to be declared as
// block-local `reg`s inside their own `always @(posedge clk)` blocks --
// rfs_cnt/rfs/rfs2 as plain `reg`, init_old as `static reg init_old=0;`
// (upstream's own existing pattern, inherited here, not added by this
// project). Both forms compile fine under ModelSim but Quartus 17.0's
// SystemVerilog elaborator rejects non-blocking assignments to EITHER
// form outright ("automatic variables can't have non-blocking
// assignments") -- a real Quartus-only synthesis error, not a ModelSim
// quirk, found running quartus_map on the real Psikyo.sv build
// (docs/ROADMAP.md's top-level integration work). `static` is not a
// working fix for this Quartus version; moving the declarations to
// module level (unambiguously static, like every other reg in this file)
// is. Given explicit `= 0` initializers at the same time, same
// simulation-fidelity reasoning as `state`/`active`/`ram_req` above.
reg [9:0] rfs_cnt = 10'd0;
reg        rfs = 1'b0, rfs2 = 1'b0;
reg         init_old = 1'b0;

reg [63:0] dout;

assign dout0 = dout;
assign dout1 = dout;
assign dout2 = dout;

// mode/reset must be declared before the access-manager block below since
// it references them -- SystemVerilog (unlike the plain-Verilog upstream
// this was adapted from) doesn't resolve forward references across
// always-block boundaries the same way, confirmed by compiling with vlog -sv.
localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

reg [1:0] mode;
reg [4:0] reset=5'h1f;

// access manager
always @(posedge clk) begin
	rfs_cnt <= rfs_cnt + 1'd1;
	// 670, not upstream's 850. The MT48LC16M16 needs 8192 auto-refresh
	// commands per 64 ms = one every 7.8125 us. At this project's
	// 85.909091 MHz clk_sys, 850 cycles is 9.90 us -- 27% OVER spec. That
	// is a real violation, not a margin: during the multi-second 14.7 MB
	// ROM download the refresh is also deferred by traffic (rfs <= rfs2
	// below), and address 0 is written FIRST, so the reset vector sits
	// longest of all before the CPU reads it. Symptom was non-deterministic
	// ROM corruption -- the same .mra read back correct on one load and
	// corrupt on the next. 670 cycles = 7.80 us, just inside spec.
	if (rfs_cnt == 670) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == 335) rfs2 <= 1;   // half of the interval above

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if (rfs) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			we <= 0;
			dqm <= 2'b00;
			active <= 0;
			state <= STATE_START;
		end
		else if (ack0 != req0) begin
			{ba,a} <= addr0;
			data <= din0;
			we <= wr[0];
			dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00;
			active <= 1;
			ram_req[0] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack1 != req1) begin
			{ba,a} <= addr1;
			data <= din1;
			we <= wr[1];
			dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00;
			active <= 1;
			ram_req[1] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
		else if (ack2 != req2) begin
			{ba,a} <= addr2;
			data <= din2;
			we <= wr[2];
			dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00;
			active <= 1;
			ram_req[2] <= 1;
			rfs <= rfs2;
			state <= STATE_START;
		end
	end

	// Burst-of-4 read capture: one 16-bit lane per cycle across the four
	// STATE_READ0..STATE_READ3 cycles, ascending address order (lane 0 =
	// lowest address = dout[15:0]) matching ACCESS_TYPE=sequential above.
	// Write completion (ack, no data capture) shares STATE_READ3 for a
	// single uniform completion point -- see PROVENANCE.md for why.
	if (state == STATE_READ0 && ram_req && !we) dout[15:0]  <= SDRAM_DQ;
	if (state == STATE_READ1 && ram_req && !we) dout[31:16] <= SDRAM_DQ;
	if (state == STATE_READ2 && ram_req && !we) dout[47:32] <= SDRAM_DQ;
	if (state == STATE_READ3 && ram_req) begin
		if (!we) dout[63:48] <= SDRAM_DQ;
		active <= 0;
		ram_req <= 0;
		if (ram_req[0]) ack0 <= req0;
		else if (ram_req[1]) ack1 <= req1;
		else if (ram_req[2]) ack2 <= req2;
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 4'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end


// initialization
always @(posedge clk) begin
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
reg         dq_oe;
reg  [15:0] dq_out;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bz;

always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? ba : 2'b00;

	dq_oe <= 1'b0;
	casex({active,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= active ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin
			{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
			dq_oe  <= 1'b1;
			dq_out <= data;
		end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(state)
			// Row/column split SWAPPED from upstream (upstream: row=a[13:1]
			// (low bits), col=a[22:14] (high bits)). Upstream never bursts
			// (BURST_LENGTH=0), so the split is an arbitrary choice there.
			// For burst-4, the low address bits MUST select the column,
			// since that's what the SDR chip auto-increments across a
			// burst -- 4 consecutive word addresses need to land at 4
			// consecutive columns of the SAME row, not 4 different rows.
			// Confirmed as a real bug (not a hunch) by tb_sdram.sv: with
			// the upstream split, a 4-word burst starting at word address N
			// silently read from rows N, N+1, N+2, N+3 at column 0 each
			// time -- wrong data, not just misaligned. See PROVENANCE.md.
			STATE_START: SDRAM_A <= a[22:10];
			STATE_CONT:  SDRAM_A <= {dqm, 2'b10, a[9:1]};
		endcase
	end
	else if(mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
end

// Upstream drives SDRAM_CLK via an altddio_out megafunction instance here
// (a phase-shifted DDR output, so the chip sees a clock edge advanced
// relative to the address/command bus it's latching against). Deliberately
// NOT vendored into this module -- same posture as ddram_phy.sv, which
// documents "DDRAM_CLK is driven separately at the top level... not by this
// module": keeps this transport-layer module free of device-specific hard
// IP that would need Altera's simulation libraries (altera_mf) compiled and
// mapped just to simulate the burst-4 read logic this module actually
// exists to verify. Real SDRAM_CLK phase generation is top-level
// integration work (see docs/ROADMAP.md's "Next steps"), same stage as
// wiring this module's ports into the real address map/arbiters.
assign SDRAM_CLK = clk;

endmodule
