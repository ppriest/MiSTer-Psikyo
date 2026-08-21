// The SDRAM counterpart to tb_video_pipeline_ddram.sv -- same scenario
// (both tilemap layers' gfxrom ports driven simultaneously, under sustained
// multi-line operation, both pointing at the shared "tiles" region), but
// routed through the real SDRAM transport stack (sdram_phy -> sdram (the
// burst-4 controller) -> sdram_chip_model) instead of
// ddram_arbiter/ddram_phy/ddram_model.
//
// This is the direct verification of docs/phase1_sdram_map.md's pivot
// decision, and it went through two real iterations, not a single
// assumed-correct pass -- see docs/phase1_sdram_map.md's "Verification
// results" section for the full writeup:
//
//   1. First version shared ONE arbitrated sdram_phy port between both
//      layers (sdram_arbiter2), matching the port-grouping table as
//      originally drafted. Result: 370/954 mismatches (39%) -- a real,
//      large improvement over DDRAM's 954/954 (100%), but not a full fix.
//   2. Gave each layer its OWN dedicated physical port (sdram.sv's
//      addr0/addr1) -- down to 189/954 (20%), but still not a full fix.
//   3. Root-caused the residual 20% directly (not assumed): even with
//      "dedicated" ports, rtl/memory/sdram/sdram.sv's read-capture pipeline
//      (state/dout/ram_req) is a SINGLE shared resource across all 3
//      ports -- addr0/addr1 only separate the address/data buses, not the
//      underlying transaction. Since both tilemap layers run off the exact
//      same line_start/h_active timing, they request in near-lockstep, and
//      measured per-tile round-trip latency for layer 1 was bimodal: ~15
//      cycles nominal (fits the 16-cycle budget), but ~22 or ~35 cycles on
//      roughly 1-in-5 tiles when contention with layer 0 forced a wait.
//      With only 1 tile ever banked ahead of display (a 2-entry ping-pong),
//      that was an immediate visible miss every time. Widening
//      tilemap_line_engine's prefetch to an 8-entry ring
//      (PREFETCH_DEPTH=8, see that module's own header) gives enough
//      absorption to ride out these stalls -- confirmed clean (0/12720) over
//      40 sustained lines, not just the original 3.
//
// This is a real, verified fix for the exact contention pattern this test
// exercises, not a proof that no contention pattern can ever exceed an
// 8-entry buffer's absorption -- the SDRAM controller's single shared
// pipeline is a genuine hardware constraint (one physical chip, one data
// bus) that a deeper buffer works around rather than removes. The
// architecturally "correct" long-term fix (a faster, independently-clocked
// fetch domain, or a pipelined/overlapping SDRAM controller) remains a
// separate, larger task -- see docs/phase1_sdram_map.md and ROADMAP.md.

