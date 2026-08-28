// Full SCREEN-PATH render of layer 1 for the Gunbird title case: real
// video_timing -> real vreg_decode (real captured vreg content, control
// registers written through its real CPU port) -> real tilemap_line_engine
// (LAYER=1) -> real compositor + real palette dpram -- every module in the
// rendered path is unmodified project RTL, wired port-for-port the way
// rtl/psikyo_core.sv wires it (same instance topology, same signal
// routing, including the layer-1 rowscroll table read through
// vreg_decode). Scroll x/y, rowscroll enable/per-tile, mode, bank, and
// enable all come from the REAL captured vregs -- nothing is forced except
// the isolation switches listed below.
//
// This closes the coverage gap TILEMAP_BUG.md documents: every module
// passed in isolation, so the off-by-one must live in the integration
// seams (line_start/vcnt sequencing, vreg latching, scroll application)
// or in synthesis. If this sim's screen output shows the tile shift /
// wrong palette, the mechanism is HERE and can be waveform-debugged; if
// the output is correct, the RTL-vs-silicon divergence is proven.
//
// Test-only elements (none in the rendered path's logic):
//   - gfxrom served from u33_swapped.hex (map="12" swap pre-applied), 8
//     bytes MSB-first per the gfxrom_data port contract, fixed 3-cycle
//     latency -- the same behavioral-model convention every existing
//     project testbench uses for this port.
//   - Layer 0 and sprites disabled the same way production can disable
//     them (compositor's l0_ctrl_enable low = dbg_render_dis[1];
//     sp_present low): the title kanji under investigation is layer 1.
//   - ce_pix tied 1 (project-wide TB convention; every counter simply
//     advances every clk).
//   - Frame capture: rgb sampled one clk after each active-pixel tick
//     (the palette dpram's registered-read latency, exactly what the real
//     scan-out sees), written as text; Python only arranges the RTL's own
//     values into a PNG.
//
// Run 3 frames; capture the 3rd (pipelines and vreg writes fully settled).

module tb_tilemap_screen;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;
    logic ce_pix;
`ifdef REAL_CE_PIX
    // Production ce_pix, copied verbatim from Psikyo.sv:236-242 -- the
    // exact 1-in-12 divide (clk_sys 85.909 MHz -> 7.159 MHz) that gates
    // display consumption on real hardware. Compile with
    // +define+REAL_CE_PIX to run with real gating; without it the TB
    // keeps the project-wide ce_pix=1 convention (12x faster sim).
    logic [3:0] ce_pix_cnt = 0;
    assign ce_pix = (ce_pix_cnt == 0);
    always_ff @(posedge clk)
        ce_pix_cnt <= (ce_pix_cnt == 11) ? 4'd0 : ce_pix_cnt + 4'd1;
`else
    assign ce_pix = 1'b1;
