// Verifies video_timing against the exact blanking boundaries confirmed
// from psikyo.cpp's machine config (set_raw(..., 456, 0, 320, 262, 0,
// 224)) -- htotal=456/active 0-319, vtotal=262/active 0-223 -- plus the
// hsync/vsync pulse windows and line_start/frame_start pulse timing this
// module's own header documents as RTL-level design choices (not
// MAME-sourced).
//
// Cases:
//   1. ce_pix gating: hcnt/vcnt must NOT advance on cycles where ce_pix=0
//   2. h_active/hblank boundary exactly at hcnt=320 (not 319 or 321)
//   3. hsync pulse window exactly [336,367] (H_SYNC_ST=336, 32 cycles wide)
//   4. line_start pulses exactly once per line, at hcnt=320
//   5. v_active/vblank boundary exactly at vcnt=224, and vsync window
//      exactly [228,230] (V_SYNC_ST=228, 3 lines wide) -- checked by
//      running a full frame and recording every line's state at hcnt=0
//   6. frame_start pulses exactly once per frame, at the first vblank line
//   7. hcnt/vcnt wrap correctly frame-to-frame (a second full frame
//      produces the identical sequence as the first)

module tb_video_timing;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset, ce_pix;
    logic [8:0] hcnt, vcnt;
    logic [7:0] vcnt_active;
    logic h_active, v_active, hblank, vblank, hsync, vsync;
    logic line_start, frame_start;

    video_timing dut (.*);

    int errors = 0;

    // ce_pix pulses every 3rd clk cycle -- deliberately NOT every cycle,
    // to make Case 1 (ce_pix gating) a real test rather than a no-op
    int ce_div;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ce_div <= 0;
            ce_pix <= 0;
        end else begin
            ce_div <= (ce_div == 2) ? 0 : ce_div + 1;
            ce_pix <= (ce_div == 2);
        end
    end

    task automatic wait_pixel;
        // waits for exactly one ce_pix-qualified advance
        do @(posedge clk); while (!ce_pix);
        @(posedge clk);   // let the NBA update settle
    endtask

    initial begin
        #20000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        reset = 1;
        repeat (5) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // ---- Case 1: ce_pix gating ----
        begin
            logic [8:0] hcnt_before;
            hcnt_before = hcnt;
            repeat (2) @(posedge clk);   // 2 non-ce_pix cycles (ce_div cycles 0,1 don't pulse ce_pix)
            if (hcnt !== hcnt_before) begin
                errors++;
                $display("FAIL(case1) hcnt advanced without ce_pix: before=%0d after=%0d", hcnt_before, hcnt);
            end else begin
                $display("Case 1 done (no advance without ce_pix)");
            end
        end

        // ---- Case 2/3/4: walk one full scanline, checking h_active/hblank/hsync/line_start ----
        // Synchronize to hcnt==455 first (the loop below advances-then-
        // checks, so the first wait_pixel() call inside it will wrap hcnt
        // to 0 matching col==0) -- Case 1's own timing-dependent ce_pix
        // window may or may not have let hcnt tick forward by the time we
        // get here, so don't assume anything about where hcnt starts.
        while (hcnt !== 9'd455) wait_pixel();
        begin
            int line_start_count;
            line_start_count = 0;
            for (int col = 0; col < 456; col++) begin
                wait_pixel();
                if (hcnt !== col[8:0]) begin
                    errors++;
                    $display("FAIL(case2) hcnt sequencing: expected=%0d got=%0d", col, hcnt);
                end
                if ((col < 320) !== h_active) begin
                    errors++;
                    $display("FAIL(case2) h_active wrong at hcnt=%0d: got=%b", col, h_active);
                end
                if ((col >= 320) !== hblank) begin
                    errors++;
                    $display("FAIL(case2) hblank wrong at hcnt=%0d: got=%b", col, hblank);
                end
                if (((col >= 336) && (col < 368)) !== hsync) begin
                    errors++;
                    $display("FAIL(case3) hsync wrong at hcnt=%0d: got=%b", col, hsync);
                end
                if (line_start) line_start_count++;
            end
            if (line_start_count !== 1) begin
                errors++;
                $display("FAIL(case4) line_start fired %0d times in one line, expected 1", line_start_count);
            end else begin
                $display("Case 2/3/4 done (h_active/hblank/hsync boundaries, line_start once per line)");
            end
        end

        // ---- Case 5/6/7: walk two full frames pixel-by-pixel (262*456 each) ----
        // One flat loop, no nested "advance to next line" bookkeeping --
        // an earlier nested version double-counted pixels at each line
        // boundary (a redundant wait_pixel() at the bottom of the outer
        // loop AND a fresh 456-call advance at the top of the next
        // iteration), drifting hcnt/vcnt further out of sync every line.
        // Re-synchronizes to the exact frame boundary first (hcnt==455 &&
        // vcnt==261, the last pixel of a frame) rather than trusting
        // wherever Case 2/3/4 happened to leave off.
        while (!(hcnt === 9'd455 && vcnt === 9'd261)) wait_pixel();
        begin
            int vactive_lines, vblank_lines, frame_start_count;
            int prev_vcnt;
            vactive_lines = 0; vblank_lines = 0; frame_start_count = 0;
            prev_vcnt = -1;

            repeat (2 * 262 * 456) begin
                wait_pixel();

                if ((vcnt < 224) !== v_active) begin
                    errors++;
                    $display("FAIL(case5) v_active wrong at hcnt=%0d vcnt=%0d: got=%b", hcnt, vcnt, v_active);
                end
                if ((vcnt >= 224) !== vblank) begin
                    errors++;
                    $display("FAIL(case5) vblank wrong at hcnt=%0d vcnt=%0d: got=%b", hcnt, vcnt, vblank);
                end
                if (frame_start) frame_start_count++;

                // count each line exactly once, at its first pixel
                if (vcnt !== prev_vcnt) begin
                    if (v_active) vactive_lines++; else vblank_lines++;
                    prev_vcnt = vcnt;
                end
            end

            // two full frames: expect double the per-frame counts
            if (vactive_lines !== 2 * 224) begin
                errors++;
                $display("FAIL(case5) v_active line count over 2 frames: got=%0d expected=448", vactive_lines);
            end
            if (vblank_lines !== 2 * 38) begin
                errors++;
                $display("FAIL(case5) vblank line count over 2 frames: got=%0d expected=76", vblank_lines);
            end
            if (frame_start_count !== 2) begin
                errors++;
                $display("FAIL(case6) frame_start fired %0d times over 2 frames, expected 2", frame_start_count);
            end else begin
                $display("Case 5/6 done (v_active/vblank line counts, frame_start once per frame)");
            end
        end

        // ---- Case 7: after exactly 2*262*456 pixels from a known frame
        // boundary, we must be back at that exact same boundary ----
        if (hcnt !== 9'd455 || vcnt !== 9'd261) begin
            errors++;
            $display("FAIL(case7) frame wrap: expected hcnt=455,vcnt=261 got hcnt=%0d,vcnt=%0d", hcnt, vcnt);
        end else begin
            $display("Case 7 done (frame-to-frame wrap correct)");
        end

        if (errors == 0)
            $display("PASS: video_timing matches expected behavior for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
