// Checks sound_cpu_gunbird's address decode / banking / WAIT_n generation
// and the sound-latch/NMI handshake, against a REAL variable-latency (5
// cycle) req/valid ROM model for the ROM port -- RAM/I/O still behave as
// fixed 1-cycle, matching the module's own split scheme (see its header).
// Mirrors sound_cpu_sngkace_tb's structure and its req/valid conversion
// exactly (two separate scenarios, same reasoning for keeping them
// separate, same T80-internal T-state tracing -- see that testbench's
// header for the full derivation this module's conversion is built on),
// adjusted for gunbird's different memory map, RAM size, I/O port layout,
// and bank-select shift. Scenario 1's `LD A,(0x8200)` already exercises
// the same "3-byte opcode whose own memory-read M-cycle follows two
// operand-fetch M-cycles" shape sngkace's bug was found against -- kept
// unchanged specifically to stress that shape here too, not invented new.
//
// Scenario 1 (straight-line, NMI never fires): exercises fixed-ROM fetch,
// a RAM write (0x8000, gunbird's RAM base -- different from sngkace's
// 0x7800), a bank-register write via port 0x00 with the (data>>4)&0x03
// shift (data=0x20 -> bank=2, same target bank as sngkace's test for an
// easy A/B), and a banked-ROM read at 0x8200 (the first banked address --
// confirms the {bank,addr[14:0]} formula holds right at the 0x8200
// boundary, not just somewhere in the middle of the window), echoed via
// the YM stub port (now at 0x04, not 0x00 -- ports moved vs sngkace).
//   0000: 3E 55        LD A,0x55
//   0002: 32 00 80     LD (0x8000),A      -- RAM write
//   0005: 3E 20        LD A,0x20
//   0007: D3 00        OUT (0x00),A       -- bank = (0x20>>4)&3 = 2
//   0009: 3A 00 82     LD A,(0x8200)      -- banked ROM read, first banked byte
//   000C: D3 04        OUT (0x04),A       -- echo to YM stub port (observable)
//   000E: 76           HALT
//
// Scenario 2 (NMI handshake): identical shape to sngkace's, only the echo
// port moves (0x04, since 0x00 is now the bank register, not YM).
//   0000: 76           HALT
//   0066: DB 08        IN A,(0x08)        -- read the latch
//   0068: D3 04        OUT (0x04),A       -- echo it (observable)
//   006A: D3 0C        OUT (0x0C),A       -- ack (clears NMI)
//   006C: ED 45        RETN