`endif

    // ---- video timing (real) ----
    logic [8:0] hcnt, vcnt;
    logic [7:0] vcnt_active;
    logic        h_active, v_active, hblank, vblank, hsync, vsync;
    logic        line_start, frame_start;

    video_timing u_timing (
        .clk(clk), .ce_pix(ce_pix), .reset(reset),
        .hcnt(hcnt), .vcnt(vcnt), .vcnt_active(vcnt_active),
        .h_active(h_active), .v_active(v_active),
        .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .frame_start(frame_start)
    );

    // ---- vreg decode (real), CPU port driven by the testbench the same
    // way the game's own CPU writes it ----
    logic [12:0] vregs_cpu_addr;
    logic         vregs_cpu_wel, vregs_cpu_weh;
    logic [15:0] vregs_cpu_wdata, vregs_cpu_rdata;

    logic [7:0]  l0_rowscroll_addr, l1_rowscroll_addr;
    logic [15:0] l0_rowscroll_data, l1_rowscroll_data;
    logic [1:0]  l0_mode, l1_mode;
    logic [15:0] l0_base_x, l0_base_y, l1_base_x, l1_base_y;
    logic [1:0]  l0_bank, l1_bank;
    logic         l0_enable, l1_enable;
    logic         l0_opaque, l1_opaque;
    logic         l0_transpen_sel, l1_transpen_sel;
    logic         l0_rs_en, l1_rs_en;
    logic         l0_rs_pertile, l1_rs_pertile;

    vreg_decode u_vregs (
        .clk(clk), .reset(reset),
        .cpu_addr(vregs_cpu_addr), .cpu_wel(vregs_cpu_wel), .cpu_weh(vregs_cpu_weh),
        .cpu_wdata(vregs_cpu_wdata), .cpu_rdata(vregs_cpu_rdata),
        .layer0_rowscroll_addr(l0_rowscroll_addr), .layer0_rowscroll_data(l0_rowscroll_data),
        .layer1_rowscroll_addr(l1_rowscroll_addr), .layer1_rowscroll_data(l1_rowscroll_data),
        .layer0_mode(l0_mode), .layer0_base_x_scroll(l0_base_x), .layer0_base_y_scroll(l0_base_y),
        .layer0_bank(l0_bank), .layer0_enable(l0_enable), .layer0_opaque(l0_opaque),
        .layer0_transpen_sel(l0_transpen_sel),
        .layer0_rowscroll_enable(l0_rs_en), .layer0_rowscroll_pertile(l0_rs_pertile),
        .layer1_mode(l1_mode), .layer1_base_x_scroll(l1_base_x), .layer1_base_y_scroll(l1_base_y),
        .layer1_bank(l1_bank), .layer1_enable(l1_enable), .layer1_opaque(l1_opaque),
        .layer1_transpen_sel(l1_transpen_sel),
        .layer1_rowscroll_enable(l1_rs_en), .layer1_rowscroll_pertile(l1_rs_pertile),
        .ka302c_banking(1'b1),   // board_gunbird
        .dbg_dump_en(1'b0), .dbg_dump_addr(13'd0), .dbg_dump_data()
    );

    // l0's rowscroll port must still be driven (vreg_decode reads it
    // combinationally into a dpram address) -- production drives it from
    // u_layer0, which this test omits; tie to 0.
    assign l0_rowscroll_addr = 8'd0;

    // ---- layer-1 tilemap engine (real), wired exactly as psikyo_core ----
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

    tilemap_line_engine #(.LAYER(1)) u_layer1 (
        .clk(clk), .reset(reset),
        .vcnt(vcnt_active), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
        .mode(l1_mode), .base_x_scroll(l1_base_x), .base_y_scroll(l1_base_y), .bank(l1_bank),
        .rowscroll_enable(l1_rs_en), .rowscroll_pertile(l1_rs_pertile),
        .rowscroll_addr(l1_rowscroll_addr), .rowscroll_data(l1_rowscroll_data),
        .vram_addr(l1_vram_addr), .vram_data(l1_vram_data),
        .gfxrom_req(l1_gfxrom_req), .gfxrom_addr(l1_gfxrom_addr),
        .gfxrom_valid(l1_gfxrom_valid), .gfxrom_data(l1_gfxrom_data),
        .pixel_valid(l1_pixel_valid), .pixel_index(l1_pixel_index), .pixel_color(l1_pixel_color),
        .fetch_overrun(l1_fetch_overrun)
`ifdef DEBUG_ISSP
        ,
        .dbg_fetch_vram_addr(), .dbg_vram_data(),
        .dbg_cell_tile_number(), .dbg_cell_color(),
        .dbg_mode_latched(), .dbg_bank_latched(),
        .dbg_pixel_src_addr(), .dbg_pixel_src_word()