module tb_video_pipeline_sdram;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset_vt, reset_l0, reset_l1, reset_sdram;

    localparam logic [24:0] TILES_BASE = 25'h0A40000;

    // ---- video_timing ----
    // ce_pix tied to 1'b1, matching tb_video_pipeline_ddram.sv and every
    // other testbench in this project -- NOT a simplification here. Tried
    // driving a realistic ~1-in-14 ce_pix divider (matching a ~100MHz
    // clk_sys against the real 7.159MHz pixel clock) and found
    // tilemap_line_engine's own internal pixel-consumption logic has no
    // ce_pix input at all -- it consumes one buffered pixel per raw clk
    // cycle, gated only by h_active, with no awareness of a slower pixel
    // domain. Under a divided ce_pix, h_active stays high for 14 consecutive
    // clk cycles per real pixel, and the engine raced through its entire
    // prefetch buffer in a fraction of the time video_timing expects,
    // producing FAR more failures (12426/13356), not fewer -- proving the
    // pixel-domain engines are designed to run with clk==pixel clock
    // throughout (a single-clock-domain video pipeline), not clk_sys with a
    // ce_pix gate. That makes ce_pix=1'b1 the *correct* modeling choice for
    // these engines, not a testbench shortcut -- see
    // docs/phase1_sdram_map.md's update for the corrected conclusion. The
    // fetch/SDRAM side running at a genuinely faster independent clock would
    // need real clock-domain-crossing at the arbiter boundary, a separate,
    // larger design task, not something to bolt on here.
    logic ce_pix;
    assign ce_pix = 1'b1;

    logic [8:0] hcnt, vcnt_raw;
    logic [7:0] vcnt_active;
    logic h_active, v_active, hblank, vblank, hsync, vsync;
    logic line_start, frame_start;

    video_timing vt (
        .clk(clk), .ce_pix(ce_pix), .reset(reset_vt),
        .hcnt(hcnt), .vcnt(vcnt_raw), .vcnt_active(vcnt_active),
        .h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .frame_start(frame_start)
    );

    // ---- tilemap layer 0 ----
    logic [1:0]  l0_mode;
    logic [15:0] l0_base_x_scroll, l0_base_y_scroll;
    logic [1:0]  l0_bank;
    logic         l0_rowscroll_enable, l0_rowscroll_pertile;
    logic [7:0]  l0_rowscroll_addr;
    logic [15:0] l0_rowscroll_data;
    logic [11:0] l0_vram_addr;
    logic [15:0] l0_vram_data;
    logic         l0_gfxrom_req;
    logic [21:0] l0_gfxrom_addr;
    logic         l0_gfxrom_valid;
    logic [63:0] l0_gfxrom_data;
    logic         l0_pixel_valid;
    logic [3:0]  l0_pixel_index;
    logic [6:0]  l0_pixel_color;
    logic         l0_fetch_overrun;

    assign l0_mode = 2'd0;
    assign l0_base_x_scroll = 16'd0;
    assign l0_base_y_scroll = 16'd0;
    assign l0_bank = 2'd0;
    assign l0_rowscroll_enable = 1'b0;
    assign l0_rowscroll_pertile = 1'b0;

    tilemap_line_engine #(.LAYER(0)) tle0 (
        .clk(clk), .reset(reset_l0),
        .vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
        .mode(l0_mode), .base_x_scroll(l0_base_x_scroll), .base_y_scroll(l0_base_y_scroll), .bank(l0_bank),
        .rowscroll_enable(l0_rowscroll_enable), .rowscroll_pertile(l0_rowscroll_pertile),
        .rowscroll_addr(l0_rowscroll_addr), .rowscroll_data(l0_rowscroll_data),
        .vram_addr(l0_vram_addr), .vram_data(l0_vram_data),
        .gfxrom_req(l0_gfxrom_req), .gfxrom_addr(l0_gfxrom_addr), .gfxrom_valid(l0_gfxrom_valid), .gfxrom_data(l0_gfxrom_data),
        .pixel_valid(l0_pixel_valid), .pixel_index(l0_pixel_index), .pixel_color(l0_pixel_color), .fetch_overrun(l0_fetch_overrun)
    );

    logic [15:0] l0_vram [0:4095];
    always_ff @(posedge clk) l0_vram_data <= l0_vram[l0_vram_addr];
    logic [15:0] l0_rowscroll_mem [0:255];
    always_ff @(posedge clk) l0_rowscroll_data <= l0_rowscroll_mem[l0_rowscroll_addr];

    // ---- tilemap layer 1 ----
    logic [1:0]  l1_mode;
    logic [15:0] l1_base_x_scroll, l1_base_y_scroll;
    logic [1:0]  l1_bank;
    logic         l1_rowscroll_enable, l1_rowscroll_pertile;
    logic [7:0]  l1_rowscroll_addr;
    logic [15:0] l1_rowscroll_data;
    logic [11:0] l1_vram_addr;
    logic [15:0] l1_vram_data;
    logic         l1_gfxrom_req;
    logic [21:0] l1_gfxrom_addr;
    logic         l1_gfxrom_valid;
    logic [63:0] l1_gfxrom_data;
    logic         l1_pixel_valid;
    logic [3:0]  l1_pixel_index;
    logic [6:0]  l1_pixel_color;
    logic         l1_fetch_overrun;

    assign l1_mode = 2'd0;
    assign l1_base_x_scroll = 16'd0;
    assign l1_base_y_scroll = 16'd0;
    assign l1_bank = 2'd0;
    assign l1_rowscroll_enable = 1'b0;
    assign l1_rowscroll_pertile = 1'b0;

    tilemap_line_engine #(.LAYER(1)) tle1 (
        .clk(clk), .reset(reset_l1),
        .vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
        .mode(l1_mode), .base_x_scroll(l1_base_x_scroll), .base_y_scroll(l1_base_y_scroll), .bank(l1_bank),
        .rowscroll_enable(l1_rowscroll_enable), .rowscroll_pertile(l1_rowscroll_pertile),
        .rowscroll_addr(l1_rowscroll_addr), .rowscroll_data(l1_rowscroll_data),
        .vram_addr(l1_vram_addr), .vram_data(l1_vram_data),
        .gfxrom_req(l1_gfxrom_req), .gfxrom_addr(l1_gfxrom_addr), .gfxrom_valid(l1_gfxrom_valid), .gfxrom_data(l1_gfxrom_data),
        .pixel_valid(l1_pixel_valid), .pixel_index(l1_pixel_index), .pixel_color(l1_pixel_color), .fetch_overrun(l1_fetch_overrun)
    );

    logic [15:0] l1_vram [0:4095];
    always_ff @(posedge clk) l1_vram_data <= l1_vram[l1_vram_addr];
    logic [15:0] l1_rowscroll_mem [0:255];
    always_ff @(posedge clk) l1_rowscroll_data <= l1_rowscroll_mem[l1_rowscroll_addr];

    // ---- SDRAM transport: DEDICATED port per layer (no arbiter) ----
    // sdram_arbiter2.sv's design is still valid and still needed for ports
    // that genuinely share (sprite gfxrom+spritelut, CPU fetches+download,
    // per docs/phase1_sdram_map.md) -- but tb_video_pipeline_ddram.sv's
    // confirmed failure was specifically the two tilemap layers contending
    // for ONE port at the exact same moment (same line_start/h_active
    // timing). sdram.sv already exposes 3 independent physical ports; giving
    // each tilemap layer its own (port0/port1) removes that contention
    // entirely instead of just making it faster. This is the direct test of
    // whether that's the right fix.
    logic [24:1] p0_addr, p1_addr;
    logic         p0_wrl, p0_wrh, p1_wrl, p1_wrh;
    logic [15:0] p0_din, p1_din;
    logic [63:0] p0_dout, p1_dout;
    logic         p0_req, p1_req, p0_ack, p1_ack;

    logic         p0_phy_req, p0_phy_busy, p0_phy_valid;
    logic [24:0] p0_phy_addr;
    logic         p1_phy_req, p1_phy_busy, p1_phy_valid;
    logic [24:0] p1_phy_addr;

    assign p0_phy_req  = l0_gfxrom_req;
    assign p0_phy_addr = TILES_BASE + {3'd0, l0_gfxrom_addr};
    assign l0_gfxrom_valid = p0_phy_valid;

    assign p1_phy_req  = l1_gfxrom_req;
    assign p1_phy_addr = TILES_BASE + {3'd0, l1_gfxrom_addr};
    assign l1_gfxrom_valid = p1_phy_valid;

    // rdata is sdram.sv's native granule byte order (ascending address ->
    // ascending bit position), NOT the MSB-first order tilemap_line_engine's
    // gfxrom_data port requires -- gfxrom_byte_reorder.sv bridges the two.
    // This test's own ROM content is uniform (all 0x0000, see below), so
    // this fix is a no-op for THIS test's pass/fail result -- it's applied
    // anyway to close a real coverage gap: sim/port2_sdram_tb/
    // tb_port2_sdram.sv found this exact mismatch using non-uniform sprite
    // gfx ROM content, and leaving this test's wiring pattern "wrong but
    // passing" would be a landmine for whoever copies it into real
    // top-level integration later. See rtl/memory/gfxrom_byte_reorder.sv's
    // header for the full story.
    logic [63:0] p0_rdata_native, p1_rdata_native;
    gfxrom_byte_reorder l0_reorder (.sdram_granule(p0_rdata_native), .gfxrom_data(l0_gfxrom_data));
    gfxrom_byte_reorder l1_reorder (.sdram_granule(p1_rdata_native), .gfxrom_data(l1_gfxrom_data));

    sdram_phy phy0 (
        .clk(clk), .reset(reset_sdram),
        .port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh),
        .port_din(p0_din), .port_dout(p0_dout), .port_req(p0_req), .port_ack(p0_ack),
        .req(p0_phy_req), .we(1'b0), .addr(p0_phy_addr), .wdata(8'd0),
        .busy(p0_phy_busy), .valid(p0_phy_valid), .rdata(p0_rdata_native)
    );

    sdram_phy phy1 (
        .clk(clk), .reset(reset_sdram),
        .port_addr(p1_addr), .port_wrl(p1_wrl), .port_wrh(p1_wrh),
        .port_din(p1_din), .port_dout(p1_dout), .port_req(p1_req), .port_ack(p1_ack),
        .req(p1_phy_req), .we(1'b0), .addr(p1_phy_addr), .wdata(8'd0),
        .busy(p1_phy_busy), .valid(p1_phy_valid), .rdata(p1_rdata_native)
    );

    wire [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic         SDRAM_DQML, SDRAM_DQMH;
    logic  [1:0] SDRAM_BA;
    logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    logic         SDRAM_CLK, SDRAM_CKE;

    logic [24:1] unused_addr2;
    logic         unused_wrl2, unused_wrh2;
    logic [15:0] unused_din2;
    logic [63:0] unused_dout2;
    logic         unused_req2, unused_ack2;

    assign unused_addr2 = 24'd0; assign unused_wrl2 = 1'b0; assign unused_wrh2 = 1'b0;
    assign unused_din2  = 16'd0; assign unused_req2 = 1'b0;

    sdram dut (
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .init(1'b0), .clk(clk),
        .addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
        .addr1(p1_addr), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
        .addr2(unused_addr2), .wrl2(unused_wrl2), .wrh2(unused_wrh2), .din2(unused_din2), .dout2(unused_dout2), .req2(unused_req2), .ack2(unused_ack2)
    );

    sdram_chip_model chip (
        .clk(clk),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
    );

    // ---- compositor ----
    logic l1_ctrl_enable_live;
    logic [11:0] pal_addr;
    logic [15:0] pal_data;
    logic [14:0] rgb;

    compositor comp (
        .l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
        .l0_ctrl_enable(1'b1), .l0_ctrl_opaque(1'b1), .l0_ctrl_transpen_sel(1'b1),
        .l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
        .l1_ctrl_enable(l1_ctrl_enable_live), .l1_ctrl_opaque(1'b1), .l1_ctrl_transpen_sel(1'b1),
        .sp_present(1'b0), .sp_pixel(4'd0), .sp_color(5'd0), .sp_priority(2'd0),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .rgb(rgb)
    );

    always_ff @(posedge clk) pal_data <= {3'd0, pal_addr};

    int errors;
    int pixel_checked_count;
    int fail_by_vcnt [0:511];
    int min_fail_hcnt [0:511];
    int max_fail_hcnt [0:511];

    initial begin
        #30000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        errors = 0;
        pixel_checked_count = 0;

        for (int i = 0; i < 4096; i++) l0_vram[i] = 16'h0000;   // tile 0, color 0
        for (int i = 0; i < 4096; i++) l1_vram[i] = 16'h2000;   // tile 0, color 65
        for (int i = 0; i < 256; i++) begin
            l0_rowscroll_mem[i] = 16'h0000;
            l1_rowscroll_mem[i] = 16'h0000;
        end

        l1_ctrl_enable_live = 1'b1;

        reset_vt = 1; reset_l0 = 1; reset_l1 = 1; reset_sdram = 1;
        repeat (15) @(posedge clk);
        reset_vt = 0; reset_l0 = 0; reset_l1 = 0; reset_sdram = 0;

        // let sdram.sv's own power-up mode-register-load sequence finish
        // (same 500-cycle headroom as tb_sdram.sv) before real requests
        // start arriving from the video engines
        repeat (500) @(posedge clk);

        // Seed the shared "tiles" region with a fixed, known 0x0000 pattern
        // at every word tile 0's 16 rows can address (gfxrom_addr =
        // 0 + fine_y*8 bytes, 4 words per row) -- same reasoning as
        // tb_video_pipeline_ddram.sv: a fixed pattern keeps decoded pixel
        // content constant across the whole frame.
        for (int fine_y = 0; fine_y < 16; fine_y++) begin
            for (int w = 0; w < 4; w++) begin
                chip.poke_word_addr((TILES_BASE + 25'(fine_y*8) + 25'(w*2)) >> 1, 16'h0000);
            end
        end

        repeat (3) begin
            do @(posedge clk); while (!line_start);
        end
        @(posedge clk);

        // ---- Case 1: both layers enabled, served through the real SDRAM
        // arbiter/phy/controller -- layer 1 must always win. 40 lines, not
        // 3 -- widened from the original 3-line check specifically to give
        // the periodic SDRAM-contention stalls found during root-causing
        // (see tilemap_line_engine.sv's PREFETCH_DEPTH comment) many chances
        // to recur, not just whatever happened to be in the first 3 lines.
        for (int v = 0; v < 512; v++) begin min_fail_hcnt[v] = -1; max_fail_hcnt[v] = -1; end

        repeat (456 * 40) begin
            @(posedge clk);
            if (h_active && hcnt >= 9'd2) begin
                pixel_checked_count++;
                if (rgb !== 15'h0C10) begin
                    errors++;
                    fail_by_vcnt[vcnt_raw]++;
                    if (min_fail_hcnt[vcnt_raw] == -1) min_fail_hcnt[vcnt_raw] = hcnt;
                    max_fail_hcnt[vcnt_raw] = hcnt;
                end
            end
        end
        $display("Case 1 done (%0d active pixels checked, layer 1 always wins, via real SDRAM arbiter/phy/controller)", pixel_checked_count);

        if (errors == 0)
            $display("PASS: both tilemap layers correctly served through dedicated sdram_phy/sdram ports over 40 sustained lines -- confirms dedicated ports (docs/phase1_sdram_map.md) plus tilemap_line_engine's widened PREFETCH_DEPTH=8 prefetch ring (found necessary by root-causing this exact test's residual failures: rtl/memory/sdram/sdram.sv's 3 ports share one internal transaction pipeline, so simultaneous same-timing requests from both layers occasionally cost one of them a full extra ~15-20 cycle round trip -- a 2-entry ping-pong had no margin to absorb that, an 8-entry ring does) together fix the throughput failure tb_video_pipeline_ddram.sv found");
        else begin
            $display("FAIL: %0d/%0d mismatches -- see tilemap_line_engine.sv's PREFETCH_DEPTH comment and docs/phase1_sdram_map.md's Verification results for the known failure mode this guards against. Do not loosen these checks to force a PASS.", errors, pixel_checked_count);
            for (int v = 0; v < 512; v++)
                if (fail_by_vcnt[v] > 0) $display("  vcnt=%0d: %0d failing pixels, hcnt range [%0d..%0d]", v, fail_by_vcnt[v], min_fail_hcnt[v], max_fail_hcnt[v]);
        end

        $finish;
    end

endmodule
