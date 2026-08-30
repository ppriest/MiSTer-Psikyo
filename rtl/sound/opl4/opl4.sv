// YMF278B (OPL4) top level -- docs/phase2_ymf278b.md.
//
// Milestone 1: full bus protocol, status/ID/BUSY/LD, both timers with IRQ
// (the Z80 driver's sequencer heartbeat), and the 24-channel PCM
// wavetable engine (opl4_pcm.sv). FM synthesis is milestone 2: FM
// register writes are accepted (timers/NEW flags live in opl4_regs.sv)
// but produce no audio yet, so the FM term of the DO2 mix is zero.
//
// Clocking: one Bresenham enable reproduces the 33.8688 MHz chip clock
// exactly from the 945/11 MHz clk_sys (33.8688M * 11 / 945M = 8624/21875,
// zero error); the 44.1 kHz output-sample tick (/768) and the 49.515 kHz
// FM-sample tick (/684, the timer time base) both divide it, keeping
// audio and timers phase-locked like the real part.
//
// Output: the reference's DO2 mix applies s_mix_scale attenuators (PCM
// regs F8/F9) to the FM and PCM sums as (x * scale) >> 11. The PCM
// engine sums both of its output pairs (opl4_pcm.sv's header explains
// why), so the PCM attenuator here scales that combined sum.
module opl4 (
	input  logic        clk,
	input  logic        reset,

	// Z80-facing bus (from sound_cpu's I/O decode)
	input  logic        cs,
	input  logic        rd,
	input  logic        wr,
	input  logic [2:0] addr,
	input  logic [7:0] din,
	output logic [7:0] dout,
	output logic        irq_n,

	// wave ROM byte reads (SDRAM sample region, 22-bit = 4MB)
	output logic        mem_rd_req,
	output logic [21:0] mem_rd_addr,
	input  logic        mem_rd_valid,
	input  logic [7:0] mem_rd_data,

	output logic signed [15:0] snd_l,
	output logic signed [15:0] snd_r,

	// FM-usage instrumentation. Milestone 2 (FM synthesis) is only worth
	// building if these games actually drive the FM half: the PCM engine
	// alone already produces music, voices and effects on both s1945 and
	// tengai. dbg_fm_keyon is the decisive one -- an FM channel that is
	// never keyed on can never be heard, whatever else gets programmed.
	// FM/PCM selection is ymfm's own: bit 9 of the register address
	// (ymf278b::write_data vs write_data_pcm).
	output logic        dbg_fm_wr,      // any write to an FM register
	output logic        dbg_fm_keyon,   // FM key-on (regs B0-B8, bit 5)
	output logic        dbg_pcm_keyon   // PCM key-on, for comparison
);

	// ---- chip clock enable: 33.8688 MHz from 945/11 MHz, exact ----
	logic [14:0] cen_acc;
	logic         chip_cen;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			cen_acc  <= 15'd0;
			chip_cen <= 1'b0;
		end else if (cen_acc + 15'd8624 >= 15'd21875) begin
			cen_acc  <= 15'(cen_acc + 15'd8624 - 15'd21875);
			chip_cen <= 1'b1;
		end else begin
			cen_acc  <= cen_acc + 15'd8624;
			chip_cen <= 1'b0;
		end
	end

	logic [9:0] div768, div684;
	logic        sample_tick, fm_tick;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			div768 <= 10'd0;
			div684 <= 10'd0;
			sample_tick <= 1'b0;
			fm_tick      <= 1'b0;
		end else begin
			sample_tick <= 1'b0;
			fm_tick      <= 1'b0;
			if (chip_cen) begin
				if (div768 == 10'd767) begin div768 <= 10'd0; sample_tick <= 1'b1; end
				else div768 <= div768 + 10'd1;
				if (div684 == 10'd683) begin div684 <= 10'd0; fm_tick <= 1'b1; end
				else div684 <= div684 + 10'd1;
			end
		end
	end

	// ---- bus strobe shaping ----
	// sound_cpu's ym_rd/ym_wr are LEVELS held for the whole Z80 I/O cycle
	// (many clk_sys cycles at the Z80's 4 MHz enable); the register block
	// needs one-cycle strobes or a data-port read would autoincrement
	// once per clock instead of once per access.
	logic rd_d, wr_d;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) {rd_d, wr_d} <= '0;
		else        {rd_d, wr_d} <= {cs & rd, cs & wr};
	end
	wire rd_stb = cs & rd & ~rd_d;
	wire wr_stb = cs & wr & ~wr_d;

	// ---- register block ----
	logic [7:0] pcm_raddr, pcm_rdata;
	logic        pcm_hdr_we;
	logic [7:0] pcm_hdr_waddr, pcm_hdr_wdata;
	logic        keyon_stb, keyon_val, wavesel_stb;
	logic [4:0] keyon_ch, wavesel_ch;
	logic        new2;
	logic        rw_mem_req, rw_mem_valid;
	logic [21:0] rw_mem_addr;

	opl4_regs u_regs (
		.clk(clk), .reset(reset), .chip_cen(chip_cen), .fm_tick(fm_tick),
		.addr(addr), .rd(rd_stb), .wr(wr_stb), .din(din), .dout(dout),
		.irq_n(irq_n),
		.pcm_raddr(pcm_raddr), .pcm_rdata(pcm_rdata),
		.pcm_hdr_we(pcm_hdr_we), .pcm_hdr_waddr(pcm_hdr_waddr), .pcm_hdr_wdata(pcm_hdr_wdata),
		.pcm_keyon_stb(keyon_stb), .pcm_keyon_ch(keyon_ch), .pcm_keyon_val(keyon_val),
		.pcm_wavesel_stb(wavesel_stb), .pcm_wavesel_ch(wavesel_ch),
		.new2(new2),
		.mem_rd_req(rw_mem_req), .mem_rd_addr(rw_mem_addr),
		.mem_rd_valid(rw_mem_valid), .mem_rd_data(mem_rd_data)
	);

	// wave-table-header bank bits live in PCM reg 02; the engine reads
	// them through its own dedicated wire to avoid stealing the read port
	logic [2:0] wave_bank;
	logic reg02_sel;
	logic [9:0] addr_shadow;
	// (peek via the regfile read port during idle would race the engine's
	// own sequencing; opl4_regs exposes the register file only through
	// that port, so the bank is snooped from writes instead)
	always_ff @(posedge clk or posedge reset) begin
		if (reset) wave_bank <= 3'd0;
		else if (wr_stb && addr == 3'd5 && new2 && reg02_sel) wave_bank <= din[4:2];
	end
	// address-register shadow purely for the bank snoop
	always_ff @(posedge clk or posedge reset) begin
		if (reset) addr_shadow <= 10'd0;
		else if (wr_stb) begin
			case (addr)
				3'd0: addr_shadow <= {2'b00, din};
				3'd2: addr_shadow <= {2'b01, din};
				3'd4: addr_shadow <= {2'b10, din};
				default: ;
			endcase
		end
	end
	assign reg02_sel = addr_shadow[9] && (addr_shadow[7:0] == 8'h02);

	// ---- FM-usage instrumentation (see the port comments) ----
	// FM data ports are offsets 1 and 3; offset 5 is the PCM data port.
	// addr_shadow[9] is set only by write_address_pcm (offset 4), so a
	// clear bit 9 means the pending register is an FM one.
	wire fm_data_wr = wr_stb && ((addr == 3'd1) || (addr == 3'd3)) && !addr_shadow[9];
	assign dbg_fm_wr    = fm_data_wr;
	assign dbg_fm_keyon = fm_data_wr && (addr_shadow[7:0] >= 8'hB0)
	                                  && (addr_shadow[7:0] <= 8'hB8) && din[5];
	assign dbg_pcm_keyon = keyon_stb && keyon_val;

	// ---- PCM engine ----
	logic        pcm_mem_req, pcm_mem_valid;
	logic [21:0] pcm_mem_addr;
	logic signed [15:0] pcm_l, pcm_r;

	opl4_pcm u_pcm (
		.clk(clk), .reset(reset), .sample_tick(sample_tick),
		.pcm_raddr(pcm_raddr), .pcm_rdata(pcm_rdata),
		.pcm_hdr_we(pcm_hdr_we), .pcm_hdr_waddr(pcm_hdr_waddr), .pcm_hdr_wdata(pcm_hdr_wdata),
		.keyon_stb(keyon_stb), .keyon_ch(keyon_ch), .keyon_val(keyon_val),
		.wavesel_stb(wavesel_stb), .wavesel_ch(wavesel_ch),
		.wave_table_bank(wave_bank),
		.mem_rd_req(pcm_mem_req), .mem_rd_addr(pcm_mem_addr),
		.mem_rd_valid(pcm_mem_valid), .mem_rd_data(mem_rd_data),
		.pcm_l(pcm_l), .pcm_r(pcm_r)
	);

	// ---- wave ROM read arbitration (engine wins; one in flight) ----
	logic owner_rw;   // 0 = pcm engine owns the in-flight read, 1 = reg window
	logic busy_mem;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			busy_mem  <= 1'b0;
			owner_rw  <= 1'b0;
			mem_rd_req <= 1'b0;
			mem_rd_addr <= 22'd0;
		end else begin
			mem_rd_req <= 1'b0;
			if (!busy_mem) begin
				if (pcm_mem_req) begin
					busy_mem   <= 1'b1;
					owner_rw   <= 1'b0;
					mem_rd_req <= 1'b1;
					mem_rd_addr <= pcm_mem_addr;
				end else if (rw_mem_req) begin
					busy_mem   <= 1'b1;
					owner_rw   <= 1'b1;
					mem_rd_req <= 1'b1;
					mem_rd_addr <= rw_mem_addr;
				end
			end else if (mem_rd_valid) begin
				busy_mem <= 1'b0;
			end
		end
	end
	assign pcm_mem_valid = busy_mem && !owner_rw && mem_rd_valid;
	assign rw_mem_valid  = busy_mem &&  owner_rw && mem_rd_valid;

	// ---- output mix (DO2 attenuators; FM term zero in milestone 1) ----
	// s_mix_scale from the reference; F9 (PCM) resets to 0 -> full scale.
	function automatic [11:0] mix_scale(input [2:0] v);
		case (v)
			3'd0: mix_scale = 12'h7FA; 3'd1: mix_scale = 12'h5A4;
			3'd2: mix_scale = 12'h3FD; 3'd3: mix_scale = 12'h2D2;
			3'd4: mix_scale = 12'h1FE; 3'd5: mix_scale = 12'h169;
			3'd6: mix_scale = 12'h0FF; default: mix_scale = 12'h000;
		endcase
	endfunction

	// PCM mix control (reg F9) snooped the same way as the bank bits
	logic [5:0] mix_pcm;   // {r[2:0], l[2:0]}
	wire regF9_sel = addr_shadow[9] && (addr_shadow[7:0] == 8'hF9);
	always_ff @(posedge clk or posedge reset) begin
		if (reset) mix_pcm <= 6'd0;
		else if (wr_stb && addr == 3'd5 && new2 && regF9_sel) mix_pcm <= din[5:0];
	end

	logic signed [27:0] mix_l, mix_r;
	always_ff @(posedge clk) begin
		mix_l <= pcm_l * $signed({1'b0, mix_scale(mix_pcm[2:0])});
		mix_r <= pcm_r * $signed({1'b0, mix_scale(mix_pcm[5:3])});
		snd_l <= 16'(mix_l >>> 11);
		snd_r <= 16'(mix_r >>> 11);
	end

endmodule
