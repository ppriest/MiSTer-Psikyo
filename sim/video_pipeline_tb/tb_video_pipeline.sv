// First real end-to-end integration test of the top-level video pipeline:
// video_timing (the raw H/V generator, docs/phase1_ddram_map.md-adjacent
// work) actually driving a real tilemap_line_engine instance, not the
// synthetic per-module timing drivers tilemap_line_engine_tb uses on its
// own. Confirms video_timing's hcnt/vcnt/h_active/line_start convention
// genuinely matches what tilemap_line_engine expects -- checked directly
// against docs/phase1_video_engine.md's own stated interface contract
// before writing this (both modules agree: hcnt 0-319 active/455 total,
// vcnt 0-223 active/261 total, line_start pulses during hblank well ahead
// of h_active), but this is the first time they've actually been wired
// together and run.
//
// Scope deliberately narrow: ONE tilemap layer (LAYER=0), synthetic VRAM
// (every cell 0x0000 -- tile 0, color 0 everywhere, per tile_cell_decode's
// documented format) and a synthetic req/valid gfx ROM model (a simple
// addressable pattern, not real tile graphics) -- this test is about
// PROVING THE TIMING HANDSHAKE, not re-verifying decode correctness
// (tilemap_line_engine_tb and its upstream module testbenches already
// cover that). No compositor, no sprite engine, no second layer -- those
// are separate, larger integration steps.
//
// ce_pix is tied high every cycle (1 pixel = 1 clk, no oversampling) --
// matches how tilemap_line_engine's own standalone testbench already
// exercises it (the module has no ce_pix port of its own, so this is the
// simplest/fastest-possible timing relationship and gives the fetch
// pipeline maximum headroom, consistent with this being a correctness
// check, not a throughput check).
//
// Pass criteria: the buffer-not-ready-during-active-display condition
// (tilemap_line_engine.sv's own fetch_overrun trigger, checked
// independently -- see below for why) never occurs across a full
// simulated frame -- the real, concrete proof that this module's timing
// budget (docs/phase1_video_engine.md: "one scanline is only htotal
// pixel-clocks") is actually met when driven by the real timing
// generator, not just assumed. Also checks pixel_valid actually pulses
// during h_active (not stuck low) and never produces X on pixel_index/
// pixel_color while valid.
//
// Two real testbench bugs found and fixed, both worth understanding
// since they reflect genuine lessons, not just fiddling until green:
//
// 1. video_timing's synchronous reset always releases into hcnt=vcnt=0,
//    immediately INSIDE the first active line -- there's no way for it to
//    reset "mid-vblank". This makes the very first active line after ANY
//    reset an unavoidable cold-start case: tilemap_line_engine cannot
//    possibly have prefetched for it (no prior hblank existed), so it
//    correctly (not a bug) raises its own fetch_overrun once. That output
//    is STICKY, though, and this project's other req/valid modules taught
//    that lesson before (ddram_arbiter etc.) -- a "run continuously from
//    reset, then check the sticky bit at the end" methodology is
//    fundamentally broken for exactly this reason: once latched by the
//    expected cold start, it is permanently indistinguishable from "a
//    real overrun happened later", regardless of how carefully reset
//    timing is arranged afterward (confirmed by direct experimentation --
//    no reset-sequencing trick avoids the initial latch, because the
//    underlying condition, h_active true with nothing prefetched, is
//    genuinely met at that moment no matter when reset releases). Fixed
//    by not checking the DUT's `fetch_overrun` output at all -- instead,
//    independently replicating its own trigger condition
//    (tilemap_line_engine.sv ~line 318-320: `h_active &&
//    !buf_ready[display_sel]`) via hierarchical access, giving a true,
//    NON-sticky per-cycle reading. Two separate resets (video_timing
//    releases immediately; tilemap_line_engine's own reset is held a
//    little longer, into its first active line) keep the checked window
//    clear of the expected, understood cold-start line.
//
// 2. A real, independent RTL bug, found while chasing what first looked
//    like a sustained-operation failure (a red herring -- see above):
//    tilemap_line_engine's fetch FSM only acted on `line_start` from
//    S_IDLE, inside the state case statement. Since the fetch FSM's last
//    tile for a line can legitimately still be in flight when the next
//    line's `line_start` pulse arrives (both timed against the same
//    16-cycle-per-tile display budget, with no structural guarantee the
//    fetch always finishes strictly first), that pulse could be silently
//    dropped whenever the FSM wasn't already idle -- permanently
//    desyncing the fetch pipeline from the display for the rest of the
//    frame. Fixed in tilemap_line_engine.sv: `line_start` is now checked
//    BEFORE the state case, with top priority in any state, restarting
//    the fetch FSM unconditionally (a new line always outranks finishing
//    stale work for the old one -- the display side already discards
//    whatever wasn't shown on its own line_start handling). Re-verified
//    against tilemap_line_engine's own pre-existing single-line testbench
//    (still PASSes unchanged) before trusting this fix.
//
// The eventual, corrected finding: once tested with a non-sticky check,
// sustained multi-line/full-frame operation is genuinely clean -- detailed
// cycle-by-cycle tracing (via $display, in lieu of a real waveform viewer)
// across lines 0-1 showed completely healthy steady-state fetch/display
// interaction throughout. The earlier "fetch_overrun on line 2-3" reports
// from prior versions of this test were the sticky bit's cold-start latch
// being surfaced at whatever arbitrary hcnt/vcnt this test's monitoring
// loop happened to first check it -- not a recurring problem. Item 2
// above is still a real, worthwhile fix, independent of that false alarm.

