// Integration measurement for Port 2 of docs/phase1_sdram_map.md's arbiter
// architecture: the real sprite_render_engine (gfxrom + spritelut, both
// req/valid, both already verified in isolation by
// sim/sprite_render_engine_tb/) driven through the real sdram_arbiter5 ->
// sdram (burst-4 controller) -> sdram_chip_model stack, contending against
// synthetic-but-realistic maincpu/audiocpu traffic on the SAME arbiter --
// same "measure, don't assume" approach sim/video_pipeline_tb/
// tb_video_pipeline_sdram.sv used for the two tilemap ports.
//
// maincpu and audiocpu are modeled as synthetic continuous-pressure request
// generators (sequential addresses, back-to-back with no idle gaps) through
// rtl/memory/sdram_narrow_bridge.sv, NOT real CPU wrapper RTL -- neither
// TG68K.C nor a req/valid-converted sound-CPU wrapper exists yet (see
// docs/ROADMAP.md's "Next steps"; the sound-CPU req/valid conversion is a
// separately tracked, still-open bug). Continuous back-to-back requests are
// the correct WORST-CASE traffic shape for measuring arbiter contention
// (a real CPU wouldn't always have a pending fetch, but this is the
// conservative bound, same reasoning tb_video_pipeline_sdram.sv used for
// its own worst-case simultaneous-request scenario), clearly labeled here
// as synthetic so nobody mistakes it for a real integration result.
//
// HPS ioctl_download is deliberately left INACTIVE throughout (dl_req tied
// low) -- unlike maincpu/audiocpu, download genuinely does not overlap with
// gameplay in the real system (it only runs before the video pipeline
// starts, per rtl/memory/ddram_arbiter.sv's own design note), so modeling
// it as simultaneous contention here would test an impossible scenario, not
// a worst case. Its absolute-priority behavior is already verified in
// isolation by sim/sdram_arbiter5_tb/tb_sdram_arbiter5.sv's Case 4.
//
// Two cases:
//   1. Baseline: sprite rendering alone (maincpu/audiocpu idle). Correctness
//      check (reusing tb_sprite_render_engine.sv's Case A reference
//      formula) + frame_done latency measurement.
//   2. Contended: identical sprite scenario, but maincpu and audiocpu are
//      BOTH issuing continuous back-to-back requests on the same arbiter
//      throughout. Same correctness check (does contention ever corrupt a
//      pixel, not just slow things down?) + frame_done latency (real
//      measured slowdown, not assumed) + maincpu/audiocpu round-trip
//      latency distribution under contention.

