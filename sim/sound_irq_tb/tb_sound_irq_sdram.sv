// Sound IRQ lockup reproduction: the REAL Gunbird sound ROM (3.u71)
// running on the real sound_cpu (T80) + real jt10 (YM2610), clocked and
// wired EXACTLY as rtl/psikyo_top.sv wires them -- including the detail
// that the Z80 runs at the full clk (T80se CLKEN=1, ~21x its real 4 MHz)
// while jt10 gets the production 88/945 Bresenham 8 MHz clock-enable.
// That arrangement is replicated deliberately, not "fixed", because the
// hardware symptom under investigation lives in it: enabling the YM->Z80
// timer IRQ (snd_irq_en) locks the Z80 solid on real hardware
// (docs/LESSONS_LEARNED.md, sound section), and the boot jingle plays
// garbled before the silence. This testbench boots the real driver with
// the IRQ path ENABLED and watches what actually happens at the first
// timer interrupt.
//
// Instrumentation (all hierarchical/test-side, no RTL changes):
//   - every YM register write (address port + data port pairs), timestamped
//   - ym_irq_n edges (timer IRQ assert/deassert)
//   - ISR entry (M1 opcode fetch at 0x0038) and RETI/EI sightings
//   - HALT state
//   - a watchdog: if no new M1 fetch happens for 2 ms of sim time, declare
//     lockup and dump the stuck state
//
// ROM port: 5-cycle req/valid model (same as the existing sound_cpu TBs;
// the ROM transport is not under suspicion here -- but note the tilemap
// lesson: if this TB FAILS to reproduce, the next fidelity step is the
// real SDRAM stack behind the audiocpu narrow bridge).

