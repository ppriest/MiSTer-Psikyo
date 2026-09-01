// YMF278B (OPL4) 24-channel PCM wavetable engine.
//
// Direct translation of MAME's ymfm reference implementation
// (3rdparty/ymfm: ymfm_pcm.cpp/h, pcm_channel/pcm_engine) -- the register
// semantics, envelope math, pitch step, LFO depths and mixing all follow
// that code, which is this project's accuracy target. See
// docs/phase2_sh404.md ("SH404 audio").
//
// Time structure: one output sample per sample_tick (chip/768 = 44.1kHz).
// Each sample walks the 24 channels sequentially; a channel slot reads
// its registers through the single regfile read port (opl4_regs.sv),
// clocks key state / envelope / LFO / position, fetches 1-2 sample bytes
// from the wave ROM (SDRAM, via the shared mem port) and accumulates the
// panned output. Quiet released channels early-out after two register
// reads, so the walk fits the ~1948-clk budget comfortably in practice;
// if a pathological all-channels-active sample overruns, the next tick
// is simply taken late (sample stretching, inaudible at this scale).
//
// Wavetable loads (writes to regs 0x08-0x1F) run a 12-byte header fetch
// FSM between channel slots, exactly the reference's load_wavetable():
// base address/format/loop/end from bytes 0-6, bytes 7-11 written back
// into the channel's registers 0x80/0x98/0xB0/0xC8/0xE0.
module opl4_pcm (
	input  logic        clk,
	input  logic        reset,
	input  logic        sample_tick,   // pulse: produce one output sample

	// register file access (opl4_regs.sv)
	output logic [7:0] pcm_raddr,
	input  logic [7:0] pcm_rdata,
	output logic        pcm_hdr_we,
	output logic [7:0] pcm_hdr_waddr,
	output logic [7:0] pcm_hdr_wdata,

	// notifications from the bus side
	input  logic        keyon_stb,
	input  logic [4:0] keyon_ch,
	input  logic        keyon_val,
	input  logic        wavesel_stb,
	input  logic [4:0] wavesel_ch,
	input  logic [2:0] wave_table_bank,   // PCM reg 02 bits 4:2

	// wave ROM (byte reads; opl4.sv arbitrates with the reg window port)
	output logic        mem_rd_req,
	output logic [21:0] mem_rd_addr,
	input  logic        mem_rd_valid,
	input  logic [7:0] mem_rd_data,

	// accumulated stereo PCM output, updated once per sample
	output logic signed [15:0] pcm_l,
	output logic signed [15:0] pcm_r
);

	// ---- constant tables (values from ymfm) ----
	// attenuation increment: 64 rates x 8 steps of 4 bits
	logic [31:0] inc_table [0:63];
	initial begin
		inc_table[ 0]='h00000000; inc_table[ 1]='h00000000; inc_table[ 2]='h10101010; inc_table[ 3]='h10101010;
		inc_table[ 4]='h10101010; inc_table[ 5]='h10101010; inc_table[ 6]='h11101110; inc_table[ 7]='h11101110;
		inc_table[ 8]='h10101010; inc_table[ 9]='h10111010; inc_table[10]='h11101110; inc_table[11]='h11111110;
		inc_table[12]='h10101010; inc_table[13]='h10111010; inc_table[14]='h11101110; inc_table[15]='h11111110;
		inc_table[16]='h10101010; inc_table[17]='h10111010; inc_table[18]='h11101110; inc_table[19]='h11111110;
		inc_table[20]='h10101010; inc_table[21]='h10111010; inc_table[22]='h11101110; inc_table[23]='h11111110;
		inc_table[24]='h10101010; inc_table[25]='h10111010; inc_table[26]='h11101110; inc_table[27]='h11111110;
		inc_table[28]='h10101010; inc_table[29]='h10111010; inc_table[30]='h11101110; inc_table[31]='h11111110;
		inc_table[32]='h10101010; inc_table[33]='h10111010; inc_table[34]='h11101110; inc_table[35]='h11111110;
		inc_table[36]='h10101010; inc_table[37]='h10111010; inc_table[38]='h11101110; inc_table[39]='h11111110;
		inc_table[40]='h10101010; inc_table[41]='h10111010; inc_table[42]='h11101110; inc_table[43]='h11111110;
		inc_table[44]='h10101010; inc_table[45]='h10111010; inc_table[46]='h11101110; inc_table[47]='h11111110;
		inc_table[48]='h11111111; inc_table[49]='h21112111; inc_table[50]='h21212121; inc_table[51]='h22212221;
		inc_table[52]='h22222222; inc_table[53]='h42224222; inc_table[54]='h42424242; inc_table[55]='h44424442;
		inc_table[56]='h44444444; inc_table[57]='h84448444; inc_table[58]='h84848484; inc_table[59]='h88848884;
		inc_table[60]='h88888888; inc_table[61]='h88888888; inc_table[62]='h88888888; inc_table[63]='h88888888;
	end

	// power (exp) table: attenuation_to_volume = pow[input[7:0]] >> input[12:8]
	logic [12:0] pow_table [0:255];
	// path is project-root-relative for Quartus; testbenches mirror it
	// under their own directory (sim/opl4_tb/rtl/...)
	initial $readmemh("rtl/sound/opl4/opl4_pow_table.hex", pow_table);

	// LFO step / AM depth / PM depth per the reference
	function automatic [5:0] lfo_step_f(input [2:0] spd);
		case (spd)
			3'd0: lfo_step_f = 6'd1;  3'd1: lfo_step_f = 6'd12; 3'd2: lfo_step_f = 6'd19;
			3'd3: lfo_step_f = 6'd25; 3'd4: lfo_step_f = 6'd31; 3'd5: lfo_step_f = 6'd35;
			3'd6: lfo_step_f = 6'd37; default: lfo_step_f = 6'd42;
		endcase
	endfunction
	function automatic [7:0] am_depth_f(input [2:0] d);
		case (d)
			3'd0: am_depth_f = 8'h00; 3'd1: am_depth_f = 8'h14; 3'd2: am_depth_f = 8'h20;
			3'd3: am_depth_f = 8'h28; 3'd4: am_depth_f = 8'h30; 3'd5: am_depth_f = 8'h40;
			3'd6: am_depth_f = 8'h50; default: am_depth_f = 8'h80;
		endcase
	endfunction
	function automatic [5:0] pm_depth_f(input [2:0] d);
		case (d)
			3'd0: pm_depth_f = 6'd0;  3'd1: pm_depth_f = 6'd2;  3'd2: pm_depth_f = 6'd3;
			3'd3: pm_depth_f = 6'd4;  3'd4: pm_depth_f = 6'd6;  3'd5: pm_depth_f = 6'd12;
			3'd6: pm_depth_f = 6'd24; default: pm_depth_f = 6'd48;
		endcase
	endfunction

	// effective envelope rate: 0->0, 15->63, else raw*4+correction clamped
	function automatic [5:0] eff_rate(input [3:0] raw, input [5:0] corr);
		logic [7:0] r;
		if (raw == 4'd0)       eff_rate = 6'd0;
		else if (raw == 4'd15) eff_rate = 6'd63;
		else begin
			r = {2'b00, raw, 2'b00} + {2'b00, corr};
			eff_rate = (r > 8'd63) ? 6'd63 : r[5:0];
		end
	endfunction

	// envelope states (ymfm ordering)
	localparam [2:0] EG_ATTACK = 3'd1, EG_DECAY = 3'd2, EG_SUSTAIN = 3'd3,
	                  EG_RELEASE = 3'd4, EG_REVERB = 3'd5;
	localparam [9:0] EG_QUIET = 10'h200;

	// ---- per-channel state ----
	logic [21:0] ch_baseaddr  [0:23];
	logic [1:0]  ch_format    [0:23];
	logic [15:0] ch_loop      [0:23];   // loop position (integer part)
	logic [15:0] ch_end       [0:23];   // end position (integer part, already negated)
	logic [31:0] ch_nextpos   [0:23];   // .16 sample position
	logic [17:0] ch_lfo       [0:23];
	logic [2:0]  ch_eg_state  [0:23];
	logic [9:0]  ch_env       [0:23];
	logic [16:0] ch_tl        [0:23];   // interpolated total level, 7.10
	logic [2:0]  ch_key       [0:23];   // {PENDING, PENDING_ON, ON}

	// ---- shared engine state ----
	logic [23:0] env_counter;

	// ---- key-on notifications (processed at the channel's next slot) ----
	logic        key_consume;
	logic [4:0] key_ch;
	logic        key_new_on;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			for (int i = 0; i < 24; i++) ch_key[i] <= 3'b000;
		end else if (keyon_stb) begin
			ch_key[keyon_ch][2] <= 1'b1;           // PENDING
			ch_key[keyon_ch][1] <= keyon_val;      // PENDING_ON
		end else if (key_consume) begin
			ch_key[key_ch] <= {1'b0, 1'b0, key_new_on};
		end
	end

	// ---- wavetable-load queue (one pending; writes arrive far apart) ----
	logic        load_pending;
	logic [4:0] load_ch;

	// ---- engine FSM ----
	typedef enum logic [4:0] {
		S_IDLE, S_RD0, S_RD1, S_RD2, S_RD3, S_RD4, S_RD5, S_RD6, S_RD7, S_RD8,
		S_CALC, S_ENV, S_ENV2, S_ENV3, S_FETCH0, S_FETCH1, S_OUT, S_OUT2, S_NEXT, S_DONE,
		S_HDR_REQ, S_HDR_WAIT
	} state_t;
	state_t state;

	logic [4:0]  ch;                 // current channel in the walk
	logic        tick_pending;

	// cached per-channel register fields for the slot in progress
	logic [9:0]  c_fnum;
	logic signed [3:0] c_oct;
	logic        c_reverb;
	logic [6:0]  c_tl_reg;
	logic        c_lvl_direct;
	logic        c_damp, c_lfo_reset;
	logic        c_out_ch;
	logic signed [3:0] c_pan;
	logic [2:0]  c_lfo_spd, c_vib, c_amd;
	logic [3:0]  c_ar, c_dr, c_sl, c_sr, c_rc, c_rr;
	// Loop/end points, cached like every other per-channel field. They are NOT
	// register-file values -- they come from the sample header at key-on and
	// are constant for the note -- but reading them as ch_end[ch]/ch_loop[ch]
	// inside S_ENV put two 24:1 muxes, selected by the slot index, in series
	// with the 32-bit wrap compare and its two 32-bit adds. Once the sprite
	// path was retimed that became the entire failing-path population of the
	// design (235 paths, ch -> ch_nextpos). Latched in S_RD8, two states
	// before use, matching the other c_* fields.
	logic [15:0] c_end, c_loop;

	// slot working values
	logic [31:0] w_step, w_curpos;
	logic [9:0]  w_env;
	logic [2:0]  w_state_eg;
	logic [17:0] w_lfo;
	logic signed [15:0] w_sample;
	logic [7:0]  w_byte0;

	// hoisted FSM scratch (Quartus 17 dislikes unnamed-block declarations)
	logic [8:0]  hs_wavnum;
	logic [21:0] hs_base;
	// Pipeline registers splitting the two deep stages. Both were single-cycle
	// and both dominated clk_sys: the envelope chain
	//   c_rc/c_oct -> corr -> eff_rate -> cur_rate -> eg_inc -> es_env_next
	// and the output chain
	//   c_amd -> am_depth_f -> (* lfo_tri) -> att2vol -> (* w_sample) -> acc
	// each ran table lookups and a multiply in one clock. The slot machine has
	// roughly 1948 clk per sample and uses a few hundred, so an extra state per
	// stage costs 48 cycles per sample and buys the whole path.
	logic [5:0]  p_rate;        // cur_rate, registered
	logic [3:0]  p_eg_inc;      // eg_inc, registered
	logic        p_frac_zero;
	logic [12:0] p_lvol, p_rvol; // att2vol results, registered
	logic [9:0]  p_am;           // AM attenuation, registered in S_ENV
	logic [9:0]  p_env_next;     // next envelope level, registered in S_ENV2
	logic [2:0]  p_st_next;      // next EG state, likewise
	logic [9:0]  es_env_next, es_dec;
	logic [2:0]  es_st_next;
	logic [31:0] es_np;
	logic [10:0] os_lenv, os_renv;
	logic [10:0] p_env_eff;      // envelope+AM+TL sum, registered in S_FETCH
	logic [12:0] os_lvol, os_rvol;
	logic signed [28:0] os_lmul, os_rmul;

	// header-load working state
	logic [3:0]  hdr_idx;
	logic [21:0] hdr_addr;
	logic [7:0]  hdr_bytes [0:6];

	// output accumulators (sum of both DO1 and DO2 pairs -- this board has
	// one DAC on the mixed output and the games route everything there;
	// summing both pairs avoids muting a channel the driver routes to DO1)
	logic signed [19:0] acc_l, acc_r;

	// ---- derived slot math ----
	// pitch step: ((0x400|fnum) << (oct+7)) >> 2 as a .16 value; 0x400 is
	// bit 10, above fnum's 10 bits, so the OR is a plain concatenation.
	// Net shift is oct+5 in [-3..12]; realized as <<(oct+8) then >>3 so
	// the barrel shift amount stays unsigned.
	wire [3:0] shamt = 4'(c_oct + 4'sd8);                   // 0..15
	wire [31:0] step_exact = ({21'd0, 1'b1, c_fnum} << shamt) >> 3;

	// envelope rate correction: 15 -> none, else (oct+corr)*2 + fnum[9]
	wire signed [5:0] rc_sum = {{2{c_oct[3]}}, c_oct} + {2'b00, c_rc};
	wire [5:0] corr = (c_rc == 4'd15) ? 6'd0
	                 : {rc_sum[4:0], c_fnum[9]};

	// sustain level: 4 bits, 15 extends to 31, then <<5 (10-bit units)
	wire [9:0] sl_val = {(c_sl == 4'd15) ? 5'd31 : {1'b0, c_sl}, 5'b00000};

	// per-state effective rates (damp overrides per the reference)
	function automatic [5:0] slot_rate(input [2:0] st);
		case (st)
			EG_ATTACK:  slot_rate = eff_rate(c_ar, corr);
			EG_DECAY:   slot_rate = c_damp ? 6'd48 : eff_rate(c_dr, corr);
			EG_SUSTAIN: slot_rate = c_damp ? 6'd63 : eff_rate(c_sr, corr);
			EG_REVERB:  slot_rate = 6'd5;
			default:     slot_rate = c_damp ? 6'd63 : eff_rate(c_rr, corr);
		endcase
	endfunction
	wire [9:0] eg_sustain = c_damp ? 10'h080 : sl_val;

	// envelope clocking math (ymfm clock_envelope, env_counter>>1 domain)
	wire [22:0] envc = env_counter[23:1];
	wire [5:0]  cur_rate = slot_rate(w_state_eg);
	wire [3:0]  rate_shift = cur_rate[5:2];

	// (B) rate_shift selects one of only twelve shift distances, so what used
	// to be two 23-bit barrel shifts of envc is a constant slice and a constant
	// mask. Same values, a fraction of the logic, no extra cycle.
	logic       frac_zero;
	logic [2:0] relevant;
	always_comb begin
		case (rate_shift)
			4'd0:  begin relevant = envc[13:11]; frac_zero = (envc[10:0] == 11'd0); end
			4'd1:  begin relevant = envc[12:10]; frac_zero = (envc[9:0]  == 10'd0); end
			4'd2:  begin relevant = envc[11:9];  frac_zero = (envc[8:0]  ==  9'd0); end
			4'd3:  begin relevant = envc[10:8];  frac_zero = (envc[7:0]  ==  8'd0); end
			4'd4:  begin relevant = envc[9:7];   frac_zero = (envc[6:0]  ==  7'd0); end
			4'd5:  begin relevant = envc[8:6];   frac_zero = (envc[5:0]  ==  6'd0); end
			4'd6:  begin relevant = envc[7:5];   frac_zero = (envc[4:0]  ==  5'd0); end
			4'd7:  begin relevant = envc[6:4];   frac_zero = (envc[3:0]  ==  4'd0); end
			4'd8:  begin relevant = envc[5:3];   frac_zero = (envc[2:0]  ==  3'd0); end
			4'd9:  begin relevant = envc[4:2];   frac_zero = (envc[1:0]  ==  2'd0); end
			4'd10: begin relevant = envc[3:1];   frac_zero = (envc[0]    ==  1'b0); end
			// rate_shift >= 11: no fractional bits left to test, and the shift
			// distance is zero.
			default: begin relevant = envc[2:0]; frac_zero = 1'b1; end
		endcase
	end

	// (A) inc_table[cur_rate] >> {relevant,2'b00} was selecting nibble
	// `relevant` of a 32-bit word -- a 64:1 mux feeding a 32-bit barrel shift.
	// Split into the word mux and an explicit 8:1 nibble mux, which is the same
	// 512:1 selection expressed as logic Quartus can build cheaply. Written as
	// a case rather than a 512-entry array on purpose: an array that size
	// invites M10K inference, and the design has none spare (553/553).
	wire [31:0] inc_word = inc_table[cur_rate];
	logic [3:0] eg_inc;
	always_comb begin
		case (relevant)
			3'd0: eg_inc = inc_word[3:0];
			3'd1: eg_inc = inc_word[7:4];
			3'd2: eg_inc = inc_word[11:8];
			3'd3: eg_inc = inc_word[15:12];
			3'd4: eg_inc = inc_word[19:16];
			3'd5: eg_inc = inc_word[23:20];
			3'd6: eg_inc = inc_word[27:24];
			3'd7: eg_inc = inc_word[31:28];
		endcase
	end

	// LFO is clocked and THEN consumed within the same sample (the
	// reference increments m_lfo_counter at the top of clock() and uses
	// the updated value for both PM and, later, AM) -- so PM math runs on
	// the freshly stepped value, and w_lfo carries it to the output stage.
	wire [17:0] lfo_upd = ch_lfo[ch] + {12'd0, lfo_step_f(c_lfo_spd)};

	// AM (output stage, from w_lfo = the updated counter)
	wire [6:0] lfo_tri = w_lfo[17] ? ~w_lfo[16:10] : w_lfo[16:10];
	wire [9:0] am_add = 10'((lfo_tri * am_depth_f(c_amd)) >> 7);
	// PM: quarter-cycle-shifted updated LFO, signed -0x40..0x3F
	// Fed from w_lfo (registered in S_CALC), not lfo_upd, so the 24-entry
	// ch_lfo[ch] mux is not in series with the PM multiply. Same value --
	// w_lfo IS lfo_upd, one state later -- but the path starts at a
	// register instead of at ch. See S_ENV.
	wire [17:0] lfo_sh = w_lfo + 18'h10000;
	wire [6:0] pm_tri = lfo_sh[17] ? ~lfo_sh[16:10] : lfo_sh[16:10];
	wire signed [7:0] pm_val = {1'b0, pm_tri} - 8'sd64;
	wire signed [13:0] pm_add = (pm_val * $signed({1'b0, pm_depth_f(c_vib)})) >>> 7;

	function automatic [9:0] pan_att_l(input signed [3:0] pan);
		if (pan >= 0)         pan_att_l = (pan == 4'sd7) ? 10'h3FF : 10'(pan) << 5;
		else                   pan_att_l = 10'd0;
	endfunction
	function automatic [9:0] pan_att_r(input signed [3:0] pan);
		if (pan <= 0 && pan >= -4'sd7) pan_att_r = (pan == -4'sd7) ? 10'h3FF : 10'(-pan) << 5;
		else if (pan > 0)               pan_att_r = 10'd0;
		else                             pan_att_r = 10'h3FF;   // pan == -8
	endfunction
	// pan == -8: both sides fully attenuated per the reference
	wire [9:0] pan_l = (c_pan == -4'sd8) ? 10'h3FF : pan_att_l(c_pan);
	wire [9:0] pan_r = (c_pan == -4'sd8) ? 10'h3FF : pan_att_r(c_pan);

	function automatic [12:0] att2vol(input [12:0] att);
		att2vol = pow_table[att[7:0]] >> att[12:8];
	endfunction

	// ---- main FSM ----
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state        <= S_IDLE;
			ch           <= 5'd0;
			tick_pending <= 1'b0;
			env_counter  <= 24'd0;
			acc_l        <= '0;
			acc_r        <= '0;
			pcm_l        <= '0;
			pcm_r        <= '0;
			pcm_raddr    <= 8'd0;
			pcm_hdr_we   <= 1'b0;
			mem_rd_req   <= 1'b0;
			load_pending <= 1'b0;
			load_ch      <= 5'd0;
			key_consume  <= 1'b0;
			hdr_idx      <= 4'd0;
			for (int i = 0; i < 24; i++) begin
				ch_baseaddr[i] <= '0;   ch_format[i] <= '0;
				ch_loop[i]      <= '0;   ch_end[i]     <= '0;
				ch_nextpos[i]  <= '0;   ch_lfo[i]     <= '0;
				ch_eg_state[i] <= EG_RELEASE;
				ch_env[i]       <= 10'h3FF;
				ch_tl[i]        <= {7'h7F, 10'd0};
			end
		end else begin
			pcm_hdr_we  <= 1'b0;
			mem_rd_req  <= 1'b0;
			key_consume <= 1'b0;

			if (sample_tick) tick_pending <= 1'b1;
			if (wavesel_stb) begin
				load_pending <= 1'b1;
				load_ch      <= wavesel_ch;
			end

			case (state)
				S_IDLE: begin
					if (load_pending) begin
						// header base: 12*wavnum, banked above wave 384
						state    <= S_RD0;   // reuse RD0 to read the two wavenum regs
						ch       <= load_ch;
						hdr_idx  <= 4'd15;   // marker: reading wavenum, not fields
						pcm_raddr <= 8'h08 + {3'd0, load_ch};
					end else if (tick_pending) begin
						tick_pending <= 1'b0;
						env_counter  <= env_counter + 24'd1;
						acc_l        <= '0;
						acc_r        <= '0;
						ch           <= 5'd0;
						state        <= S_RD1;
						pcm_raddr    <= 8'h68 + 8'd0;      // keyon reg first
					end
				end

				// ---- wavetable number read (header load path) ----
				S_RD0: begin
					w_byte0   <= pcm_rdata;                 // wave num low
					pcm_raddr <= 8'h20 + {3'd0, ch};
					state     <= S_HDR_REQ;
				end
				S_HDR_REQ: begin
					// compute header address: 12*wavnum (+bank window)
					hs_wavnum = {pcm_rdata[0], w_byte0};
					hs_base   = 22'(hs_wavnum) * 22'd12;
					if (hs_wavnum >= 9'd384 && wave_table_bank != 3'd0)
						hs_base = (22'(wave_table_bank) << 19) + (22'(hs_wavnum - 9'd384) * 22'd12);
					hdr_addr    <= hs_base;
					hdr_idx     <= 4'd0;
					mem_rd_req  <= 1'b1;
					mem_rd_addr <= hs_base;
					state       <= S_HDR_WAIT;
				end
				S_HDR_WAIT: if (mem_rd_valid) begin
					if (hdr_idx <= 4'd6) hdr_bytes[hdr_idx[2:0]] <= mem_rd_data;
					else begin
						// bytes 7-11 write channel registers directly
						pcm_hdr_we     <= 1'b1;
						pcm_hdr_wdata <= mem_rd_data;
						case (hdr_idx)
							4'd7:  pcm_hdr_waddr <= 8'h80 + {3'd0, ch};
							4'd8:  pcm_hdr_waddr <= 8'h98 + {3'd0, ch};
							4'd9:  pcm_hdr_waddr <= 8'hB0 + {3'd0, ch};
							4'd10: pcm_hdr_waddr <= 8'hC8 + {3'd0, ch};
							default: pcm_hdr_waddr <= 8'hE0 + {3'd0, ch};
						endcase
					end
					if (hdr_idx == 4'd11) begin
						// commit decoded fields
						ch_format[ch]    <= hdr_bytes[0][7:6];
						ch_baseaddr[ch] <= {hdr_bytes[0][5:0], hdr_bytes[1], hdr_bytes[2]};
						ch_loop[ch]      <= {hdr_bytes[3], hdr_bytes[4]};
						ch_end[ch]       <= 16'd0 - {hdr_bytes[5], hdr_bytes[6]};
						ch_env[ch]       <= 10'h3FF;
						load_pending     <= 1'b0;
						state            <= S_IDLE;
					end else begin
						hdr_idx     <= hdr_idx + 4'd1;
						mem_rd_req  <= 1'b1;
						mem_rd_addr <= hdr_addr + 22'(hdr_idx) + 22'd1;
					end
				end

				// ---- channel slot: gather registers ----
				// RD1 keyon/damp/pan, RD2 fnum hi/oct, RD3 fnum lo/wave hi,
				// RD4 TL, RD5 LFO/vib, RD6 AR/DR, RD7 SL/SR, RD8 RC/RR (+AM)
				S_RD1: begin
					{c_damp, c_lfo_reset, c_out_ch} <= pcm_rdata[6:4];
					c_pan <= pcm_rdata[3:0];
					// key handling: consume pending transition now
					if (ch_key[ch][2]) begin
						key_consume <= 1'b1;
						key_ch       <= ch;
						key_new_on  <= ch_key[ch][1];
						if (ch_key[ch][1] && !ch_key[ch][0]) begin
							// key on: start attack
							if (ch_eg_state[ch] != EG_ATTACK) begin
								ch_eg_state[ch] <= EG_ATTACK;
								ch_nextpos[ch]  <= 32'd0;
							end
						end else if (!ch_key[ch][1] && ch_key[ch][0]) begin
							if (ch_eg_state[ch] < EG_RELEASE) ch_eg_state[ch] <= EG_RELEASE;
						end
					end
					// quiet early-out: released and silent -> skip the rest
					if (!ch_key[ch][2] && ch_eg_state[ch] >= EG_RELEASE
					     && ch_env[ch] >= EG_QUIET) begin
						state <= S_NEXT;
					end else begin
						pcm_raddr <= 8'h38 + {3'd0, ch};
						state     <= S_RD2;
					end
				end
				S_RD2: begin
					c_oct       <= pcm_rdata[7:4];
					c_reverb    <= pcm_rdata[3];
					c_fnum[9:7] <= pcm_rdata[2:0];
					pcm_raddr   <= 8'h20 + {3'd0, ch};
					state       <= S_RD3;
				end
				S_RD3: begin
					c_fnum[6:0] <= pcm_rdata[7:1];
					pcm_raddr   <= 8'h50 + {3'd0, ch};
					state       <= S_RD4;
				end
				S_RD4: begin
					c_tl_reg     <= pcm_rdata[7:1];
					c_lvl_direct <= pcm_rdata[0];
					pcm_raddr    <= 8'h80 + {3'd0, ch};
					state        <= S_RD5;
				end
				S_RD5: begin
					c_lfo_spd <= pcm_rdata[5:3];
					c_vib      <= pcm_rdata[2:0];
					pcm_raddr <= 8'h98 + {3'd0, ch};
					state      <= S_RD6;
				end
				S_RD6: begin
					c_ar       <= pcm_rdata[7:4];
					c_dr       <= pcm_rdata[3:0];
					pcm_raddr <= 8'hB0 + {3'd0, ch};
					state      <= S_RD7;
				end
				S_RD7: begin
					c_sl       <= pcm_rdata[7:4];
					c_sr       <= pcm_rdata[3:0];
					pcm_raddr <= 8'hC8 + {3'd0, ch};
					state      <= S_RD8;
				end
				S_RD8: begin
					c_rc       <= pcm_rdata[7:4];
					c_rr       <= pcm_rdata[3:0];
					c_end      <= ch_end[ch];
					c_loop     <= ch_loop[ch];
					pcm_raddr <= 8'hE0 + {3'd0, ch};
					state      <= S_CALC;
				end

				// ---- clock LFO/position, then envelope ----
				S_CALC: begin
					c_amd     <= pcm_rdata[2:0];
					w_lfo      <= lfo_upd;
					w_env      <= ch_env[ch];
					w_state_eg <= ch_eg_state[ch];
					// attack->decay / decay->sustain transitions (pre-rate)
					if (ch_eg_state[ch] == EG_ATTACK && ch_env[ch] == 10'd0)
						w_state_eg <= EG_DECAY;
					else if (ch_eg_state[ch] == EG_DECAY && ch_env[ch] >= eg_sustain)
						w_state_eg <= EG_SUSTAIN;
					// position advance with vibrato and loop wrap
					w_curpos <= ch_nextpos[ch];
					state     <= S_ENV;
				end
				// Register the rate chain (corr -> eff_rate -> cur_rate -> eg_inc)
				// so S_ENV2's arithmetic does not sit behind it in one clock.
				S_ENV: begin
					p_rate      <= cur_rate;
					p_eg_inc    <= eg_inc;
					p_frac_zero <= frac_zero;
					// Pitch step lands here rather than in S_CALC. In S_CALC it
					// ran ch -> ch_lfo[ch] mux -> add -> shift -> invert -> sub
					// -> multiply -> 32-bit add in one clock, which was the
					// design's worst path by a wide margin (-4.958ns, and every
					// one of the top 15 failing paths). Here the mux is already
					// resolved into w_lfo, and this runs parallel to the rate
					// chain above rather than behind it, so it costs no cycle.
					// c_fnum/c_oct/c_vib are registered well before S_CALC and
					// w_lfo is stable until S_ENV2, so the value is unchanged.
					w_step      <= step_exact + 32'($signed(pm_add));
					// Likewise the AM term, for S_OUT. It depends only on
					// w_lfo and c_amd, both registered in S_CALC and unchanged
					// through S_OUT, so the value is the same one S_OUT would
					// have computed -- but the invert-and-multiply no longer
					// sits in front of S_OUT's muxes and att2vol lookup.
					p_am        <= am_add;
					state       <= S_ENV2;
				end

				S_ENV2: begin
					es_env_next = w_env;
					es_st_next   = w_state_eg;
					if (p_frac_zero) begin
						if (w_state_eg == EG_ATTACK) begin
							// reference: att += (~att * inc) >> 4, where ~att
							// is the C-integer negation -(att+1) -- i.e. the
							// attenuation DECAYS by ceil((att+1)*inc / 16)
							if (p_rate < 6'd62) begin
								es_dec = 10'(((11'(w_env) + 11'd1) * p_eg_inc + 15'd15) >> 4);
								es_env_next = (es_dec > w_env) ? 10'd0 : w_env - es_dec;
							end
							if (p_rate == 6'd63) es_env_next = 10'd0;
						end else begin
							if ({1'b0, w_env} + {7'd0, p_eg_inc} >= 11'h400) es_env_next = 10'h3FF;
							else es_env_next = w_env + {6'd0, p_eg_inc};
							if (es_env_next >= 10'h0C0 && w_state_eg < EG_REVERB && c_reverb)
								es_st_next = EG_REVERB;
						end
					end
					p_env_next      <= es_env_next;
					p_st_next       <= es_st_next;
					ch_lfo[ch]      <= w_lfo;
					// position advance + loop
					es_np = w_curpos + w_step;
					if (es_np >= {c_end, 16'd0})
						es_np = es_np + {c_loop, 16'd0} - {c_end, 16'd0};
					ch_nextpos[ch] <= es_np;
					// total level interpolation (19 up / 38 down per sample)
					if (c_lvl_direct) ch_tl[ch] <= {c_tl_reg, 10'd0};
					else if (ch_tl[ch] < {c_tl_reg, 10'd0})
						ch_tl[ch] <= ((ch_tl[ch] + 17'd19) > {c_tl_reg, 10'd0})
						            ? {c_tl_reg, 10'd0} : ch_tl[ch] + 17'd19;
					else if (ch_tl[ch] > {c_tl_reg, 10'd0})
						ch_tl[ch] <= ((ch_tl[ch] - 17'd38) < {c_tl_reg, 10'd0})
						            ? {c_tl_reg, 10'd0} : ch_tl[ch] - 17'd38;
					// The fetch address is computed unconditionally. It depends
					// only on w_curpos and ch_baseaddr[ch], both stable here,
					// whereas the quiet test (now in S_ENV3) sits at the far end of the
					// envelope arithmetic above. Gating the address on that test
					// put the entire envelope chain in series with the baseaddr
					// mux and the x3 multiply, which was the worst path at
					// -2.385ns. opl4.sv's arbiter latches pcm_mem_addr only
					// inside if (pcm_mem_req), so an address computed for a
					// silent channel is never sampled.
					case (ch_format[ch])
						2'd0: mem_rd_addr <= ch_baseaddr[ch] + 22'(w_curpos[31:16]);
						2'd2: mem_rd_addr <= ch_baseaddr[ch] + {5'd0, w_curpos[31:16], 1'b0};
						default: mem_rd_addr <= ch_baseaddr[ch]
						        + 22'(w_curpos[31:17]) * 22'd3
						        + (w_curpos[16] ? 22'd2 : 22'd0);
					endcase
					state <= S_ENV3;
				end

				// The envelope writeback and the quiet decision, split off from
				// the arithmetic that produces them. In S_ENV2 the attack
				// multiply, the clamps and the reverb test ran straight into the
				// 24-entry ch_env write decode in one clock -- the worst path at
				// -1.117ns. Splitting there costs a state per channel per sample,
				// about 24 clk_sys cycles out of the ~1948 available between
				// 44.1kHz sample ticks, so the engine still finishes each sample
				// with room to spare. It is the first of these splits that is not
				// free, which is why it was left until last.
				S_ENV3: begin
					ch_env[ch]      <= p_env_next;
					ch_eg_state[ch] <= p_st_next;
					// silent? skip the ROM fetch entirely
					if (p_env_next > EG_QUIET) state <= S_NEXT;
					else begin
						state <= S_FETCH0;
						mem_rd_req <= 1'b1;
					end
				end

				// The attenuation sum is registered here, in the states that are
				// already stalled on the sample ROM. ch_env[ch] and ch_tl[ch] are
				// written by S_ENV2/S_ENV3, so by now they hold the values S_OUT
				// would read -- but computing it here keeps the two 24-entry
				// channel muxes out of series with att2vol's lookup and barrel
				// shift, which was the worst path at -1.712ns. Re-assigning on
				// each stalled cycle is harmless; the inputs do not change.
				S_FETCH0: begin
				  p_env_eff <= {1'b0, ch_env[ch]} + {1'b0, p_am}
				             + {2'b00, ch_tl[ch][16:8]};
				  if (mem_rd_valid) begin
					w_byte0 <= mem_rd_data;
					if (ch_format[ch] == 2'd0) begin
						w_sample <= {mem_rd_data, 8'd0};
						state     <= S_OUT;
					end else begin
						// second byte: 16-bit -> pos*2+1; 12-bit -> middle byte
						mem_rd_req  <= 1'b1;
						mem_rd_addr <= (ch_format[ch] == 2'd2)
						  ? ch_baseaddr[ch] + {5'd0, w_curpos[31:16], 1'b0} + 22'd1
						  : ch_baseaddr[ch] + 22'(w_curpos[31:17]) * 22'd3 + 22'd1;
						state <= S_FETCH1;
					end
				  end
				end
				S_FETCH1: begin
				  p_env_eff <= {1'b0, ch_env[ch]} + {1'b0, p_am}
				             + {2'b00, ch_tl[ch][16:8]};
				  if (mem_rd_valid) begin
					if (ch_format[ch] == 2'd2)
						w_sample <= {w_byte0, mem_rd_data};
					// 12-bit packing (reference fetch_sample): the middle
					// byte's LOW nibble belongs to the even sample, the
					// HIGH nibble to the odd one
					else if (!w_curpos[16])
						w_sample <= {w_byte0, mem_rd_data[3:0], 4'd0};
					else
						w_sample <= {w_byte0, mem_rd_data[7:4], 4'd0};
					state <= S_OUT;
				  end
				end

				// ---- output accumulate ----
				// Attenuation and the att2vol lookups, registered. Doing these
				// and the sample multiply in one clock made acc_l/acc_r the
				// worst clk_sys path in the design.
				S_OUT: begin
					// attenuation = envelope + AM + total-level (7.10 -> .2
					// units via >>8, per the reference's `total_level >> 8`)
					os_lenv = p_env_eff + {1'b0, pan_l};
					os_renv = p_env_eff + {1'b0, pan_r};
					p_lvol <= att2vol((os_lenv > 11'h3FF) ? 13'hFFC : {os_lenv[9:0], 2'b00});
					p_rvol <= att2vol((os_renv > 11'h3FF) ? 13'hFFC : {os_renv[9:0], 2'b00});
					state  <= S_OUT2;
				end

				S_OUT2: begin
					os_lmul = $signed({1'b0, p_lvol}) * w_sample;
					os_rmul = $signed({1'b0, p_rvol}) * w_sample;
					acc_l <= acc_l + 20'(os_lmul >>> 15);
					acc_r <= acc_r + 20'(os_rmul >>> 15);
					state <= S_NEXT;
				end

				S_NEXT: begin
					if (ch == 5'd23) state <= S_DONE;
					else begin
						ch         <= ch + 5'd1;
						pcm_raddr <= 8'h68 + {3'd0, ch} + 8'd1;
						state      <= S_RD1;
					end
				end

				S_DONE: begin
					// clamp to 16 bits and publish
					pcm_l <= (acc_l > 20'sd32767)  ? 16'sd32767
					        : (acc_l < -20'sd32768) ? -16'sd32768 : 16'(acc_l);
					pcm_r <= (acc_r > 20'sd32767)  ? 16'sd32767
					        : (acc_r < -20'sd32768) ? -16'sd32768 : 16'(acc_r);
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
