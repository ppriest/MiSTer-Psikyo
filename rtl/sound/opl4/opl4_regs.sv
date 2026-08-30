// YMF278B (OPL4) bus interface, status, timers and PCM register file.
//
// Modeled on MAME's ymfm reference (3rdparty/ymfm: ymfm_opl.h ymf278b,
// ymfm_pcm.h pcm_registers) -- the same code MAME's psikyo.cpp uses for
// these boards, and this project's accuracy target. FM synthesis is NOT
// implemented here (opl4.sv's header explains the split); this block
// carries everything the sound program interacts with directly: the
// 6-port bus protocol, chip-ID/status/busy semantics, the two OPL
// timers with their IRQ (the Z80 sound driver's sequencer heartbeat),
// the NEW/NEW2 mode flags, the 256-byte PCM register file, and the
// external-memory access window (PCM regs 02-06).
//
// Port map (offset within the chip select, = Z80 I/O 0x08+offset):
//   0 r: status    w: FM address low
//   1 w: FM data
//   2 w: FM address high   3 w: FM data
//   4 w: PCM address       5 rw: PCM data
//
// Status: bit7 IRQ, bit6 timer A, bit5 timer B, bit1 LD, bit0 BUSY.
// The first status read after reset or NEW2 0->1 returns a chip ID
// (NEW2 ? 02 : NEW ? 00 : 06) instead. BUSY/LD read as 0 unless NEW2.
module opl4_regs (
	input  logic        clk,
	input  logic        reset,
	input  logic        chip_cen,      // ~33.8688 MHz enable (opl4.sv)
	input  logic        fm_tick,       // chip_cen/684: one FM sample (timer time base)

	// Z80-facing bus (one-cycle rd/wr strobes from sound_cpu's I/O decode)
	input  logic [2:0] addr,
	input  logic        rd,
	input  logic        wr,
	input  logic [7:0] din,
	output logic [7:0] dout,
	output logic        irq_n,

	// PCM register file read port for the wavetable engine (opl4_pcm.sv):
	// combinational, engine-owned; the engine's own header-load writes come
	// back through pcm_hdr_we (never simultaneous with a Z80 data write --
	// the engine holds them off while a bus write is in flight this cycle).
	input  logic [7:0] pcm_raddr,
	output logic [7:0] pcm_rdata,
	input  logic        pcm_hdr_we,
	input  logic [7:0] pcm_hdr_waddr,
	input  logic [7:0] pcm_hdr_wdata,

	// PCM engine notifications
	output logic        pcm_keyon_stb,     // pulse: write hit 0x68-0x7F
	output logic [4:0] pcm_keyon_ch,
	output logic        pcm_keyon_val,     // bit 7 of the written data
	output logic        pcm_wavesel_stb,   // pulse: write hit 0x08-0x1F (load wavetable)
	output logic [4:0] pcm_wavesel_ch,
	output logic        new2,               // OPL4 mode enabled (gates PCM writes)

	// External sample memory window (PCM regs 02-06), shared SDRAM client
	// owned by opl4.sv: this block only issues the byte-at-address
	// prefetches the data-port protocol needs.
	output logic        mem_rd_req,        // pulse: fetch byte at mem_rd_addr
	output logic [21:0] mem_rd_addr,
	input  logic        mem_rd_valid,
	input  logic [7:0] mem_rd_data
);

	// ---- address register (10 bits: bit9 = PCM space, bit8 = FM high) ----
	logic [9:0] address;

	// ---- FM register subset ----
	// Only what the non-synthesis side needs: timers (02/03/04), NEW
	// (0x105 bit0), NEW2 (0x105 bit1). Other FM writes are accepted and
	// dropped (synthesis not implemented -- opl4.sv header).
	logic [7:0] timer_a_reg, timer_b_reg;
	logic        mask_a, mask_b, load_a, load_b;
	logic        flag_a, flag_b;
	logic        new1;

	// Timer counters: A counts (1024 - 4*value) FM samples -- implemented
	// as a count-up from value*4 to 1023; B counts 16*(256 - value), as a
	// count-up from value*16 to 4095.
	logic [9:0]  timer_a_cnt;
	logic [11:0] timer_b_cnt;

	// ---- PCM register file ----
	logic [7:0] pcm_regs [0:255];
	assign pcm_rdata = pcm_regs[pcm_raddr];

	// ---- status / busy / ID ----
	logic        next_status_id;
	logic [7:0] busy_cnt;           // chip-clock countdown: 56 FM / 88 PCM writes
	wire         busy = (busy_cnt != 8'd0);
	wire         irq  = (flag_a & ~mask_a) | (flag_b & ~mask_b);
	assign irq_n = ~irq;

	// LD: wavetable header loads take "about 300us" (13 samples); the real
	// engine load is far faster here, but the flag is part of the protocol
	// the driver may poll, so time it like the reference.
	logic [3:0] ld_cnt;
	logic [9:0] ld_sample_div;      // counts chip_cen/768 like the sample tick

	logic [7:0] status;
	always_comb begin
		status = {irq, flag_a, flag_b, 3'b000, (ld_cnt != 0), busy};
		if (!new2) status &= 8'hFC;   // BUSY/LD visible only in OPL4 mode
	end

	// ---- memory-access window (PCM regs 02-06) ----
	// reg 02 bit0 = memory access mode; regs 03-05 = 22-bit address;
	// reg 06 = data port with post-increment. Reads cannot stall the Z80,
	// so the byte at the CURRENT address is prefetched whenever the
	// address changes (or after each data access) and served from
	// mem_buf; BUSY covers the fetch latency.
	logic [7:0] mem_buf;
	logic        mem_pending;
	wire  [21:0] mem_addr_cur = {pcm_regs[8'h03][5:0], pcm_regs[8'h04], pcm_regs[8'h05]};
	assign mem_rd_addr = mem_addr_cur;
	wire mem_mode = pcm_regs[8'h02][0];

	// ---- bus read mux ----
	// The value is LATCHED on the read strobe: reads have side effects
	// (the ID consume below), and the Z80 samples the data bus late in
	// its I/O cycle -- a combinational dout would have already flipped to
	// the post-consume value by then.
	logic [7:0] read_val;
	always_comb begin
		read_val = 8'hFF;
		if (addr == 3'd0) begin
			read_val = next_status_id ? (new2 ? 8'h02 : (new1 ? 8'h00 : 8'h06)) : status;
		end else if (addr == 3'd5 && address[9]) begin
			case (address[7:0])
				8'h02:   read_val = pcm_regs[8'h02] | 8'h20;   // device ID = 1 (YMF278B)
				8'h06:   read_val = mem_mode ? mem_buf : pcm_regs[8'h06];
				default: read_val = pcm_regs[address[7:0]];
			endcase
		end
	end
	always_ff @(posedge clk or posedge reset) begin
		if (reset) dout <= 8'hFF;
		else if (rd) dout <= read_val;
	end

	// ---- write / status / timer logic ----
	wire fm_space  = wr && (addr == 3'd1 || addr == 3'd3) && !address[9];
	wire pcm_space = wr && (addr == 3'd5) && address[9];

	assign pcm_keyon_stb   = pcm_space && new2 && (address[7:0] >= 8'h68) && (address[7:0] <= 8'h7F);
	assign pcm_keyon_ch    = 5'(address[7:0] - 8'h68);
	assign pcm_keyon_val   = din[7];
	assign pcm_wavesel_stb = pcm_space && new2 && (address[7:0] >= 8'h08) && (address[7:0] <= 8'h1F);
	assign pcm_wavesel_ch  = 5'(address[7:0] - 8'h08);

	logic mem_kick;   // schedule a prefetch (address touched / data accessed)

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			address        <= 10'd0;
			timer_a_reg    <= 8'd0;
			timer_b_reg    <= 8'd0;
			{mask_a, mask_b, load_a, load_b} <= '0;
			{flag_a, flag_b} <= '0;
			new1           <= 1'b0;
			new2           <= 1'b0;
			next_status_id <= 1'b1;
			busy_cnt       <= 8'd0;
			ld_cnt         <= 4'd0;
			ld_sample_div  <= 10'd0;
			mem_buf        <= 8'd0;
			mem_pending    <= 1'b0;
			mem_kick       <= 1'b0;
			mem_rd_req     <= 1'b0;
			timer_a_cnt    <= 10'd0;
			timer_b_cnt    <= 12'd0;
			// register-file reset (the file is flops, not BRAM: it needs
			// multiple asynchronous read ports); F8 per the reference
			for (int i = 0; i < 256; i++) pcm_regs[i] <= (i == 'hF8) ? 8'h1B : 8'h00;
		end else begin
			mem_rd_req <= 1'b0;

			// prefetch scheduling FIRST, so a same-cycle mem_kick setter
			// below wins over this clear (NBA last-assignment-wins)
			if (mem_kick && !mem_pending) begin
				mem_kick    <= 1'b0;
				mem_pending <= 1'b1;
				mem_rd_req  <= 1'b1;
			end
			if (mem_pending && mem_rd_valid) begin
				mem_buf     <= mem_rd_data;
				mem_pending <= 1'b0;
			end

			// busy countdown in chip clocks
			if (chip_cen && busy) busy_cnt <= busy_cnt - 8'd1;

			// LD countdown in output samples (chip_cen/768)
			if (chip_cen && ld_cnt != 0) begin
				if (ld_sample_div == 10'd767) begin
					ld_sample_div <= 10'd0;
					ld_cnt         <= ld_cnt - 4'd1;
				end else ld_sample_div <= ld_sample_div + 10'd1;
			end

			// status ID consumed by the first read
			if (rd && addr == 3'd0) next_status_id <= 1'b0;

			// address writes
			if (wr && addr == 3'd0) address <= {2'b00, din};
			if (wr && addr == 3'd2) begin
				// YMF262-style: high bit masked in compat mode except 0x105
				if (!new1 && {2'b01, din} != 10'h105) address <= {2'b00, din};
				else                                     address <= {2'b01, din};
			end
			if (wr && addr == 3'd4) address <= {2'b10, din};

			// FM data writes: timers + NEW/NEW2; everything else dropped
			if (fm_space) begin
				busy_cnt <= 8'd56;
				case (address[8:0])
					9'h002: timer_a_reg <= din;
					9'h003: timer_b_reg <= din;
					9'h004: begin
						if (din[7]) begin
							{flag_a, flag_b} <= '0;   // RST clears flags only
						end else begin
							mask_a <= din[6];
							mask_b <= din[5];
							load_a <= din[0];
							load_b <= din[1];
							if (din[6]) flag_a <= 1'b0;   // masking also clears
							if (din[5]) flag_b <= 1'b0;
						end
					end
					9'h105: begin
						new1 <= din[0];
						if (din[1] && !new2) next_status_id <= 1'b1;
						new2 <= din[1];
					end
					default: ;
				endcase
			end

			// PCM data writes (gated on NEW2, like the reference)
			if (pcm_space && new2) begin
				busy_cnt <= 8'd88;
				if (address[7:0] == 8'h06 && mem_mode) begin
					// external memory WRITE not supported: the wave ROM is
					// SDRAM-resident and read-only in this system (the real
					// board has no wave SRAM either); autoincrement anyway
					{pcm_regs[8'h03][5:0], pcm_regs[8'h04], pcm_regs[8'h05]} <= mem_addr_cur + 22'd1;
					mem_kick <= 1'b1;
				end else begin
					pcm_regs[address[7:0]] <= din;
					if (address[7:0] >= 8'h02 && address[7:0] <= 8'h05) mem_kick <= 1'b1;
					if (address[7:0] >= 8'h08 && address[7:0] <= 8'h1F) ld_cnt <= 4'd13;
				end
			end

			// data-port READ consumes the buffer: autoincrement + refetch
			if (rd && addr == 3'd5 && address[9] && address[7:0] == 8'h06 && mem_mode) begin
				{pcm_regs[8'h03][5:0], pcm_regs[8'h04], pcm_regs[8'h05]} <= mem_addr_cur + 22'd1;
				mem_kick <= 1'b1;
			end

			// engine-side header-load writes (regs 0x80..0xF7 bands)
			if (pcm_hdr_we) pcm_regs[pcm_hdr_waddr] <= pcm_hdr_wdata;

			// ---- timers (FM-sample time base) ----
			if (fm_tick) begin
				if (load_a) begin
					if (timer_a_cnt == 10'd1023) begin
						timer_a_cnt <= {timer_a_reg, 2'b00};
						if (!mask_a) flag_a <= 1'b1;
					end else timer_a_cnt <= timer_a_cnt + 10'd1;
				end
				if (load_b) begin
					if (timer_b_cnt == 12'd4095) begin
						timer_b_cnt <= {timer_b_reg, 4'b0000};
						if (!mask_b) flag_b <= 1'b1;
					end else timer_b_cnt <= timer_b_cnt + 12'd1;
				end
			end
			// (re)arm counters when load bits are written
			if (fm_space && address[8:0] == 9'h004 && !din[7]) begin
				if (din[0] && !load_a) timer_a_cnt <= {timer_a_reg, 2'b00};
				if (din[1] && !load_b) timer_b_cnt <= {timer_b_reg, 4'b0000};
			end
		end
	end

endmodule
