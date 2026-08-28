// Replays the ACTUAL captured VRAM1 content and ACTUAL layer-1 config from
// the paused Gunbird title screen (real hardware, 2026-08-29) through the
// real tilemap_line_engine.sv + dpram.sv, to check whether the RTL
// simulation reproduces the bug seen on hardware: word 0x080 (0x802100)
// holds 0x2010 (tile_low13=0x010, own color bits=1), and the CORRECT
// behavior (tile+color both from this one word, per tile_cell_decode.sv's
// single-word design) would give color=65 (1+LAYER_BASE). Real hardware,
// measured via a JTAG VRAM-write probe, instead showed color=64 -- as if
// color came from the ADJACENT word 0x081 (0x000A, own color bits=0,
// 0+64=64) instead.
//
// tb_tilemap_addr_trace.sv already tested this exact mode/bank config
// (mode 3, bank 1) with a SYNTHETIC self-describing VRAM pattern and found
// no split. This testbench is the direct follow-up: same DUT, same config,
// but with the REAL captured VRAM1 content (sim/tilemap_addr_trace_tb/
// real_vram1_dump.hex, extracted from a trace-overlay screenshot of the
// actual paused game) and the REAL scroll registers (base_x_scroll=0x140,
// base_y_scroll=0, read from the same screenshot) -- so if there's a
// data-dependent bug invisible to a low-entropy synthetic pattern (this
// project has hit exactly that class of gap once already, see
// docs/phase1_sdram_map.md's gfx-ROM byte-order bug, invisible to
// all-zero test content), this is the test that would catch it.
//
// Base-x-scroll=0x140=320 means tile_col=0 (our target, vram_index=128 in
// mode 3's row*32+col with row=4) is reached at fetch_eff_x = (320+screen_x)
// mod 512 in [0,15], i.e. screen_x=192 (native, pre-rotation) -- but this
// testbench doesn't need screen_x at all, it just needs base_x_scroll set
// correctly so the FETCH sequence's tile_col values land on the same
// addresses as they did in tb_tilemap_addr_trace.sv's mode3/bank1
// scenario, letting the SAME confirm/deny check apply.