module tb_sound_cpu_gunbird;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset;
	logic         rom_req;
	logic [16:0] rom_addr;
	logic         rom_valid;
	logic [7:0]  rom_data;
	logic [7:0]  latch_data;
	logic         latch_write;
	logic         nmi_pending; // unused by these tests, just needed for the .* binding below
	logic         ym_cs;
	logic [1:0]  ym_addr;
	logic         ym_rd, ym_wr;
	logic [7:0]  ym_dout;
	logic [7:0]  ym_din;

	int errors;

	assign ym_din = 8'hAA;   // arbitrary fixed stub response, unused by these tests' reads

	sound_cpu_gunbird dut (.*);

	// ---- ROM model: real req/valid, fixed 5-cycle round trip (matches
	// sound_cpu_sngkace_tb's model exactly) ----
	logic [7:0] rom [0:131071];
	localparam int ROM_LATENCY = 5;
	logic         rom_busy;
	int           rom_cnt;
	// plain always, not always_ff: this block also increments `errors`,
	// which the initial block's procedural code drives too -- always_ff
	// enforces single-driver exclusivity that a plain always doesn't.
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			rom_busy  <= 1'b0;
			rom_valid <= 1'b0;
		end else begin
			rom_valid <= 1'b0;
			if (rom_req && !rom_busy) begin
				rom_busy <= 1'b1;
				rom_cnt  <= 0;
			end else if (rom_busy) begin
				if (rom_cnt == ROM_LATENCY - 1) begin
					rom_valid <= 1'b1;
					rom_data  <= rom[rom_addr];
					rom_busy  <= 1'b0;
				end else begin
					rom_cnt <= rom_cnt + 1;
				end
			end
			if (rom_req && rom_busy) begin
				$display("FAIL: rom_req pulsed while a previous ROM access was still in flight (rom_pending race)");
				errors++;
			end
		end
	end

	// ---- T80-internal T-state/M-cycle trace, around LD A,(0x8200)'s full
	// M-cycle sequence: its own 3 fetch bytes (rom_addr 0x0009-0x000B) and
	// the banked read it triggers (rom_addr 0x10200, physical for bank 2
	// offset 0x200 -- see rom_addr's {bank,a[14:0]} concatenation). See
	// tb_sound_cpu_sngkace.sv's header for why this trace matters.
	logic [2:0] mcycle_prev, tstate_prev;
	always_ff @(posedge clk) begin
		if ({dut.u_cpu.u0.MCycle, dut.u_cpu.u0.TState} !== {mcycle_prev, tstate_prev}) begin
			if ((rom_addr >= 17'h00009 && rom_addr <= 17'h0000B) ||
				(rom_addr >= 17'h10200 && rom_addr <= 17'h10202))
				$display("T80 trace: MCycle=%0d TState=%0d rom_addr=%h rom_req=%b rom_valid=%b wait_n=%b",
						  dut.u_cpu.u0.MCycle, dut.u_cpu.u0.TState, rom_addr, rom_req, rom_valid, dut.wait_n);
			mcycle_prev <= dut.u_cpu.u0.MCycle;
			tstate_prev <= dut.u_cpu.u0.TState;
		end
	end

	// capture every YM stub write as a small FIFO-ish trail (only a few
	// writes ever happen in these tests, so a plain array + count is fine)
	logic [7:0] ym_writes [0:15];
	int          ym_write_count;
	always_ff @(posedge clk) begin
		if (ym_wr) begin
			ym_writes[ym_write_count] <= ym_dout;
			ym_write_count             <= ym_write_count + 1;
		end
	end

	task automatic reset_dut;
		ym_write_count = 0;
		latch_write = 0;
		latch_data  = 8'h00;
		reset = 1;
		@(posedge clk); @(posedge clk);
		reset = 0;
	endtask

	task automatic run_cycles(int n);
		repeat (n) @(posedge clk);
	endtask

	initial begin
		errors = 0;
		for (int i = 0; i < 131072; i++) rom[i] = 8'h00;

		// ---- Scenario 1 ----
		rom[16'h0000] = 8'h3E; rom[16'h0001] = 8'h55;
		rom[16'h0002] = 8'h32; rom[16'h0003] = 8'h00; rom[16'h0004] = 8'h80;
		rom[16'h0005] = 8'h3E; rom[16'h0006] = 8'h20;
		rom[16'h0007] = 8'hD3; rom[16'h0008] = 8'h00;
		rom[16'h0009] = 8'h3A; rom[16'h000A] = 8'h00; rom[16'h000B] = 8'h82;
		rom[16'h000C] = 8'hD3; rom[16'h000D] = 8'h04;
		rom[16'h000E] = 8'h76;
		// physical 0x10200 (bank 2, offset 0x200 -- {bank,addr[14:0]} for
		// addr=0x8200) -- what the banked read should return
		rom[17'h10200] = 8'hC7;

		reset_dut();
		run_cycles(2000);

		if (dut.ram[0] !== 8'h55) begin
			errors++;
			$display("FAIL(s1) RAM[0]: got=%h expected=55", dut.ram[0]);
		end
		if (dut.bank !== 2'd2) begin
			errors++;
			$display("FAIL(s1) bank register: got=%0d expected=2", dut.bank);
		end
		if (ym_write_count < 1 || ym_writes[0] !== 8'hC7) begin
			errors++;
			$display("FAIL(s1) YM stub write: count=%0d first=%h expected first=C7", ym_write_count, ym_writes[0]);
		end
		if (dut.halt_n !== 1'b0) begin
			errors++;
			$display("FAIL(s1) core did not reach HALT");
		end
		$display("Scenario 1 done (fixed ROM fetch, RAM write, bank switch w/ >>4 shift, banked ROM read at 0x8200 boundary)");

		// ---- Scenario 2 ----
		for (int i = 0; i < 131072; i++) rom[i] = 8'h00;
		rom[16'h0000] = 8'h76;   // HALT immediately
		rom[16'h0066] = 8'hDB; rom[16'h0067] = 8'h08;   // IN A,(0x08)
		rom[16'h0068] = 8'hD3; rom[16'h0069] = 8'h04;   // OUT (0x04),A
		rom[16'h006A] = 8'hD3; rom[16'h006B] = 8'h0C;   // OUT (0x0C),A
		rom[16'h006C] = 8'hED; rom[16'h006D] = 8'h45;   // RETN

		reset_dut();
		run_cycles(500);   // let it reach HALT and settle

		if (dut.halt_n !== 1'b0) begin
			errors++;
			$display("FAIL(s2) core did not reach HALT before latch_write");
		end
		if (dut.latch_pending !== 1'b0) begin
			errors++;
			$display("FAIL(s2) latch_pending asserted before any latch_write");
		end

		latch_data  = 8'h77;
		latch_write = 1'b1;
		@(posedge clk);
		latch_write = 1'b0;

		// latch_pending should assert immediately (combinational off the write)
		run_cycles(1);
		if (dut.latch_pending !== 1'b1) begin
			errors++;
			$display("FAIL(s2) latch_pending did not assert after latch_write");
		end

		run_cycles(1000);   // let the NMI handler run to completion

		if (ym_write_count < 1 || ym_writes[0] !== 8'h77) begin
			errors++;
			$display("FAIL(s2) NMI handler did not echo the latch value: count=%0d first=%h expected 77",
					  ym_write_count, ym_writes[0]);
		end
		if (dut.latch_pending !== 1'b0) begin
			errors++;
			$display("FAIL(s2) latch_pending not cleared after handler's ack write");
		end
		$display("Scenario 2 done (sound latch write -> NMI -> handler reads/echoes/acks)");

		if (errors == 0)
			$display("PASS: sound_cpu_gunbird matches reference for all cases, ROM port verified against a real 5-cycle-latency req/valid model");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