module tb_port2_sdram;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;

    // ---- region base byte offsets, from docs/phase1_sdram_map.md's
    // address map table ----
    localparam logic [24:0] MAINCPU_BASE   = 25'h0000000;
    localparam logic [24:0] AUDIOCPU_BASE  = 25'h0200000;
    localparam logic [24:0] SPRITES_BASE   = 25'h0240000;
    localparam logic [24:0] SPRITELUT_BASE = 25'h0DC0000;

    // ---- sdram_arbiter5 physical port + sdram + chip model ----
    logic         phy_req, phy_we, phy_busy, phy_valid;
    logic [24:0] phy_addr;
    logic [7:0]  phy_wdata;
    logic [63:0] phy_rdata;

    logic         c0_req, c1_req, c2_req, c3_req;
    logic [24:0] c0_addr, c1_addr, c2_addr, c3_addr;
    logic         c0_valid, c1_valid, c2_valid, c3_valid;
    logic [63:0] c0_data, c1_data, c2_data, c3_data;

    logic         dl_req, dl_busy;
    logic [24:0] dl_addr;
    logic [7:0]  dl_data;
    assign dl_req  = 1'b0;
    assign dl_addr = 25'd0;
    assign dl_data = 8'd0;

    sdram_arbiter5 arb (
        .clk(clk), .reset(reset),
        .phy_req(phy_req), .phy_we(phy_we), .phy_addr(phy_addr), .phy_wdata(phy_wdata),
        .phy_busy(phy_busy), .phy_valid(phy_valid), .phy_rdata(phy_rdata),
        .c0_req(c0_req), .c0_addr(c0_addr), .c0_valid(c0_valid), .c0_data(c0_data),
        .c1_req(c1_req), .c1_addr(c1_addr), .c1_valid(c1_valid), .c1_data(c1_data),
        .c2_req(c2_req), .c2_addr(c2_addr), .c2_valid(c2_valid), .c2_data(c2_data),
        .c3_req(c3_req), .c3_addr(c3_addr), .c3_valid(c3_valid), .c3_data(c3_data),
        .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy)
    );

    logic [24:1] p_addr;
    logic         p_wrl, p_wrh;
    logic [15:0] p_din;
    logic [63:0] p_dout;
    logic         p_req, p_ack;

    logic [24:1] unused_addr1, unused_addr2;
    logic         unused_wrl1, unused_wrh1, unused_wrl2, unused_wrh2;
    logic [15:0] unused_din1, unused_din2;
    logic [63:0] unused_dout1, unused_dout2;
    logic         unused_req1, unused_ack1, unused_req2, unused_ack2;
    assign unused_addr1 = 24'd0; assign unused_wrl1 = 1'b0; assign unused_wrh1 = 1'b0;
    assign unused_din1  = 16'd0; assign unused_req1 = 1'b0;
    assign unused_addr2 = 24'd0; assign unused_wrl2 = 1'b0; assign unused_wrh2 = 1'b0;
    assign unused_din2  = 16'd0; assign unused_req2 = 1'b0;

    wire [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic         SDRAM_DQML, SDRAM_DQMH;
    logic  [1:0] SDRAM_BA;
    logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    logic         SDRAM_CLK, SDRAM_CKE;

    sdram mem_ctrl (
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .init(1'b0), .clk(clk),
        .addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
        .addr1(unused_addr1), .wrl1(unused_wrl1), .wrh1(unused_wrh1), .din1(unused_din1), .dout1(unused_dout1), .req1(unused_req1), .ack1(unused_ack1),
        .addr2(unused_addr2), .wrl2(unused_wrl2), .wrh2(unused_wrh2), .din2(unused_din2), .dout2(unused_dout2), .req2(unused_req2), .ack2(unused_ack2)
    );

    sdram_chip_model chip (
        .clk(clk),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
    );

    sdram_phy phy (
        .clk(clk), .reset(reset),
        .port_addr(p_addr), .port_wrl(p_wrl), .port_wrh(p_wrh),
        .port_din(p_din), .port_dout(p_dout), .port_req(p_req), .port_ack(p_ack),
        .req(phy_req), .we(phy_we), .addr(phy_addr), .wdata(phy_wdata),
        .busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
    );

    // ---- sprite_render_engine (real) ----
    logic         frame_start, frame_busy, frame_done;
    logic         trans_pen0, trans_pen15;
    logic [11:0] dl_bram_addr;
    logic [15:0] dl_bram_data;
    logic [11:0] at_addr;
    logic [15:0] at_data;
    logic         lut_req;
    logic [16:0] lut_addr;
    logic         lut_valid;
    logic [15:0] lut_data;
    logic         gfxrom_req;
    logic [22:0] gfxrom_addr;
    logic         gfxrom_valid;
    logic [63:0] gfxrom_data;
    logic         fb_we;
    logic [8:0]  fb_x;
    logic [7:0]  fb_y;
    logic [3:0]  fb_pixel;
    logic [4:0]  fb_color;
    logic [1:0]  fb_priority;

    sprite_render_engine sre (
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .frame_busy(frame_busy), .frame_done(frame_done),
        .trans_pen0(trans_pen0), .trans_pen15(trans_pen15),
        .dl_addr(dl_bram_addr), .dl_data(dl_bram_data),
        .at_addr(at_addr), .at_data(at_data),
        .lut_req(lut_req), .lut_addr(lut_addr), .lut_valid(lut_valid), .lut_data(lut_data),
        .gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr), .gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
        .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_pixel(fb_pixel), .fb_color(fb_color), .fb_priority(fb_priority)
    );

    logic [15:0] dl_mem [0:4095];
    logic [15:0] at_mem [0:4095];
    always_ff @(posedge clk) dl_bram_data <= dl_mem[dl_bram_addr];
    always_ff @(posedge clk) at_data       <= at_mem[at_addr];

    // gfxrom: connects to arbiter c0 (already 8-byte-aligned, see
    // rtl/memory/sdram_arbiter5.sv's header) -- zero-extend the 23-bit
    // region-relative address and add SPRITES_BASE. c0_data is sdram.sv's
    // native granule byte order, NOT the MSB-first order
    // sprite_render_engine's gfxrom_data port requires -- see
    // rtl/memory/gfxrom_byte_reorder.sv's header for the real bug this
    // fixes (found by this test's own non-uniform gradient tile content).
    assign c0_req  = gfxrom_req;
    assign c0_addr = SPRITES_BASE + {2'd0, gfxrom_addr};
    assign gfxrom_valid = c0_valid;

    gfxrom_byte_reorder gfx_reorder (
        .sdram_granule(c0_data),
        .gfxrom_data(gfxrom_data)
    );

    // spritelut: 17-bit WORD address -> byte address via <<1, through the
    // narrow bridge (16-bit word) onto arbiter c1.
    logic         lutb_g_req, lutb_g_valid;
    logic [24:0] lutb_g_addr;
    logic [63:0] lutb_g_data;

    sdram_narrow_bridge #(.WORD_BYTES(2)) lut_bridge (
        .clk(clk), .reset(reset),
        .req(lut_req), .addr(SPRITELUT_BASE + {lut_addr, 1'b0}),
        .valid(lut_valid), .data(lut_data),
        .g_req(lutb_g_req), .g_addr(lutb_g_addr), .g_valid(lutb_g_valid), .g_data(lutb_g_data)
    );
    assign c1_req  = lutb_g_req;
    assign c1_addr = lutb_g_addr;
    assign lutb_g_valid = c1_valid;
    assign lutb_g_data  = c1_data;

    // ---- synthetic maincpu traffic (continuous back-to-back word fetches,
    // sequential addresses within MAINCPU_BASE's region) -- see this file's
    // header for why continuous pressure is the right worst-case shape and
    // why this is synthetic, not real CPU RTL ----
    logic         mc_en;
    logic         mc_req, mc_valid;
    logic [24:0] mc_addr;
    logic [15:0] mc_data;
    logic         mcb_g_req, mcb_g_valid;
    logic [24:0] mcb_g_addr;
    logic [63:0] mcb_g_data;

    sdram_narrow_bridge #(.WORD_BYTES(2)) maincpu_bridge (
        .clk(clk), .reset(reset),
        .req(mc_req), .addr(mc_addr), .valid(mc_valid), .data(mc_data),
        .g_req(mcb_g_req), .g_addr(mcb_g_addr), .g_valid(mcb_g_valid), .g_data(mcb_g_data)
    );
    assign c2_req  = mcb_g_req;
    assign c2_addr = mcb_g_addr;
    assign mcb_g_valid = c2_valid;
    assign mcb_g_data  = c2_data;

    logic [15:0] mc_pc;
    logic         mc_busy;
    int mc_start_cyc, mc_cyc;
    int mc_lat_min, mc_lat_max, mc_lat_sum, mc_lat_count;
    always_ff @(posedge clk) mc_cyc <= mc_cyc + 1;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            mc_pc <= 16'd0; mc_req <= 1'b0; mc_busy <= 1'b0;
            mc_lat_min <= 32'h7fffffff; mc_lat_max <= 0; mc_lat_sum <= 0; mc_lat_count <= 0;
        end else if (mc_en) begin
            if (!mc_busy) begin
                mc_addr      <= MAINCPU_BASE + {mc_pc, 1'b0};
                mc_req       <= 1'b1;
                mc_busy      <= 1'b1;
                mc_start_cyc <= mc_cyc;
            end else begin
                mc_req <= 1'b0;
                if (mc_valid) begin
                    automatic int lat = mc_cyc - mc_start_cyc;
                    if (lat < mc_lat_min) mc_lat_min <= lat;
                    if (lat > mc_lat_max) mc_lat_max <= lat;
                    mc_lat_sum   <= mc_lat_sum + lat;
                    mc_lat_count <= mc_lat_count + 1;
                    mc_pc   <= mc_pc + 16'd1;
                    mc_busy <= 1'b0;
                end
            end
        end else begin
            mc_req <= 1'b0;
            mc_busy <= 1'b0;
        end
    end

    // ---- synthetic audiocpu traffic (continuous back-to-back byte
    // fetches, same reasoning as maincpu above, narrower WORD_BYTES=1) ----
    logic         ac_en;
    logic         ac_req, ac_valid;
    logic [24:0] ac_addr;
    logic [7:0]  ac_data;
    logic         acb_g_req, acb_g_valid;
    logic [24:0] acb_g_addr;
    logic [63:0] acb_g_data;

    sdram_narrow_bridge #(.WORD_BYTES(1)) audiocpu_bridge (
        .clk(clk), .reset(reset),
        .req(ac_req), .addr(ac_addr), .valid(ac_valid), .data(ac_data),
        .g_req(acb_g_req), .g_addr(acb_g_addr), .g_valid(acb_g_valid), .g_data(acb_g_data)
    );
    assign c3_req  = acb_g_req;
    assign c3_addr = acb_g_addr;
    assign acb_g_valid = c3_valid;
    assign acb_g_data  = c3_data;

    logic [15:0] ac_pc;
    logic         ac_busy;
    int ac_start_cyc;
    int ac_lat_min, ac_lat_max, ac_lat_sum, ac_lat_count;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ac_pc <= 16'd0; ac_req <= 1'b0; ac_busy <= 1'b0;
            ac_lat_min <= 32'h7fffffff; ac_lat_max <= 0; ac_lat_sum <= 0; ac_lat_count <= 0;
        end else if (ac_en) begin
            if (!ac_busy) begin
                ac_addr      <= AUDIOCPU_BASE + {17'd0, ac_pc};
                ac_req       <= 1'b1;
                ac_busy      <= 1'b1;
                ac_start_cyc <= mc_cyc;
            end else begin
                ac_req <= 1'b0;
                if (ac_valid) begin
                    automatic int lat = mc_cyc - ac_start_cyc;
                    if (lat < ac_lat_min) ac_lat_min <= lat;
                    if (lat > ac_lat_max) ac_lat_max <= lat;
                    ac_lat_sum   <= ac_lat_sum + lat;
                    ac_lat_count <= ac_lat_count + 1;
                    ac_pc   <= ac_pc + 16'd1;
                    ac_busy <= 1'b0;
                end
            end
        end else begin
            ac_req <= 1'b0;
            ac_busy <= 1'b0;
        end
    end

    // ---- frame buffer capture ----
    logic         got_written [0:319][0:223];
    logic [3:0]  got_pixel     [0:319][0:223];
    logic [4:0]  got_color     [0:319][0:223];
    logic [1:0]  got_priority [0:319][0:223];

    always_ff @(posedge clk) begin
        if (fb_we) begin
            got_written[fb_x][fb_y]  <= 1'b1;
            got_pixel[fb_x][fb_y]     <= fb_pixel;
            got_color[fb_x][fb_y]     <= fb_color;
            got_priority[fb_x][fb_y] <= fb_priority;
        end
    end

    task automatic clear_fb;
        for (int x = 0; x < 320; x++)
            for (int y = 0; y < 224; y++)
                got_written[x][y] = 1'b0;
    endtask

    // fills the sprite gfx ROM (chip model backdoor, granule-at-a-time) for
    // `tile_code` with pixel(r,c) = (r+c)%16, matching
    // tb_sprite_render_engine.sv's write_gradient_tile reference pixel
    // values exactly -- but poking the chip using the REAL SDR SDRAM word
    // layout (low byte = even address, high byte = odd address), NOT the
    // gfxrom_data/row_bytes MSB-first convention. gfxrom_byte_reorder.sv
    // (wired into this test's gfxrom path above) is what converts between
    // the two -- poking pre-reordered data here would double-swap and
    // silently produce a DIFFERENT but still self-consistent-looking wrong
    // pattern instead of a crash, which is exactly the kind of bug this
    // test's non-uniform content exists to catch (see
    // rtl/memory/gfxrom_byte_reorder.sv's header for the full story).
    task automatic write_gradient_tile(int tile_code);
        automatic int base_byte = SPRITES_BASE + tile_code * 128;
        for (int r = 0; r < 16; r++) begin
            automatic logic [7:0] rb [0:7];
            for (int k = 0; k < 8; k++) begin
                automatic int p0 = (r + 2*k) % 16;
                automatic int p1 = (r + 2*k + 1) % 16;
                rb[k] = {p0[3:0], p1[3:0]};
            end
            chip.poke_word_addr(25'(base_byte + r*8 + 0) >> 1, {rb[1], rb[0]});
            chip.poke_word_addr(25'(base_byte + r*8 + 2) >> 1, {rb[3], rb[2]});
            chip.poke_word_addr(25'(base_byte + r*8 + 4) >> 1, {rb[5], rb[4]});
            chip.poke_word_addr(25'(base_byte + r*8 + 6) >> 1, {rb[7], rb[6]});
        end
    endtask

    task automatic setup_single_sprite(
        int sprite_idx, int x_pos, int y_pos, int nx_m1, int ny_m1,
        int zoom_x_raw, int zoom_y_raw, int flip_x, int flip_y,
        int color, int pri, int code
    );
        automatic logic [15:0] wy, wx, wattr, wcodelo;
        wy      = {zoom_y_raw[3:0], ny_m1[2:0], y_pos[8:0]};
        wx      = {zoom_x_raw[3:0], nx_m1[2:0], x_pos[8:0]};
        wattr   = {flip_y[0], flip_x[0], 1'b0, color[4:0], pri[1:0], 5'd0, code[16]};
        wcodelo = code[15:0];
        at_mem[sprite_idx*4 + 0] = wy;
        at_mem[sprite_idx*4 + 1] = wx;
        at_mem[sprite_idx*4 + 2] = wattr;
        at_mem[sprite_idx*4 + 3] = wcodelo;

        dl_mem[12'hC00] = sprite_idx[15:0];
        dl_mem[12'hC01] = 16'hFFFF;
    endtask

    int frame_start_cyc, frame_latency;

    task automatic run_frame;
        frame_start = 1;
        @(posedge clk);
        frame_start = 0;
        frame_start_cyc = mc_cyc;
        for (int i = 0; i < 20000; i++) begin
            @(posedge clk);
            if (frame_done) begin
                frame_latency = mc_cyc - frame_start_cyc;
                return;
            end
        end
        $display("TIMEOUT waiting for frame_done");
        frame_latency = -1;
    endtask

    int errors;

    task automatic check_pixel(string label, int x, int y, int exp_written, int exp_pixel, int exp_color, int exp_pri);
        if (got_written[x][y] !== exp_written[0:0]) begin
            errors++;
            if (errors <= 20)
                $display("FAIL(%s) (%0d,%0d) written: got=%b expected=%b", label, x, y, got_written[x][y], exp_written);
            return;
        end
        if (exp_written && (got_pixel[x][y] !== exp_pixel[3:0] || got_color[x][y] !== exp_color[4:0] || got_priority[x][y] !== exp_pri[1:0])) begin
            errors++;
            if (errors <= 20)
                $display("FAIL(%s) (%0d,%0d) got=(pix=%0d col=%0d pri=%0d) expected=(pix=%0d col=%0d pri=%0d)",
                          label, x, y, got_pixel[x][y], got_color[x][y], got_priority[x][y], exp_pixel, exp_color, exp_pri);
        end
    endtask

    task automatic check_sprite_case_a;
        for (int r = 0; r < 16; r++)
            for (int c = 0; c < 16; c++)
                check_pixel("A", 100+c, 50+r, 1, (r+c)%16, 5, 1);
        check_pixel("A-border", 99, 50, 0, 0, 0, 0);
        check_pixel("A-border", 116, 50, 0, 0, 0, 0);
        check_pixel("A-border", 100, 66, 0, 0, 0, 0);
    endtask

    initial begin
        #6000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        errors = 0;
        frame_start = 0;
        trans_pen0 = 0;
        trans_pen15 = 0;
        mc_en = 0;
        ac_en = 0;
        for (int i = 0; i < 4096; i++) begin dl_mem[i] = 16'h0000; at_mem[i] = 16'h0000; end

        reset = 1;
        repeat (15) @(posedge clk);
        reset = 0;
        repeat (500) @(posedge clk);

        // seed gfx ROM (tile 7, gradient) and spritelut (sub_code 3 -> tile 7)
        write_gradient_tile(7);
        chip.poke_word_addr((SPRITELUT_BASE + 25'(3*2)) >> 1, 16'd7);

        // ---- Case 1: baseline, sprite rendering alone ----
        clear_fb();
        setup_single_sprite(0, 100, 50, 0, 0, 0, 0, 0, 0, 5, 1, 3);
        run_frame();
        check_sprite_case_a();
        $display("Case 1 done: baseline frame_done latency = %0d cycles, errors so far = %0d", frame_latency, errors);

        // ---- Case 2: contended, maincpu+audiocpu hammering the same
        // arbiter continuously throughout ----
        clear_fb();
        mc_en = 1;
        ac_en = 1;
        setup_single_sprite(0, 100, 50, 0, 0, 0, 0, 0, 0, 5, 1, 3);
        run_frame();
        check_sprite_case_a();
        mc_en = 0;
        ac_en = 0;
        $display("Case 2 done: contended frame_done latency = %0d cycles, errors so far = %0d", frame_latency, errors);

        if (mc_lat_count > 0)
            $display("maincpu bridge under contention: %0d requests served, latency min=%0d max=%0d avg=%0d cycles",
                      mc_lat_count, mc_lat_min, mc_lat_max, mc_lat_sum / mc_lat_count);
        if (ac_lat_count > 0)
            $display("audiocpu bridge under contention: %0d requests served, latency min=%0d max=%0d avg=%0d cycles",
                      ac_lat_count, ac_lat_min, ac_lat_max, ac_lat_sum / ac_lat_count);

        if (errors == 0)
            $display("PASS: sprite_render_engine renders correctly through the real Port 2 SDRAM stack (sdram_arbiter5/sdram_narrow_bridge/sdram), both alone and under sustained maincpu+audiocpu contention");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
