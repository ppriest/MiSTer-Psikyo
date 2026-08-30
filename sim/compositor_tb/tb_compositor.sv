// Checks compositor against an independently-computed reference. Cases
// chosen to isolate specific risks rather than one big combined scenario:
// basic layer-only draws, transparent-pen skip, opaque-mode override,
// layer-disable, the sprite priority-mask table's "always front"/"always
// behind" behavior (including the easy-to-miss case where a "behind"
// sprite still shows through when NEITHER tilemap layer drew anything),
// and the backdrop quirk (always layer 0's transpen bit, regardless of
// which layer is actually enabled).

module tb_compositor;

	logic         l0_valid;
	logic [3:0]  l0_pixel;
	logic [6:0]  l0_color;
	logic         l0_ctrl_enable, l0_ctrl_opaque, l0_ctrl_transpen_sel;

	logic         l1_valid;
	logic [3:0]  l1_pixel;
	logic [6:0]  l1_color;
	logic         l1_ctrl_enable, l1_ctrl_opaque, l1_ctrl_transpen_sel;

	logic         sp_present;
	logic [3:0]  sp_pixel;
	logic [4:0]  sp_color;
	logic [1:0]  sp_priority;

	logic [11:0] pal_addr;
	logic [8:0]  pal_s_addr;
	logic         sprite_sel;

	compositor dut (.*);

	int errors;

	task automatic set_l0(int valid, int pixel, int color, int en, int op, int tsel);
		l0_valid = valid[0]; l0_pixel = pixel[3:0]; l0_color = color[6:0];
		l0_ctrl_enable = en[0]; l0_ctrl_opaque = op[0]; l0_ctrl_transpen_sel = tsel[0];
	endtask

	task automatic set_l1(int valid, int pixel, int color, int en, int op, int tsel);
		l1_valid = valid[0]; l1_pixel = pixel[3:0]; l1_color = color[6:0];
		l1_ctrl_enable = en[0]; l1_ctrl_opaque = op[0]; l1_ctrl_transpen_sel = tsel[0];
	endtask

	task automatic set_sp(int present, int pixel, int color, int pri);
		sp_present = present[0]; sp_pixel = pixel[3:0]; sp_color = color[4:0]; sp_priority = pri[1:0];
	endtask

	// tilemap/backdrop wins: the LIVE palette lookup must carry exp_addr
	// and sprite_sel must be low.
	task automatic check(string label, int exp_addr);
		#1;
		if (sprite_sel !== 1'b0) begin
			errors++;
			$display("FAIL(%s) sprite_sel: got=1 expected=0", label);
		end
		if (pal_addr !== exp_addr[11:0]) begin
			errors++;
			$display("FAIL(%s) pal_addr: got=%h expected=%h", label, pal_addr, exp_addr);
		end
	endtask

	// sprite wins: the SNAPSHOT palette lookup must carry exp_addr and
	// sprite_sel must be high (the caller muxes the RAM outputs on it).
	task automatic check_sp(string label, int exp_addr);
		#1;
		if (sprite_sel !== 1'b1) begin
			errors++;
			$display("FAIL(%s) sprite_sel: got=0 expected=1", label);
		end
		if (pal_s_addr !== exp_addr[8:0]) begin
			errors++;
			$display("FAIL(%s) pal_s_addr: got=%h expected=%h", label, pal_s_addr, exp_addr);
		end
	endtask

	initial begin
		errors = 0;

		// ---- Case 1: only layer0 opaque, non-transparent pixel ----
		set_l0(1, 5, 3, 1, 0, 0);   // transpen=15 (tsel=0), pixel=5 != 15 -> draws
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		check("l0-only", 12'h800 + 3*16 + 5);

		// ---- Case 2: layer0 transparent (pixel==transpen), layer1 opaque wins ----
		set_l0(1, 15, 3, 1, 0, 0);   // transpen=15, pixel==15 -> does NOT draw
		set_l1(1, 7, 2, 1, 0, 1);    // transpen=0 (tsel=1), pixel=7 != 0 -> draws
		set_sp(0, 0, 0, 0);
		check("l1-wins-l0-transparent", 12'h800 + 2*16 + 7);

		// ---- Case 3: layer0 opaque-mode forces draw even at transparent pixel ----
		set_l0(1, 15, 4, 1, 1, 0);   // transpen=15, pixel==15, but opaque=1 -> draws anyway
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		check("l0-opaque-forced", 12'h800 + 4*16 + 15);

		// ---- Case 4: layer0 disabled even with non-transparent pixel ----
		set_l0(1, 5, 3, 0, 0, 0);    // ctrl_enable=0 -> does NOT draw regardless of pixel
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		// falls through to backdrop; backdrop is ALWAYS pen 0 (0x800),
		// unconditionally, regardless of l0_ctrl_transpen_sel or l0's own
		// enable bit -- corrected earlier today (commit 7b9c33d) per the
		// MAME renderer author's direction; this test predated that fix.
		check("l0-disabled-backdrop", 12'h800);

		// ---- Case 5: sprite priority 0 -- always front, wins over both opaque layers ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 0);
		check_sp("sprite-priority0-front", 6*16 + 9);

		// Cases 6-9 encode the BIT-INDEXED primask semantics (MAME's
		// pdrawgfx convention: sprite blocked iff primask[priority_val]),
		// fixed 2026-08-29. The original value-AND implementation --
		// (priority_val & primask) == 0 -- passed an earlier version of
		// these cases while rendering samuraia's priority-1 cloud sprites
		// over tilemap 1 on hardware: layer 1's priority_val of 2 ANDs to
		// zero against 0xFC. The tests below fail against value-AND.

		// ---- Case 6: sprite priority 1 (0xFC) -- above layer 0 ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 1);
		check_sp("sprite-priority1-wins-over-l0-only", 6*16 + 9);

		// ---- Case 6b: sprite priority 1 -- BELOW layer 1 (the samuraia
		// cloud case: primask[2] of 0xFC is set, layer 1 wins) ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 1);
		check("sprite-priority1-blocked-by-l1", 12'h800 + 2*16 + 7);

		// ---- Case 6c: priority 1, both layers drawing -- layer 1 on top
		// (priority_val=2), sprite still blocked ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 1);
		check("sprite-priority1-blocked-by-l1-over-l0", 12'h800 + 2*16 + 7);

		// ---- Case 7: sprite priority 2 (0xFE) -- blocked by layer 0 alone
		// (primask[1] set), unlike priority 1 ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 2);
		check("sprite-priority2-blocked-by-l0", 12'h800 + 3*16 + 5);

		// ---- Case 7b: sprite priority 2 -- blocked by layer 1 alone ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 2);
		check("sprite-priority2-blocked-by-l1-only", 12'h800 + 2*16 + 7);

		// ---- Case 7c: sprite priority 2 -- visible over BARE BACKDROP
		// (primask[0] of 0xFE is clear; this is what distinguishes 0xFE
		// from published MAME's 0xFF for this entry) ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 2);
		check_sp("sprite-priority2-wins-over-backdrop", 6*16 + 9);

		// ---- Case 8: sprite priority 3 (0xFF) -- blocked by layer 1 ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 7, 2, 1, 0, 1);
		set_sp(1, 9, 6, 3);
		check("sprite-priority3-blocked-by-l1", 12'h800 + 2*16 + 7);

		// ---- Case 8b: sprite priority 3 -- blocked by layer 0 alone ----
		set_l0(1, 5, 3, 1, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 3);
		check("sprite-priority3-blocked-by-l0-too", 12'h800 + 3*16 + 5);

		// ---- Case 8c: sprite priority 3 -- NEVER visible: primask[0] of
		// 0xFF is set, so even bare backdrop blocks it ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(1, 9, 6, 3);
		check("sprite-priority3-never-visible", 12'h800);

		// ---- Case 9: sprite priority 1, neither layer drew -- primask[0]
		// of 0xFC is clear, sprite wins over backdrop ----
		set_l0(1, 15, 0, 1, 0, 0);   // transparent
		set_l1(1, 0, 0, 1, 0, 1);    // transparent (transpen=0, pixel=0)
		set_sp(1, 9, 6, 1);
		check_sp("sprite-priority1-wins-over-backdrop", 6*16 + 9);

		// ---- Case 10: full backdrop, tsel=0 -- ALWAYS pen 0 now (0x800),
		// tsel no longer has any effect on the backdrop (commit 7b9c33d) ----
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(0, 0, 0, 0, 0, 0);
		set_sp(0, 0, 0, 0);
		l0_ctrl_transpen_sel = 1'b0;
		check("backdrop-always-pen0-tsel0", 12'h800);

		// ---- Case 11: full backdrop, tsel=1 -- still pen 0, tsel truly has
		// no effect either way (this case and Case 10 now expect the SAME
		// address, which is the point: it proves tsel is ignored) ----
		l0_ctrl_transpen_sel = 1'b1;
		check("backdrop-always-pen0-tsel1", 12'h800);

		// ---- Case 12: backdrop with layer1 enabled+opaque-forced with its
		// OWN transpen bit set differently, layer0 DISABLED -- still just
		// pen 0 unconditionally, not "black", not following either layer's
		// transpen_sel ----
		set_l0(0, 0, 0, /*en=*/0, 0, /*tsel=*/1);   // l0 disabled
		set_l1(0, 0, 0, /*en=*/0, 0, /*tsel=*/0);   // l1 also disabled/not drawing
		set_sp(0, 0, 0, 0);
		check("backdrop-always-pen0-ignores-enable-and-tsel", 12'h800);

		// ---- Cases 13-15: backdrop follows the topmost ENABLED layer (per
		// the MAME renderer author, 2026-08-29): that layer's palette bank
		// (l1 -> 0xC00, l0 -> 0x800) at its transpen-selected pen (tsel=1
		// -> pen 0, tsel=0 -> pen 15). Cases 10-12 above still hold: with
		// BOTH layers disabled the clear stays 0x800.
		set_l0(0, 0, 0, 0, 0, 0);
		set_l1(1, 0, 2, 1, 0, 1);   // enabled, pixel==transpen(0): not drawing
		set_sp(0, 0, 0, 0);
		check("backdrop-l1-enabled-tsel1", 12'hC00);

		set_l1(1, 15, 2, 1, 0, 0);  // transpen=15, pixel 15: not drawing
		check("backdrop-l1-enabled-tsel0", 12'hC0F);

		set_l0(1, 0, 3, 1, 0, 1);   // only layer 0 enabled, transparent
		set_l1(0, 0, 0, 0, 0, 0);
		check("backdrop-l0-enabled-tsel1", 12'h800);
		set_l0(1, 15, 3, 1, 0, 0);
		check("backdrop-l0-enabled-tsel0", 12'h80F);

		set_l0(1, 15, 3, 1, 0, 0);   // both enabled, both transparent:
		set_l1(1, 0, 2, 1, 0, 1);    // layer 1 wins the backdrop choice
		check("backdrop-l1-priority-over-l0", 12'hC00);

		// (The final RGB mux -- registered sprite_sel selecting between the
		// two palette RAMs' outputs -- lives in psikyo_core.sv, exercised
		// by the integration testbenches, not here.)

		if (errors == 0)
			$display("PASS: compositor matches reference for all cases");
		else
			$display("FAIL: %0d mismatches", errors);

		$finish;
	end

endmodule
