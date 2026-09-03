// Granule cache with next-granule prefetch for the YM2610 ADPCM-A sample
// stream. Replaces sdram_narrow_bridge on that one client.
//
// WHY THIS EXISTS
// ---------------
// jt10's ADPCM-A ROM bus is FIXED LATENCY, not req/valid. jt10_adpcm_drvA
// reloads its `data` register from adpcma_data on every cen, and jt10_adpcm
// consumes it one cen6 later, so a byte that has not arrived by the last
// reload before that edge is not waited for -- it is silently replaced by
// whatever the previous fetch left on the bus. The deadline is 11 ym_cen
// ticks after roe_n falls: 1.375 us, ~118 clk at 85.909 MHz.
//
// Measured on hardware (build 855, debug row 214 / ISSP probe bits 48-63):
// 241 fetches missed that deadline in about four minutes of Gunbird attract
// mode. Each miss hands the decoder a nibble belonging to another channel,
// and ADPCM-A is predictive with an adaptive step -- one wrong nibble
// perturbs both the accumulator and the step index, so the error decays over
// tens of samples rather than clicking once.
//
// The old bridge's SINGLE-entry granule cache is why the miss rate was so
// high. Six ADPCM-A channels are interleaved on one bus at 666 kHz, so
// consecutive fetches belong to six different streams: with one cache entry
// every fetch evicts the previous stream's granule and every fetch misses,
// exposing all of them to a round trip that has to cross a fixed priority
// chain (sdram.sv gives port 0 tilemaps and port 1 sprite gfx absolute
// priority over port 2, where this lives). That is also why the fault tracks
// screen business, and why it is worse with several sounds playing: one
// channel on its own HITS the single entry and never waits.
//
// Two mechanisms, and the second is the one that actually closes it:
//
//   ENTRIES granules, fully associative -- six streams keep their own
//   granule instead of evicting each other. Each stream reads 8 bytes twice
//   over (two nibbles per byte), so this alone turns 15 of every 16 fetches
//   from a miss into a hit.
//
//   NEXT-GRANULE PREFETCH -- the remaining misses are granule crossings, and
//   those are predictable, because ADPCM-A addresses walk linearly. When a
//   stream reads the last byte of its granule the next one is fetched in the
//   background. A channel consumes a granule over ~864 us and crosses ~108
//   us after that last byte, against a worst-case round trip of 149 clk
//   (1.7 us) -- so the fetch is not merely likely to be early, it has two
//   orders of magnitude of slack. Without this the cache only makes the
//   defect 16x rarer; with it, demand misses stop happening at all except on
//   a cold start (channel key-on), where the decoder has just been cleared
//   and the step index is 0, so a wrong nibble is worth a fraction of an LSB.
//
// It also removes, structurally, the hazard the address latch in psikyo_top
// was added to work around: g_addr here is driven from a REGISTERED tag
// captured when the transaction is issued, never from the live client
// address. sdram_narrow_bridge drives it combinationally from `addr` while
// tagging the result with what it latched at accept, so a client whose
// address moves mid-fetch stores one granule's data under another's tag --
// and jt10's address rotates every 1.5 us regardless of us.