`endif
    );

    // ---- VRAM1 (real dpram, real captured content), b-port to the layer
    // engine exactly as psikyo_core's u_vram1 (vram_dump inactive) ----
    logic [15:0] vram1_a_rdata_unused;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
        .clk(clk),
        .a_addr(12'd0), .a_wel(1'b0), .a_weh(1'b0),
        .a_wdata(16'd0), .a_rdata(vram1_a_rdata_unused),
        .b_addr(l1_vram_addr), .b_rdata(l1_vram_data)
    );

    // ---- palette RAM (real dpram, real captured content), b-port to the
    // compositor exactly as psikyo_core's u_palette (pal_dump inactive) ----
    logic [11:0] pal_addr;
    logic [15:0] pal_b_rdata;
    logic [15:0] pal_a_rdata_unused;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
        .clk(clk),
        .a_addr(12'd0), .a_wel(1'b0), .a_weh(1'b0),
        .a_wdata(16'd0), .a_rdata(pal_a_rdata_unused),
        .b_addr(pal_addr), .b_rdata(pal_b_rdata)
    );

    // ---- compositor (real), layer 0 + sprites disabled via the same
    // signals production's dbg_render_dis switches drive ----
    logic [14:0] rgb;
    compositor u_compositor (
        .l0_valid(1'b0), .l0_pixel(4'd0), .l0_color(7'd0),
        .l0_ctrl_enable(1'b0), .l0_ctrl_opaque(l0_opaque), .l0_ctrl_transpen_sel(l0_transpen_sel),
        .l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
        .l1_ctrl_enable(l1_enable), .l1_ctrl_opaque(l1_opaque), .l1_ctrl_transpen_sel(l1_transpen_sel),
        .sp_present(1'b0), .sp_pixel(4'd0), .sp_color(5'd0), .sp_priority(2'd0),
        .pal_addr(pal_addr), .pal_data(pal_b_rdata),
        .rgb(rgb)
    );

    // ---- gfx ROM model: u33.bin (tiles region), MSB-first per the port
    // contract, fixed 3-cycle latency (same convention as every existing
    // project TB for this port) ----
    logic [7:0] gfxrom [0:2097151];
    initial $readmemh("u33_swapped.hex", gfxrom);

    int gfxrom_delay;
    logic [21:0] gfxrom_addr_held;
    always_ff @(posedge clk) begin
        if (reset) begin
            l1_gfxrom_valid <= 1'b0;
            gfxrom_delay     <= 0;
        end else begin
            l1_gfxrom_valid <= 1'b0;
            if (l1_gfxrom_req && gfxrom_delay == 0) begin
                gfxrom_addr_held <= l1_gfxrom_addr;
                gfxrom_delay      <= 3;
            end else if (gfxrom_delay > 0) begin
                if (gfxrom_delay == 1) begin
                    l1_gfxrom_data <= {gfxrom[gfxrom_addr_held+0], gfxrom[gfxrom_addr_held+1],
                                        gfxrom[gfxrom_addr_held+2], gfxrom[gfxrom_addr_held+3],
                                        gfxrom[gfxrom_addr_held+4], gfxrom[gfxrom_addr_held+5],
                                        gfxrom[gfxrom_addr_held+6], gfxrom[gfxrom_addr_held+7]};
                    l1_gfxrom_valid <= 1'b1;
                end
                gfxrom_delay <= gfxrom_delay - 1;
            end
        end
    end

    // ---- content preload: real captured memories ----
    initial begin
        $readmemh("real_vram1_dump.hex",   u_vram1.mem);
        $readmemh("real_palette_dump.hex", u_palette.mem);
        // vreg region RAM (both copies -- production writes them
        // identically from the one CPU port)
        $readmemh("real_vregs_dump.hex", u_vregs.u_ram_l0.mem);
        $readmemh("real_vregs_dump.hex", u_vregs.u_ram_l1.mem);
    end

    // ---- CPU-port write task: the same mechanism the game uses to set
    // the six latched control registers ----
    task automatic vreg_write(logic [12:0] addr, logic [15:0] data);
        @(posedge clk);
        vregs_cpu_addr  <= addr;
        vregs_cpu_wdata <= data;
        vregs_cpu_wel   <= 1'b1;
        vregs_cpu_weh   <= 1'b1;
        @(posedge clk);
        vregs_cpu_wel   <= 1'b0;
        vregs_cpu_weh   <= 1'b0;
    endtask

    // ---- frame capture: sample rgb one clk after each active tick (the
    // palette dpram's registered-read latency), with the coordinates
    // delayed to match ----
    logic [8:0] hcnt_d, vcnt_d;
    logic        active_d;
    int          frame_num;
    integer      fcap;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_d  <= 1'b0;
            frame_num <= 0;
        end else begin
            hcnt_d    <= hcnt;
            vcnt_d    <= vcnt;
            active_d  <= ce_pix && h_active && v_active;
            if (frame_start) frame_num <= frame_num + 1;
            if (active_d && frame_num == 3 && fcap != 0)
                $fwrite(fcap, "%0d %0d %04h\n", vcnt_d, hcnt_d, rgb);
        end
    end

    initial begin
        fcap = 0;
        reset = 1;
        vregs_cpu_addr = '0; vregs_cpu_wdata = '0;
        vregs_cpu_wel = 0; vregs_cpu_weh = 0;
        repeat (8) @(posedge clk);
        reset = 0;
        repeat (4) @(posedge clk);

        // the six latched control registers, real captured values, written
        // through the real CPU port (vreg_decode.sv's ADDR_* map)
        vreg_write(13'h201, 16'h0000);   // L0 Y-scroll
        vreg_write(13'h203, 16'h0000);   // L0 X-scroll
        vreg_write(13'h205, 16'h0000);   // L1 Y-scroll
        vreg_write(13'h207, 16'h0140);   // L1 X-scroll
        vreg_write(13'h209, 16'h00D0);   // L0 control
        vreg_write(13'h20B, 16'h04D0);   // L1 control (mode 3, bank 1)

        fcap = $fopen("screen_dump.txt", "w");
        if (fcap == 0) begin $display("FAIL: cannot open screen_dump.txt"); $finish; end

        // run until frame 3 has fully rendered (frame_num increments at
        // each vblank rising edge; frame 3's active area is captured above)
        wait (frame_num == 4);
        $fclose(fcap);
        fcap = 0;
        $display("PASS: captured frame 3 (%0d x %0d active pixels) to screen_dump.txt", 320, 224);
        if (l1_fetch_overrun)
            $display("WARNING: l1_fetch_overrun was asserted at least once -- some pixels may be backdrop fallback");
        $finish;
    end

endmodule
