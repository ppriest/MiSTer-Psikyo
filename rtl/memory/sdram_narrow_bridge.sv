// Bridges a narrow (byte- or word-wide) req/valid read port onto a
// 64-bit-granule sdram_arbiter5/sdram_phy consumer port. Exists because
// sdram.sv's burst-4 controller only ever hands back a full 8-byte-aligned
// granule (rtl/memory/sdram/sdram.sv, rtl/memory/sdram_arbiter5.sv) -- every
// Port 2 consumer narrower than that (sprite spritelut's 16-bit words,
// maincpu's 16-bit program fetch, audiocpu's 8-bit program fetch, per
// docs/phase1_sdram_map.md) needs the same "fetch the containing granule,
// then pick out the wanted slice" logic, so it's built once here rather
// than copy-pasted per consumer.
//
// GRANULE CACHE: the bridge
// keeps the last fetched granule and serves any request that falls inside
// it WITHOUT a new SDRAM transaction -- a 1-cycle B_HIT response instead
// of a full arbiter+controller round trip. The narrow consumers' access
// patterns are dominated by sequential streams (68020 opcode fetch: 4
// words/granule; Z80 opcode fetch: 8 bytes/granule; spritelut: runs of
// consecutive tile codes), so this removes the majority of their Port 2
// traffic -- which otherwise contends with sprite gfx fetches and was a
// prime suspect in the rendering slowdown (docs/ROADMAP.md, "Fix the
// slowdown"). All cached regions are ROM (written only by the HPS
// download), so the only invalidation needed is the `inval` input, tied
// to ioctl_download by psikyo_sdram_top -- the cache is flushed
// continuously for the whole download and starts cold afterwards.
//
// Byte/word layout within a fetched granule, derived directly from
// sdram.sv's own read-capture logic and sdram_chip_model.sv's write-mask
// decode (not assumed) -- word i (0-3, ascending byte address) occupies
// g_data[16*i +: 16] (sdram.sv: STATE_READ0->dout[15:0] is the FIRST/lowest-
// address word, STATE_READ3->dout[63:48] the last), and within a 16-bit
// word, the EVEN byte address (addr[0]=0) is the LOW byte, ODD (addr[0]=1)
// is the HIGH byte (sdram_phy.sv: wrl <= we && !addr[0] selects the byte
// sdram_chip_model.sv writes to mem[][7:0], the low half) -- ordinary
// little-endian packing within each 16-bit lane. So for any byte address
// `addr`, word_index = addr[2:1] and (for WORD_BYTES=1) byte_in_word =
// addr[0] selecting low/high half of that word.
//
// req/valid contract: clients PULSE req (see maincpu.sv's rom_req comment
// -- a held req would re-trigger this bridge) and hold `addr` stable until
// the valid pulse. Toward the arbiter this bridge holds g_req until
// g_valid, one request at a time (no pipelining -- matches
// sdram_arbiter5's own single-outstanding-transaction design).

module sdram_narrow_bridge #(
	parameter int WORD_BYTES = 2   // 1 = byte-wide client (e.g. Z80/audiocpu),
									 // 2 = word-wide client (e.g. spritelut, maincpu)
) (
	input  logic clk,
	input  logic reset,

	// flush the granule cache (hold high while the backing store is being
	// written, i.e. ioctl_download)
	input  logic inval,

	// narrow client side
	input  logic                     req,
	input  logic [24:0]              addr,    // byte address of the desired unit
	output logic                     valid,
	output logic [8*WORD_BYTES-1:0] data,

	// wide granule side (one sdram_arbiter5 consumer port)
	output logic         g_req,
	output logic [24:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	typedef enum logic [1:0] {B_IDLE, B_WAIT, B_HIT, B_DRAIN} bstate_t;
	bstate_t bstate;

	logic [1:0] word_sel;
	logic         byte_sel;

	// ---- granule cache ----
	logic [63:0] cache_data;
	logic [21:0] cache_tag;      // granule address, addr[24:3]
	logic         cache_valid;
	logic [21:0] tag_inflight;   // granule being fetched (latched at accept --
								  // addr is only guaranteed stable until valid)

	wire hit = cache_valid && (addr[24:3] == cache_tag);

	assign g_addr = {addr[24:3], 3'b000};   // 8-byte-align down to the granule base
	assign g_req  = (bstate == B_WAIT);

	// B_HIT serves from the cache; B_WAIT serves from the live granule the
	// cycle it arrives (and fills the cache the same cycle).
	logic [15:0] sel_word;
	assign sel_word = (bstate == B_HIT) ? cache_data[16*word_sel +: 16]
										  : g_data[16*word_sel +: 16];

	generate
		if (WORD_BYTES == 1) begin : g_byte
			assign data = byte_sel ? sel_word[15:8] : sel_word[7:0];
		end else begin : g_word
			assign data = sel_word;
		end
	endgenerate

	assign valid = ((bstate == B_WAIT) && g_valid) || (bstate == B_HIT);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bstate       <= B_IDLE;
			cache_valid <= 1'b0;
		end else begin
			if (inval) cache_valid <= 1'b0;

			case (bstate)
				B_IDLE: begin
					if (req) begin
						word_sel <= addr[2:1];
						byte_sel <= addr[0];
						if (hit && !inval) begin
							bstate <= B_HIT;
						end else begin
							tag_inflight <= addr[24:3];
							bstate        <= B_WAIT;
						end
					end
				end
				B_WAIT: begin
					if (g_valid) begin
						if (!inval) begin
							cache_data  <= g_data;
							cache_tag   <= tag_inflight;
							cache_valid <= 1'b1;
						end
						bstate <= B_IDLE;
					end
				end
				B_HIT: begin
					// valid pulses this cycle (see assign above). Go through
					// B_DRAIN rather than straight to B_IDLE: a HELD-req
					// client (the ADPCM-A path holds req until valid, unlike
					// the pulse-req CPUs) clears its req only on the cycle
					// AFTER seeing valid -- returning to B_IDLE immediately
					// would re-latch the still-high req and serve a spurious
					// second hit. The old all-miss bridge had the same
					// re-latch exposure but its ~20-cycle round trip made the
					// extra serve harmless; a 1-cycle hit would loop.
					bstate <= B_DRAIN;
				end
				B_DRAIN: begin
					if (!req) bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

endmodule