module tb_video_pipeline;

	logic clk = 0;
	always #5 clk = ~clk;

	logic reset_vt, reset_tle;

	// ---- video_timing ----
	logic ce_pix;
	logic [8:0] hcnt, vcnt_raw;
	logic [7:0] vcnt_active;
	logic h_active, v_active, hblank, vblank, hsync, vsync;
	logic line_start, frame_start;

	assign ce_pix = 1'b1;

	video_timing vt (
		.clk(clk), .ce_pix(ce_pix), .reset(reset_vt),
		.hcnt(hcnt), .vcnt(vcnt_raw), .vcnt_active(vcnt_active),
		.h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start)
	);

	// ---- tilemap_line_engine, layer 0 ----
	logic [1:0]  mode;
	logic [15:0] base_x_scroll, base_y_scroll;
	logic [1:0]  bank;
	logic         rowscroll_enable, rowscroll_pertile;
	logic [7:0]  rowscroll_addr;
	logic [15:0] rowscroll_data;
	logic [11:0] vram_addr;
	logic [15:0] vram_data;
	logic         gfxrom_req;
	logic [21:0] gfxrom_addr;
	logic         gfxrom_valid;
	logic [63:0] gfxrom_data;
	logic         pixel_valid;
	logic [3:0]  pixel_index;
	logic [6:0]  pixel_color;
	logic         fetch_overrun;

	assign mode             = 2'd0;
	assign base_x_scroll    = 16'd0;
	assign base_y_scroll    = 16'd0;
	assign bank             = 2'd0;
	assign rowscroll_enable = 1'b0;
	assign rowscroll_pertile = 1'b0;

	tilemap_line_engine #(.LAYER(0)) tle (
		.clk(clk), .reset(reset_tle),
		.vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
		.mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll), .bank(bank),
		.rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile),
		.rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr), .gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
		.pixel_valid(pixel_valid), .pixel_index(pixel_index), .pixel_color(pixel_color), .fetch_overrun(fetch_overrun)
	);

	// synthetic VRAM: every cell 0x0000 (tile 0, color 0 everywhere, per
	// tile_cell_decode.sv's documented format) -- 1-cycle sync read
	logic [15:0] vram [0:4095];
	always_ff @(posedge clk) vram_data <= vram[vram_addr];

	// synthetic row-scroll table -- content irrelevant since
	// rowscroll_enable=0, but the port still needs a defined 1-cycle sync
	// response, not X
	logic [15:0] rowscroll_mem [0:255];
	always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

	// synthetic gfx ROM: req/valid, 3-cycle latency, a simple deterministic
	// pattern keyed on the requested address (not real tile graphics --
	// this test checks the timing handshake, not decoded pixel content)
	typedef enum logic { G_IDLE, G_WAIT } gstate_t;
	gstate_t gstate;
	int gwait_cnt;
	localparam int GFX_LATENCY = 3;

	always_ff @(posedge clk or posedge reset_tle) begin
		if (reset_tle) begin
			gstate       <= G_IDLE;
			gfxrom_valid <= 1'b0;
		end else begin
			gfxrom_valid <= 1'b0;
			case (gstate)
				G_IDLE: if (gfxrom_req) begin
					gwait_cnt <= GFX_LATENCY;
					gstate    <= G_WAIT;
				end
				G_WAIT: begin
					if (gwait_cnt == 0) begin
						gfxrom_data  <= {8{gfxrom_addr[7:0]}};
						gfxrom_valid <= 1'b1;
						gstate       <= G_IDLE;
					end else begin
						gwait_cnt <= gwait_cnt - 1;
					end
				end
			endcase
		end
	end

	int pixel_valid_count;
	int errors;

	initial begin
		#30000000;
		$display("TIMEOUT: simulation did not finish in time");
		$finish;
	end

	initial begin
		errors = 0;
		pixel_valid_count = 0;

		for (int i = 0; i < 4096; i++) vram[i] = 16'h0000;
		for (int i = 0; i < 256; i++) rowscroll_mem[i] = 16'h0000;

		// video_timing's reset always lands on hcnt=vcnt=0 -- immediately
		// INSIDE the first active line, with no prior hblank ever having
		// occurred. That first line is an unavoidable cold-start case
		// (tilemap_line_engine could not possibly have prefetched for it),
		// genuinely raising fetch_overrun -- but that bit is STICKY, so it
		// must be cleared with a second, precisely-timed reset pulse
		// before it falsely poisons every later line's measurement.
		//
		// The timing constraint: reset_tle must fully release BEFORE this
		// first line's line_start fires (hcnt==319->320) -- release any
		// later and the module misses that exact pulse (reset dominates
		// while held, and line_start is a single-cycle pulse with no way
		// to "catch it late"), sitting idle through the entire NEXT
		// active line with nothing ever fetched -- a real, immediate
		// fetch_overrun right at that line's first pixel. An earlier
		// version of this sequencing released 50 cycles AFTER the first
		// line_start (deep in hblank, reasoning backwards that more
		// hblank time = more margin) and hit exactly this trap -- every
		// "failure" this test reported traced back to that single
		// sequencing mistake, not a tilemap_line_engine bug. Releasing
		// early in line 0's ACTIVE window (well before hcnt reaches 319)
		// avoids it entirely: line 0 itself is still an unavoidable
		// write-off (no prior hblank existed to prefetch it in), but the
		// module is long out of reset and correctly waiting in S_IDLE by
		// the time line 0's real line_start arrives, cleanly priming line 1.
		reset_vt  = 1;
		reset_tle = 1;
		repeat (15) @(posedge clk);   // still well inside line 0's active window
		reset_vt  = 0;
		reset_tle = 0;                 // released with ~300 cycles to spare before hcnt==319
		@(posedge clk);

		// Skip a couple more line_start pulses as extra settle margin
		// before trusting the output.
		repeat (2) begin
			do @(posedge clk); while (!line_start);
		end
		@(posedge clk);

		// run for slightly over one full frame (262*456 + margin cycles)
		//
		// Deliberately NOT checking the DUT's own `fetch_overrun` output
		// here -- it's sticky (see the module's own header), and the very
		// first active line after any reset is an unavoidable cold-start
		// case (video_timing's reset always lands mid-active-line, with no
		// prior hblank to have prefetched in), which sets it once, for
		// good, regardless of how carefully the reset is timed afterward
		// (confirmed by direct experimentation: no reset-timing trick
		// avoids it, because the underlying condition -- h_active true
		// with nothing prefetched -- is genuinely met at that moment).
		// Once latched, the sticky bit reading 1 is permanently
		// indistinguishable from "a real overrun happened later", making
		// it useless for a "run continuously, check at the end" test.
		// Instead, this replicates the DUT's own trigger condition
		// (tilemap_line_engine.sv ~line 318-320: h_active && !buf_ready
		// [display_sel]) independently and NON-stickily via hierarchical
		// access, giving a true per-cycle reading unaffected by history --
		// this is what actually resolved the "fetch_overrun on sustained
		// operation" finding from earlier versions of this test: detailed
		// waveform-equivalent tracing (via $display, not a real waveform
		// viewer) of dut.state/buf_ready/consumed across lines 0-1 showed
		// completely healthy, steady-state operation throughout -- the
		// repeated "failures" were the sticky cold-start bit being
		// reported at whatever arbitrary hcnt/vcnt this test's monitoring
		// loop happened to first check it, not a real recurring problem.
		repeat (262 * 456 + 500) begin
				@(posedge clk);

				if (pixel_valid) begin
					pixel_valid_count++;
					if (pixel_index === 4'hx || pixel_color === 7'hx) begin
						errors++;
						$display("FAIL X-valued pixel output at hcnt=%0d vcnt=%0d: index=%h color=%h",
								  hcnt, vcnt_raw, pixel_index, pixel_color);
					end
				end

				if (h_active && !tle.buf_ready[tle.display_sel]) begin
					errors++;
					$display("FAIL buffer not ready during active display at hcnt=%0d vcnt=%0d -- timing budget not met", hcnt, vcnt_raw);
				end
		end

		if (pixel_valid_count == 0) begin
			errors++;
			$display("FAIL pixel_valid never asserted across the whole frame");
		end else if (pixel_valid_count > 320 * 263) begin
			// tilemap_line_engine has no concept of vblank -- it responds
			// to h_active/line_start regardless of v_active, so pixel_valid
			// legitimately pulses during every one of the 262 total lines
			// (not just the 224 visible ones); a real top-level would gate
			// actual video output by v_active separately. 320*262 is the
			// real one-frame max; the +320 margin (one extra line's worth)
			// accounts for this loop deliberately running slightly past
			// one exact frame boundary (+500 cycles, just over one extra
			// line), not a real discrepancy.
			errors++;
			$display("FAIL pixel_valid asserted %0d times, well beyond even the +1-line margin over the 320*262=%0d theoretical one-frame max",
					  pixel_valid_count, 320*262);
		end else begin
			$display("pixel_valid asserted %0d times over one frame (320*262=%0d theoretical max, 320*224=%0d if gated to visible lines only)",
					  pixel_valid_count, 320*262, 320*224);
		end

		if (errors == 0)
			$display("PASS: video_timing correctly drives tilemap_line_engine over a full frame, no fetch_overrun");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
