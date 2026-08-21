// Exercises sprite_display_list_walker against a synchronous spriteram
// model, checking: early 0xFFFF termination, exhausting all 1023 entries
// with no terminator, mod-768 wraparound on out-of-range indices, and an
// immediate terminator (zero entries).
//
// `advance` is held high for the list-walking cases (run_walk) -- those
// only care about the entry_valid/sprite_index/done sequence, not exact
// cycle count, and a free-running advance replicates the pre-flow-control
// timing closely enough (one extra hold cycle per entry) that behavior is
// unaffected. A dedicated case below drives `advance` directly to check
// the hold/backpressure behavior itself: entry_valid/sprite_index must
// stay stable and busy must stay high while advance is held low, and the
// walker must not silently skip ahead.

module tb_sprite_display_list_walker;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;
    logic start, busy;
    logic advance;
    logic [11:0] sram_addr;
    logic [15:0] sram_data;
    logic         entry_valid;
    logic [9:0]  sprite_index;
    logic         done;

    sprite_display_list_walker dut (.*);

    // synchronous spriteram model -- display list region only (word offsets
    // 0xC00-0xFFE), 1-cycle read latency matching the DUT's assumption.
    logic [15:0] mem [0:4095];
    always_ff @(posedge clk) sram_data <= mem[sram_addr];

    int errors;
    int got_count;
    int got_indices[2000];

    task automatic run_walk(string label);
        got_count = 0;
        advance = 1'b1;
        reset = 1;
        @(posedge clk); @(posedge clk);
        reset = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // run until done pulses or a generous timeout (3 cycles/entry now
        // that S_HOLD adds one cycle vs. the pre-flow-control 2 cycles/entry,
        // times 1023 entries, plus headroom)
        for (int i = 0; i < 5000; i++) begin
            @(posedge clk);
            if (entry_valid) begin
                got_indices[got_count] = sprite_index;
                got_count++;
            end
            if (done) begin
                @(posedge clk); // let busy settle
                return;
            end
        end
        errors++;
        $display("FAIL(%s) timed out waiting for done", label);
    endtask

    task automatic check_result(string label, int exp_count, int exp_indices[]);
        if (got_count !== exp_count) begin
            errors++;
            $display("FAIL(%s) entry count: got=%0d expected=%0d", label, got_count, exp_count);
            return;
        end
        for (int i = 0; i < exp_count; i++) begin
            if (got_indices[i] !== exp_indices[i]) begin
                errors++;
                if (errors <= 10)
                    $display("FAIL(%s) entry %0d: got=%0d expected=%0d", label, i, got_indices[i], exp_indices[i]);
            end
        end
        if (busy !== 1'b0) begin
            errors++;
            $display("FAIL(%s) busy still asserted after done", label);
        end
    endtask

    initial begin
        errors = 0;
        start = 0;

        // --- Case 1: short list, early terminator, includes a mod-768 wrap value
        for (int i = 0; i < 4096; i++) mem[i] = 16'h0000;
        mem[12'hC00] = 16'd5;
        mem[12'hC01] = 16'd767;
        mem[12'hC02] = 16'd768;    // wraps to 0
        mem[12'hC03] = 16'd769;    // wraps to 1
        mem[12'hC04] = 16'd65534; // 65534 % 768 = 254 (NOT 65535/0xFFFF -- that value IS the
                                    // terminator sentinel by definition, can't double as data)
        mem[12'hC05] = 16'hFFFF;  // terminator
        run_walk("short_list");
        begin
            automatic int exp[5] = '{5, 767, 0, 1, 254};
            check_result("short_list", 5, exp);
        end

        // --- Case 2: immediate terminator, zero entries
        for (int i = 0; i < 4096; i++) mem[i] = 16'h0000;
        mem[12'hC00] = 16'hFFFF;
        run_walk("immediate_terminator");
        begin
            automatic int exp[1];
            check_result("immediate_terminator", 0, exp);
        end

        // --- Case 3: exhaust all 1023 entries, no terminator anywhere
        for (int i = 0; i < 4096; i++) mem[i] = 16'h0000;
        for (int i = 0; i < 1023; i++) mem[12'hC00 + i] = i[15:0]; // all < 768*... some will wrap
        run_walk("exhausted_list");
        begin
            automatic int exp[1023];
            for (int i = 0; i < 1023; i++) exp[i] = i % 768;
            check_result("exhausted_list", 1023, exp);
        end

        // --- Case 4: backpressure -- hold `advance` low for several cycles
        // after the first entry_valid pulse, confirm the walker holds
        // (sprite_index stable, busy stays high, second entry NOT fetched
        // early), then advance and confirm it proceeds correctly.
        for (int i = 0; i < 4096; i++) mem[i] = 16'h0000;
        mem[12'hC00] = 16'd42;
        mem[12'hC01] = 16'd99;
        mem[12'hC02] = 16'hFFFF;
        begin
            automatic logic [9:0] held_index;
            advance = 1'b0;
            reset = 1;
            @(posedge clk); @(posedge clk);
            reset = 0;
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            // wait for the first entry_valid pulse
            while (!entry_valid) @(posedge clk);
            if (sprite_index !== 10'd42) begin
                errors++;
                $display("FAIL(backpressure) first entry: got=%0d expected=42", sprite_index);
            end
            held_index = sprite_index;

            // hold advance low for several cycles -- must not advance
            for (int i = 0; i < 5; i++) begin
                @(posedge clk);
                if (entry_valid) begin
                    errors++;
                    $display("FAIL(backpressure) entry_valid pulsed again while advance held low");
                end
                if (sprite_index !== held_index) begin
                    errors++;
                    $display("FAIL(backpressure) sprite_index changed while held: got=%0d expected=%0d", sprite_index, held_index);
                end
                if (!busy) begin
                    errors++;
                    $display("FAIL(backpressure) busy dropped while held");
                end
            end

            // now advance -- should fetch entry 2 (value 99), then terminate
            advance = 1'b1;
            @(posedge clk);
            advance = 1'b0; // one-cycle pulse is enough; walker only samples it in S_HOLD
            while (!entry_valid && !done) @(posedge clk);
            if (!entry_valid || sprite_index !== 10'd99) begin
                errors++;
                $display("FAIL(backpressure) second entry: entry_valid=%b got=%0d expected=99", entry_valid, sprite_index);
            end
            advance = 1'b1;
            while (!done) @(posedge clk);
            @(posedge clk);
            if (busy !== 1'b0) begin
                errors++;
                $display("FAIL(backpressure) busy still asserted after done");
            end
        end
        $display("backpressure case done");

        if (errors == 0)
            $display("PASS: sprite_display_list_walker matches reference for all cases (short list w/ mod-768 wrap, immediate terminator, exhausted 1023-entry list, backpressure hold)");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