module tb_sound_irq_sdram;

	logic clk = 0;
	always #5 clk = ~clk;   // stands for the 85.909 MHz clk_sys

	logic reset;

	// 4 MHz Z80 clock enable -- production 44/945 Bresenham, mirroring
	// psikyo_top.sv's z80_cen exactly (the former SLOW_Z80 divided-clock
	// experiment is superseded: the production fix IS the slow Z80).
	logic [9:0] z80_cen_acc = 10'd0;
	logic        z80_cen;
	always_ff @(posedge clk) begin
		if (z80_cen_acc >= 10'd945 - 10'd44) z80_cen_acc <= z80_cen_acc + 10'd44 - 10'd945;
		else                                   z80_cen_acc <= z80_cen_acc + 10'd44;
	end
	assign z80_cen = (z80_cen_acc >= 10'd945 - 10'd44);
	wire clk_z80 = clk;   // single clock domain again; pacing comes from cen_4m

	// ---- sound_cpu (real), wired as psikyo_top does ----
	logic         rom_req;
	logic [16:0] rom_addr;
	logic         rom_valid;
	logic [7:0]  rom_data;
	logic [7:0]  latch_data  = 8'h00;
	logic         latch_write = 1'b0;
	logic         nmi_pending;
	logic         ym_cs, ym_rd, ym_wr;
	logic [2:0]  ym_addr;   // widened with sound_cpu's OPL4 window; jt10 uses [1:0]
	logic [7:0]  ym_dout, ym_din;
	logic         ym_irq_n;

	sound_cpu u_sound (
		.clk(clk), .reset(reset), .board_gunbird(1'b1), .board_sh404(1'b0),
		.cen_4m(z80_cen),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.latch_data(latch_data), .latch_write(latch_write),
		.nmi_pending(nmi_pending),
		.ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
		.ym_dout(ym_dout), .ym_din(ym_din),
		.ym_irq_n(ym_irq_n)      // snd_irq_en = 1: IRQ path ENABLED
`ifdef DEBUG_ISSP
		, .dbg_latch_ack_event()
`endif
	);

	// ---- ym_cen: production Bresenham, copied verbatim from psikyo_top ----
	logic [9:0] ym_cen_acc = 10'd0;
	logic        ym_cen;
	always_ff @(posedge clk) begin
		if (ym_cen_acc >= 10'd945 - 10'd88) ym_cen_acc <= ym_cen_acc + 10'd88 - 10'd945;
		else                                  ym_cen_acc <= ym_cen_acc + 10'd88;
	end
	assign ym_cen = (ym_cen_acc >= 10'd945 - 10'd88);

	// ---- jt10 (real), wired as psikyo_top does; ADPCM-A served instantly
	// with zero bytes (an unpopulated sample ROM), ADPCM-B tied zero ----
	logic [19:0] adpcma_addr;
	logic [4:0]  adpcma_bank;
	logic         adpcma_roe_n;
	logic [23:0] adpcmb_addr;
	logic         adpcmb_roe_n;
	logic signed [15:0] snd_left, snd_right;
	logic         snd_sample;

	jt10 u_ym2610 (
		.rst        (reset),
		.clk        (clk),
		.cen        (ym_cen),
		.din        (ym_dout),
		.addr       (ym_addr[1:0]),
		.cs_n       (~(ym_cs & (ym_rd | ym_wr))),
		.wr_n       (~ym_wr),
		.dout       (ym_din),
		.irq_n      (ym_irq_n),
		.adpcma_addr(adpcma_addr), .adpcma_bank(adpcma_bank),
		.adpcma_roe_n(adpcma_roe_n), .adpcma_data(8'd0),
		.adpcmb_addr(adpcmb_addr), .adpcmb_roe_n(adpcmb_roe_n), .adpcmb_data(8'd0),
		.snd_left(snd_left), .snd_right(snd_right), .snd_sample(snd_sample)
	);

	// ---- PRODUCTION ROM transport: psikyo_sdram_top's audiocpu path
	// (sdram_narrow_bridge WORD_BYTES=1 -> arbiter client c3 -> sdram_phy
	// -> sdram.sv -> chip model), every other client tied off. The
	// behavioral fixed-latency model cannot reproduce the on-hardware
	// freeze -- variable real-transport latency is the ingredient, same
	// lesson as the tilemap bug. ----
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic [1:0]  SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	logic         SDRAM_CLK, SDRAM_CKE;
	wire  [15:0] SDRAM_DQ;

	psikyo_sdram_top u_sdram (
		.clk(clk), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
		.ioctl_addr(25'd0), .ioctl_dout(8'd0), .ioctl_wait(),
		.l0_gfxrom_req(1'b0), .l0_gfxrom_addr(22'd0),
		.l0_gfxrom_valid(), .l0_gfxrom_data(),
		.l1_gfxrom_req(1'b0), .l1_gfxrom_addr(22'd0),
		.l1_gfxrom_valid(), .l1_gfxrom_data(),
		.sp_gfxrom_req(1'b0), .sp_gfxrom_addr(23'd0),
		.sp_gfxrom_valid(), .sp_gfxrom_data(),
		.sp_lut_req(1'b0), .sp_lut_addr(17'd0),
		.sp_lut_valid(), .sp_lut_data(),
		.cpu_rom_req(1'b0), .cpu_rom_addr(19'd0),
		.cpu_rom_valid(), .cpu_rom_data(),
		.audiocpu_rom_req(rom_req), .audiocpu_rom_addr({1'b0, rom_addr}),
		.audiocpu_rom_valid(rom_valid), .audiocpu_rom_data(rom_data),
		.adpcma_rom_req(1'b0), .adpcma_rom_addr(20'd0),
		.adpcma_rom_valid(), .adpcma_rom_data()
	);

	sdram_chip_model_wide chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	localparam logic [24:0] AUDIOCPU_BASE = 25'h0200000;
	logic [7:0] rom [0:131071];
	initial begin
		$readmemh("gunbird_sound_rom.hex", rom);
		for (int i = 0; i < 65536; i++)
			chip.poke_word_addr(24'((AUDIOCPU_BASE >> 1) + i), {rom[2*i+1], rom[2*i]});
	end

	// ---- ROM handshake trace (stall hunt) ----
	always_ff @(posedge clk) begin
		if (!reset && rom_req)
			$display("[%0t] ROM_REQ addr=0x%05X bridge_state=%0d cache_valid=%0d",
					  $time, rom_addr, u_sdram.u_audiocpu_bridge.bstate,
					  u_sdram.u_audiocpu_bridge.cache_valid);
		if (!reset && rom_valid)
			$display("[%0t] ROM_VALID data=0x%02X bridge_state=%0d",
					  $time, rom_data, u_sdram.u_audiocpu_bridge.bstate);
	end

	// ---- port-2 chain trace (stall hunt, layer by layer) ----
	logic g_req_d, arb_pv_d, p2req_d, p2ack_d, phybusy_d;
	logic [1:0] astate_d;
	always_ff @(posedge clk) begin
		g_req_d   <= u_sdram.u_audiocpu_bridge.g_req;
		astate_d  <= u_sdram.u_arbiter.astate;
		arb_pv_d  <= u_sdram.p2phy_valid;
		p2req_d   <= u_sdram.p2_req;
		p2ack_d   <= u_sdram.p2_ack;
		phybusy_d <= u_sdram.p2phy_busy;
		if ($time > 9000 && $time < 40000) begin
			if (u_sdram.u_audiocpu_bridge.g_req !== g_req_d)
				$display("[%0t] g_req -> %0d", $time, u_sdram.u_audiocpu_bridge.g_req);
			if (u_sdram.u_arbiter.astate !== astate_d)
				$display("[%0t] arb astate -> %0d (sel=%0d found=%0d phy_busy=%0d)",
						  $time, u_sdram.u_arbiter.astate, u_sdram.u_arbiter.sel,
						  u_sdram.u_arbiter.found, u_sdram.p2phy_busy);
			if (u_sdram.p2phy_busy !== phybusy_d)
				$display("[%0t] p2phy_busy -> %0d", $time, u_sdram.p2phy_busy);
			if (u_sdram.p2_req !== p2req_d)
				$display("[%0t] p2_req(toggle) -> %0d (ack=%0d)", $time, u_sdram.p2_req, u_sdram.p2_ack);
			if (u_sdram.p2_ack !== p2ack_d)
				$display("[%0t] p2_ack(toggle) -> %0d", $time, u_sdram.p2_ack);
			if (u_sdram.p2phy_valid !== arb_pv_d)
				$display("[%0t] p2phy_valid -> %0d", $time, u_sdram.p2phy_valid);
		end
	end

	// ---- instrumentation ----
	int ym_write_count;
	logic ym_wr_d;
	logic [7:0] ym_reg_addr [0:1];   // last value written to address port, per bank

	always_ff @(posedge clk) begin
		ym_wr_d <= ym_wr;
		if (ym_wr && !ym_wr_d) begin
			ym_write_count <= ym_write_count + 1;
			if (ym_write_count < 60 || ym_addr[0] == 1'b0)
				;   // register-address writes logged compactly below
			if (ym_addr[0] == 1'b0)
				ym_reg_addr[ym_addr[1]] <= ym_dout;
			else
				$display("[%0t] YM write #%0d: bank%0d reg 0x%02X = 0x%02X",
						  $time, ym_write_count, ym_addr[1],
						  ym_reg_addr[ym_addr[1]], ym_dout);
		end
	end

	logic irq_n_d;
	always_ff @(posedge clk) begin
		irq_n_d <= ym_irq_n;
		if (irq_n_d && !ym_irq_n)
			$display("[%0t] *** YM IRQ ASSERTED (irq_n fell) -- ym writes so far: %0d", $time, ym_write_count);
		if (!irq_n_d && ym_irq_n)
			$display("[%0t] *** YM IRQ CLEARED (irq_n rose)", $time);
	end

	// M1 opcode fetch tracking (hierarchical into sound_cpu's T80 bus)
	logic        m1_fetch;
	logic [15:0] last_m1_addr;
	longint      last_m1_time;
	logic        in_isr;

	assign m1_fetch = !u_sound.m1_n && !u_sound.mreq_n && !u_sound.rd_n && u_sound.wait_n;

	logic m1_fetch_d;
	always_ff @(posedge clk) begin
		m1_fetch_d <= m1_fetch;
		if (m1_fetch && !m1_fetch_d) begin
			last_m1_addr <= u_sound.a;
			last_m1_time <= $time;
			if (u_sound.a == 16'h0038 && !in_isr) begin
				in_isr <= 1'b1;
				$display("[%0t] >>> ISR ENTRY (M1 at 0x0038)", $time);
			end
		end
		// EI opcode sighting (0xFB on the data bus during an M1 read)
		if (m1_fetch && !m1_fetch_d && u_sound.di == 8'hFB)
			$display("[%0t] EI executed at PC=0x%04X", $time, u_sound.a);
		if (!u_sound.halt_n && u_sound.halt_n !== 1'bx) begin
			// reported once via the watchdog dump rather than spamming
		end
	end

	// watchdog: no new M1 fetch for 2 ms (200_000 clk at 10 ns) => lockup.
	// Cycle-counted rather than $time-compared -- immune to timeunit/
	// resolution mismatches between # delays (ns here) and $time (ps).
	int m1_idle_cycles;
	always_ff @(posedge clk) begin
		if (reset || (m1_fetch && !m1_fetch_d)) m1_idle_cycles <= 0;
		else                                       m1_idle_cycles <= m1_idle_cycles + 1;
	end

	initial begin
		forever begin
			@(posedge clk);
			if (m1_idle_cycles > 200000) begin
				$display("[%0t] !!! LOCKUP: no M1 fetch for >2 ms. last_m1_addr=0x%04X halt_n=%0d ym_irq_n=%0d nmi_pending=%0d wait_n=%0d state: mreq_n=%0d iorq_n=%0d rd_n=%0d wr_n=%0d a=0x%04X",
						  $time, last_m1_addr, u_sound.halt_n, ym_irq_n, nmi_pending,
						  u_sound.wait_n, u_sound.mreq_n, u_sound.iorq_n,
						  u_sound.rd_n, u_sound.wr_n, u_sound.a);
				$display("!!! ending sim at lockup for inspection");
				$finish;
			end
		end
	end

	// activity counters for jt10's internal FM clocking: clk_en is the
	// prescaler output (cen/6 for YM2610), zero the 24-slot pipeline marker
	// the timers count on. If either never ticks, loaded+enabled timers
	// sit frozen exactly as observed.
	longint clk_en_ticks, zero_ticks;
	logic zero_d;
	always_ff @(posedge clk) begin
		if (u_ym2610.u_jt12.clk_en) clk_en_ticks <= clk_en_ticks + 1;
		zero_d <= u_ym2610.u_jt12.zero;
		if (u_ym2610.u_jt12.zero && !zero_d) zero_ticks <= zero_ticks + 1;
	end

	task automatic print_timers(string tag);
		$display("[%0t] TIMERS(%s): value_A=0x%03X load_A=%0d enable_irq_A=%0d flag_A=%0d value_B=0x%02X load_B=%0d enable_irq_B=%0d flag_B=%0d irq_n=%0d",
				  $time, tag,
				  u_ym2610.u_jt12.u_timers.value_A,  u_ym2610.u_jt12.u_timers.load_A,
				  u_ym2610.u_jt12.u_timers.enable_irq_A, u_ym2610.u_jt12.u_timers.flag_A,
				  u_ym2610.u_jt12.u_timers.value_B,  u_ym2610.u_jt12.u_timers.load_B,
				  u_ym2610.u_jt12.u_timers.enable_irq_B, u_ym2610.u_jt12.u_timers.flag_B,
				  ym_irq_n);
		$display("          clk_en_ticks=%0d zero_ticks=%0d", clk_en_ticks, zero_ticks);
	endtask

	initial begin
		// periodic timer-state samples: right after boot, then each 10 ms
		repeat (2) @(negedge reset);
	end

	initial begin
		#2000000;    // 2 ms (ns units): boot writes long finished
		print_timers("post-boot");
		forever begin
			#10000000;   // every 10 ms
			print_timers("periodic");
		end
	end

	initial begin
		reset = 1;
		repeat (20) @(posedge clk);
		reset = 0;
		$display("[%0t] reset released -- real gunbird sound ROM booting, IRQ path ENABLED", $time);

		// let boot + a few timer periods pass, then send a sound command the
		// way the 68020's latch write reaches sound_cpu (latch_write pulse),
		// and watch for NMI -> ISR -> ack -> YM key-on activity.
		repeat (2000000) @(posedge clk);   // 20 ms
		$display("[%0t] === sending sound command 0x01 via latch ===", $time);
		latch_data  = 8'h01;
		latch_write = 1'b1;
		@(posedge clk);
		latch_write = 1'b0;
		fork
			begin
				wait (nmi_pending == 1'b0);
				$display("[%0t] === latch ACKED by Z80 ISR (nmi_pending cleared) ===", $time);
			end
		join_none

		// run up to 80 ms total sim time
		repeat (6000000) @(posedge clk);   // 60 more ms
		$display("[%0t] END: 80 ms elapsed without watchdog lockup. ym_write_count=%0d last_m1_addr=0x%04X",
				  $time, ym_write_count, last_m1_addr);
		$finish;
	end

endmodule
