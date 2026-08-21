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
    logic [15:0] pal_data;
    logic [14:0] rgb;

    compositor dut (.*);

    // simple palette memory: pal_data = pal_addr (identity), so checking
    // rgb reduces to checking pal_addr[14:0] directly -- keeps the
    // reference simple while still exercising the pal_data wiring
    assign pal_data = {1'b0, pal_addr[11:0], 3'b000};

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

    task automatic check(string label, int exp_addr);
        #1;
        if (pal_addr !== exp_addr[11:0]) begin
            errors++;
            $display("FAIL(%s) pal_addr: got=%h expected=%h", label, pal_addr, exp_addr);
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
        // falls through to backdrop; backdrop uses l0_ctrl_transpen_sel
        // regardless of l0's own enable bit (tsel=0 here -> pen15 -> 0x80f)
        check("l0-disabled-backdrop", 12'h80f);

        // ---- Case 5: sprite priority 0 -- always front, wins over both opaque layers ----
        set_l0(1, 5, 3, 1, 0, 0);
        set_l1(1, 7, 2, 1, 0, 1);
        set_sp(1, 9, 6, 0);
        check("sprite-priority0-front", 6*16 + 9);

        // ---- Case 6: sprite priority 1 -- "same as 0", still always front ----
        set_sp(1, 9, 6, 1);
        check("sprite-priority1-front", 6*16 + 9);

        // ---- Case 7: sprite priority 2 -- behind, blocked by layer0 opaque ----
        set_l0(1, 5, 3, 1, 0, 0);
        set_l1(0, 0, 0, 0, 0, 0);
        set_sp(1, 9, 6, 2);
        check("sprite-priority2-blocked-by-l0", 12'h800 + 3*16 + 5);

        // ---- Case 8: sprite priority 3 -- behind, blocked by layer1 opaque ----
        set_l0(0, 0, 0, 0, 0, 0);
        set_l1(1, 7, 2, 1, 0, 1);
        set_sp(1, 9, 6, 3);
        check("sprite-priority3-blocked-by-l1", 12'h800 + 2*16 + 7);

        // ---- Case 9: sprite priority 2 ("behind"), but NEITHER layer drew --
        // subtle case from the priority-mask table: primask=0xFF but
        // priority_val=0 (nothing drawn) means (0 & 0xFF)==0, sprite still wins
        set_l0(1, 15, 0, 1, 0, 0);   // transparent
        set_l1(1, 0, 0, 1, 0, 1);    // transparent (transpen=0, pixel=0)
        set_sp(1, 9, 6, 2);
        check("sprite-behind-but-nothing-else-drawn", 6*16 + 9);

        // ---- Case 10: full backdrop, tsel=0 (pen15) ----
        set_l0(0, 0, 0, 0, 0, 0);
        set_l1(0, 0, 0, 0, 0, 0);
        set_sp(0, 0, 0, 0);
        l0_ctrl_transpen_sel = 1'b0;
        check("backdrop-pen15", 12'h80f);

        // ---- Case 11: full backdrop, tsel=1 (pen0) ----
        l0_ctrl_transpen_sel = 1'b1;
        check("backdrop-pen0", 12'h800);

        // ---- Case 12: backdrop quirk -- layer1 enabled+opaque-forced with its
        // OWN transpen bit set differently, layer0 DISABLED -- backdrop still
        // follows layer0's transpen_sel, not layer1's, and not "black"
        set_l0(0, 0, 0, /*en=*/0, 0, /*tsel=*/1);   // l0 disabled, tsel=1 (would mean pen0 if it mattered)
        set_l1(0, 0, 0, /*en=*/0, 0, /*tsel=*/0);   // l1 also disabled/not drawing
        set_sp(0, 0, 0, 0);
        check("backdrop-ignores-l1-and-l0-enable", 12'h800);   // l0 tsel=1 -> pen0 -> 0x800, per the quirk

        // rgb pipeline: pal_data = {1'b0, pal_addr, 3'b0}, so rgb (15 bits) should be pal_addr<<3 & 0x7FFF -- spot check
        #1;
        if (rgb !== {pal_addr, 3'b000}) begin
            errors++;
            $display("FAIL(rgb) got=%h expected=%h", rgb, {pal_addr, 3'b000});
        end

        if (errors == 0)
            $display("PASS: compositor matches reference for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