module adpcma_sample_cache #(
	parameter int ENTRIES = 16
) (
	input  logic clk,
	input  logic reset,

	// flush while the backing store is being written (ioctl_download)
	input  logic inval,

	// narrow client side. req may be HELD until valid (the ADPCM-A glue does
	// that) or pulsed (the OPL4 wave reader, which shares this client on
	// SH403/SH404 boards) -- S_DRAIN handles both.
	input  logic         req,
	input  logic [24:0] addr,      // byte address
	output logic         valid,
	output logic [7:0]  data,

	// granule side (one sdram_arbiter6 consumer port)
	output logic         g_req,
	output logic [24:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	localparam int IW = $clog2(ENTRIES);

	typedef enum logic [2:0] {
		S_IDLE, S_LOOK, S_HIT, S_FILL, S_DRAIN, S_PF
	} state_t;
	state_t st;

	logic [21:0] tag  [0:ENTRIES-1];   // granule address, addr[24:3]
	logic         tval [0:ENTRIES-1];
	logic [63:0] cdata[0:ENTRIES-1];
	logic [63:0] cdata_q;

	logic [IW-1:0] rr;          // round-robin replacement pointer
	logic [IW-1:0] sel_idx;     // entry being read or filled
	logic [2:0]    byte_sel;
	logic [21:0]   fill_tag;    // REGISTERED: what g_addr is asking for

	logic         pf_want;      // this access was a granule's last byte
	logic [21:0] pf_tag;

	// ---- fully-associative lookup ----
	// One comparator array, time-shared: it answers "is the requested
	// granule resident?" in S_IDLE and "is the prefetch target already
	// resident?" in S_DRAIN. Two arrays would double the compare logic on a
	// design where only one fitter seed in four closes timing.
	wire [21:0] look_tag = (st == S_DRAIN) ? pf_tag : addr[24:3];
	logic          hit;
	logic [IW-1:0] hit_idx;
	always_comb begin
		hit     = 1'b0;
		hit_idx = '0;
		for (int i = 0; i < ENTRIES; i++) begin
			if (tval[i] && (tag[i] == look_tag)) begin
				hit     = 1'b1;
				hit_idx = i[IW-1:0];
			end
		end
	end

	// Byte k of a granule is g_data[8*k +: 8]: sdram.sv captures word 0 (the
	// lowest byte address) into bits [15:0] and ascends, and within a word
	// the even byte address is the low half (sdram_phy.sv's wrl decode), so
	// a granule is plain little-endian across all eight bytes.
	wire [63:0] serve_word = (st == S_FILL) ? g_data : cdata_q;
	assign data  = serve_word[8*byte_sel +: 8];
	assign valid = (st == S_HIT) || ((st == S_FILL) && g_valid);

	assign g_addr = {fill_tag, 3'b000};
	assign g_req  = (st == S_FILL) || (st == S_PF);

	// Cache data in its own block so Quartus infers an MLAB rather than
	// building a 64-bit ENTRIES:1 mux out of logic. The read is registered,
	// which is what S_LOOK is for; there is no rush, the deadline is 118 clk.
	wire fill_we = ((st == S_FILL) || (st == S_PF)) && g_valid;
	always_ff @(posedge clk) begin
		if (fill_we) cdata[sel_idx] <= g_data;
		cdata_q <= cdata[sel_idx];
	end

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st      <= S_IDLE;
			rr      <= '0;
			pf_want <= 1'b0;
			for (int i = 0; i < ENTRIES; i++) tval[i] <= 1'b0;
		end else begin
			if (inval) for (int i = 0; i < ENTRIES; i++) tval[i] <= 1'b0;

			case (st)
				S_IDLE: if (req) begin
					byte_sel <= addr[2:0];
					// Last byte of the granule: the stream is about to cross
					// into the next one, and will not need it for ~108 us.
					pf_want  <= (addr[2:0] == 3'd7);
					pf_tag   <= addr[24:3] + 22'd1;
					if (hit && !inval) begin
						sel_idx <= hit_idx;
						st      <= S_LOOK;
					end else begin
						fill_tag <= addr[24:3];
						sel_idx  <= rr;
						rr       <= rr + 1'b1;
						st       <= S_FILL;
					end
				end

				S_LOOK: st <= S_HIT;      // cdata_q settling

				S_HIT: st <= S_DRAIN;     // valid pulses this cycle

				S_FILL: if (g_valid) begin
					tag[sel_idx]  <= fill_tag;
					tval[sel_idx] <= !inval;
					st            <= S_DRAIN;
				end

				// Wait for a held req to drop before looking again, exactly as
				// sdram_narrow_bridge's B_DRAIN does -- going straight back to
				// S_IDLE would re-latch a still-high req and serve a spurious
				// second read. Then spend the idle time prefetching: the next
				// demand fetch is ~9 us away, so this always finishes long
				// before anything waits on it. `hit` reads pf_tag here.
				S_DRAIN: if (!req) begin
					pf_want <= 1'b0;
					if (pf_want && !hit) begin
						fill_tag <= pf_tag;
						sel_idx  <= rr;
						rr       <= rr + 1'b1;
						st       <= S_PF;
					end else begin
						st <= S_IDLE;
					end
				end

				S_PF: if (g_valid) begin
					tag[sel_idx]  <= fill_tag;
					tval[sel_idx] <= !inval;
					st            <= S_IDLE;
				end

				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