module tb_tilemap_real_data;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;
    logic [7:0] vcnt;
    logic       h_active, line_start, ce_pix;

    logic [1:0]  mode;
    logic [15:0] base_x_scroll, base_y_scroll;
    logic [1:0]  bank;
    logic        rowscroll_enable, rowscroll_pertile;

    logic [7:0]  rowscroll_addr;
    logic [15:0] rowscroll_data;

    logic [11:0] vram_addr;
    logic [15:0] vram_data;

    logic        gfxrom_req;
    logic [21:0] gfxrom_addr;
    logic        gfxrom_valid;
    logic [63:0] gfxrom_data;

    logic        pixel_valid;
    logic [3:0]  pixel_index;
    logic [6:0]  pixel_color;
    logic        fetch_overrun;

    logic [11:0] dbg_fetch_vram_addr;
    logic [15:0] dbg_vram_data;
    logic [14:0] dbg_cell_tile_number;
    logic [6:0]  dbg_cell_color;
    logic [1:0]  dbg_mode_latched;
    logic [1:0]  dbg_bank_latched;
    logic [11:0] dbg_pixel_src_addr;
    logic [15:0] dbg_pixel_src_word;

    assign ce_pix = 1'b1;

    tilemap_line_engine #(.LAYER(1)) dut (
        .clk(clk), .reset(reset),
        .vcnt(vcnt), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
        .mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll), .bank(bank),
        .rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile),
        .rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
        .vram_addr(vram_addr), .vram_data(vram_data),
        .gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr),
        .gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
        .pixel_valid(pixel_valid), .pixel_index(pixel_index), .pixel_color(pixel_color),
        .fetch_overrun(fetch_overrun),
        .dbg_fetch_vram_addr(dbg_fetch_vram_addr), .dbg_vram_data(dbg_vram_data),
        .dbg_cell_tile_number(dbg_cell_tile_number), .dbg_cell_color(dbg_cell_color),
        .dbg_mode_latched(dbg_mode_latched), .dbg_bank_latched(dbg_bank_latched),
        .dbg_pixel_src_addr(dbg_pixel_src_addr), .dbg_pixel_src_word(dbg_pixel_src_word)
    );

    logic [11:0] vram1_a_addr;
    logic [15:0] vram1_a_wdata, vram1_a_rdata;

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
        .clk(clk),
        .a_addr(vram1_a_addr), .a_wel(1'b0), .a_weh(1'b0),
        .a_wdata(vram1_a_wdata), .a_rdata(vram1_a_rdata),
        .b_addr(vram_addr), .b_rdata(vram_data)
    );
    assign vram1_a_addr  = 12'd0;
    assign vram1_a_wdata = 16'd0;

    logic [15:0] rowscroll_mem [0:255];
    always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

    int gfxrom_delay;
    always_ff @(posedge clk) begin
        if (reset) begin
            gfxrom_valid <= 1'b0;
            gfxrom_delay <= 0;
        end else begin
            gfxrom_valid <= 1'b0;
            if (gfxrom_req && gfxrom_delay == 0) begin
                gfxrom_delay <= 3;
            end else if (gfxrom_delay > 0) begin
                if (gfxrom_delay == 1) begin
                    gfxrom_data  <= 64'h0;
                    gfxrom_valid <= 1'b1;
                end
                gfxrom_delay <= gfxrom_delay - 1;
            end
        end
    end

    // ---- preload: REAL captured VRAM1 content, not a synthetic pattern.
    // Path is relative to the simulator's CWD, which per this project's own
    // established convention (docs/LESSONS_LEARNED.md's $readmemh notes)
    // must be the testbench's own directory for a relative path to resolve
    // -- vsim is launched from sim/tilemap_addr_trace_tb/ same as the
    // sibling testbench in this same directory. ----
    initial begin
        $readmemh("real_vram1_dump.hex", u_vram1.mem);
        for (int i = 0; i < 256; i++)
            rowscroll_mem[i] = 16'h0000;   // rowscroll_enable=0 for this config, unused
    end

    // ---- drive: the REAL layer-1 config read off the same screenshot --
    // mode=3, bank=1, base_x_scroll=0x140, base_y_scroll=0x0000,
    // rowscroll disabled (vreg_decode.sv's ADDR_L1_XSCROLL/YSCROLL/CTRL,
    // decoded control word 0x04D0). ----
    task automatic run;
        reset = 1;
        mode = 2'd3;
        base_x_scroll = 16'h0140;
        base_y_scroll = 16'h0000;
        bank = 2'd1;
        rowscroll_enable = 1'b0;
        rowscroll_pertile = 1'b0;
        // base_x_scroll=0x140 shifts the first fetched tile_col to 20 (not
        // 0). tile_col is recomputed fresh from fetch_eff_x through
        // tilemap_coord's own 0x1FF mask each tile (not a free-running
        // 8-bit counter), so it wraps correctly at 32: fetch_eff_x=320+16k,
        // masked to 9 bits, tile_col=masked[8:4]. At k=12, fetch_eff_x=512,
        // masked_x=0, tile_col=0 -- vram_index=row*32+0=128 needs row=4,
        // same as the row tb_tilemap_addr_trace.sv's mode3/bank1 scenario
        // used with base_x_scroll=0 (col=0 at k=0 there instead). vcnt=64
        // -> tile_row=vcnt>>4=4.
        vcnt = 8'd64;
        h_active = 1'b0;
        line_start = 1'b0;

        repeat (4) @(posedge clk);
        reset = 0;
        repeat (4) @(posedge clk);

        line_start = 1'b1;
        @(posedge clk);
        line_start = 1'b0;

        repeat (100) @(posedge clk);

        h_active = 1'b1;
        repeat (320) @(posedge clk);
        h_active = 1'b0;

        repeat (10) @(posedge clk);
    endtask

    // ---- targeted check: this is NOT the generic self-consistency sweep
    // (that check relied on the synthetic pattern's self-describing
    // property, which real captured data does not have). Instead, check
    // the SPECIFIC known real values directly: word 0x080 = 0x2010 means
    // tile_low13=0x010, own color bits=1. CORRECT behavior (single-word
    // design) gives tile_number=0x010+bank*0x2000=8208, color=1+64=65.
    // The hardware bug would show color=64 instead (as if sourced from
    // word 0x081=0x000A's own color bits=0, 0+64=64). ----
    int found_080;
    int mismatch;

    always_ff @(posedge clk) begin
        if (!reset && dut.state == dut.S_CELLDEC && dbg_fetch_vram_addr == 12'h080) begin
            found_080 <= found_080 + 1;
            $display("[fetch 0x080] raw_word=0x%04X tile_number=%0d (0x%04X) color=%0d",
                      dbg_vram_data, dbg_cell_tile_number, dbg_cell_tile_number, dbg_cell_color);
            if (dbg_cell_tile_number !== 15'd8208) begin
                $display("  <-- UNEXPECTED tile_number (expected 8208)");
                mismatch <= mismatch + 1;
            end
            if (dbg_cell_color === 7'd65)
                $display("  -- color=65 (CORRECT: own word's color bits) -- sim did NOT reproduce the hardware bug");
            else if (dbg_cell_color === 7'd64) begin
                $display("  -- color=64 (BUGGY: matches adjacent word 0x081's color bits) -- sim REPRODUCED the hardware bug!");
                mismatch <= mismatch + 1;
            end else begin
                $display("  -- color=%0d (neither 64 nor 65 -- unexpected third value)", dbg_cell_color);
                mismatch <= mismatch + 1;
            end
        end
    end

    // ---- DISPLAY-side trace across the WRAP TRANSITION specifically --
    // logs every S_CELLDEC fetch (address + tile_number + color, so the
    // wrap point col=31->0 i.e. addr=(row*32+31)->(row*32+0) is visible in
    // context) AND every pixel_valid pulse's dbg_pixel_src_addr/word vs
    // pixel_color, checking that the DISPLAYED color for each pixel still
    // matches its own buffered source word -- catches a ring-buffer
    // indexing bug that only manifests right at the wrap, which the
    // fetch-only check above cannot see. ----
    int disp_mismatch;
    int disp_total;

    always_ff @(posedge clk) begin
        if (!reset && dut.state == dut.S_CELLDEC) begin
            $display("[fetch] addr=0x%03X word=0x%04X tile_number=%0d color=%0d%s",
                      dbg_fetch_vram_addr, dbg_vram_data, dbg_cell_tile_number, dbg_cell_color,
                      (dbg_fetch_vram_addr[4:0] == 5'd31 || dbg_fetch_vram_addr[4:0] == 5'd0) ? "  <-- near wrap (col 31 or 0)" : "");
        end
        // display-side check: does the CURRENTLY DISPLAYED pixel_color
        // match its own buffered source word's color field?
        if (!reset && pixel_valid) begin
            disp_total <= disp_total + 1;
            if ((pixel_color - 7'd64) !== {4'd0, dbg_pixel_src_word[15:13]}) begin
                disp_mismatch <= disp_mismatch + 1;
                $display("[display] src_addr=0x%03X src_word=0x%04X pixel_color=%0d  <-- DISPLAY-SIDE MISMATCH (word's own color bits=%0d, displayed color-64=%0d)",
                          dbg_pixel_src_addr, dbg_pixel_src_word, pixel_color,
                          dbg_pixel_src_word[15:13], pixel_color - 7'd64);
            end
        end
    end

    initial begin
        run();
        $display("---- real-data replay done: fetched addr 0x080 %0d time(s), %0d pixels displayed, %0d display-side mismatches ----",
                  found_080, disp_total, disp_mismatch);
        if (found_080 == 0)
            $display("FAIL: never fetched address 0x080 -- check base_x_scroll/mode/bank against the real config");
        else if (mismatch > 0)
            $display("RESULT: sim REPRODUCES the hardware bug (or an unexpected tile_number) -- see log above for detail");
        else
            $display("RESULT: sim does NOT reproduce the hardware bug -- tilemap_line_engine.sv gives the correct color=65 even with real VRAM data, pointing to a sim/hardware divergence (synthesis or timing) rather than an RTL logic bug in this module");
        $finish;
    end

endmodule
