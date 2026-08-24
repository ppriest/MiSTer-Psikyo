// Top-level Phase 1 video+CPU core: wires rtl/cpu/maincpu.sv (the 68EC020
// bus) into the memory glue (rtl/memory/dpram.sv, rtl/video/vreg_decode.sv,
// rtl/video/spriteram_dbuf.sv) and the already-verified video pipeline
// (rtl/video/video_timing.sv, tilemap_line_engine.sv x2,
// sprite_render_engine.sv + sprite_frame_buffer.sv, compositor.sv) into one
// module -- see docs/ROADMAP.md's "Top-level integration" progress entry.
//
// Deliberately out of scope here (kept as external ports instead): gfx/CPU
// ROM content, which belongs to the SDRAM stack
// (rtl/memory/sdram_arbiter5.sv etc, docs/phase1_sdram_map.md) -- that's
// its own already-substantial, separately-verified piece, wired to this
// module's rom_req/addr/valid/data-shaped ports rather than duplicated
// here. Also out of scope: the sound CPU / YM2610 (only the raw
// latch_data/latch_write handshake is exposed) and the HPS/DIP/CRT_Offset
// glue that belongs in Psikyo.sv itself, one level up.
//
// ---- Sprite pipeline per-frame sequencing (the one genuinely new piece
// of control logic this module adds, not just wiring) ----
// video_timing's frame_start pulse drives THREE things, deliberately in
// two stages one cycle apart:
//   1. Same cycle: spriteram_dbuf.frame_start -- swaps which physical bank
//      the CPU writes into vs. which one is frozen for the render engine
//      to read, and latches this frame's sprites_disable/trans_pen* control
//      bits (docs/phase1_memory_map.md's spriteram control word).
//   2. One cycle later (frame_start_d): sprite_render_engine.frame_start,
//      gated by the NOW-updated sprites_disable -- spriteram_dbuf's own
//      control latch is itself registered on the frame_start edge, so
//      sprites_disable isn't valid until the cycle after the swap; waiting
//      one cycle is what makes the gating correct rather than reading last
//      frame's stale disable bit. If sprites are disabled, the render
//      engine is simply never kicked -- sprite_frame_buffer's write-role
//      bank keeps whatever an earlier frame_swap already cleared it to
//      (rd_present all-0), which is exactly "no sprites drawn" (matches
//      MAME's own early-return-from-draw when the control word's disable
//      bit is set -- docs/phase1_video_engine.md's "sprites-disable...
//      caller's responsibility" note).
// sprite_frame_buffer.frame_swap is driven from frame_start (suppressed
// while rendering is still busy), NOT from sprite_render_engine.frame_done.
// Swapping on frame_done toggles the display bank at whatever point in the
// frame rendering happens to end, which is usually mid-scanout -- the
// compositor then reads the top of the picture from one bank and the bottom
// from the other. Swapping at the frame boundary keeps a finished bank
// visible for a whole frame. See the sequencing block further down.
module psikyo_core #(
    parameter bit BOARD_GUNBIRD = 1'b0,
    parameter bit DEBUG_TRACER  = 1'b1
) (
    input  logic clk,
    input  logic ce_pix,
    input  logic reset,

    // CPU program ROM -- external (SDRAM stack).
    output logic         cpu_rom_req,
    output logic [18:0] cpu_rom_addr,
    input  logic         cpu_rom_valid,
    input  logic [15:0] cpu_rom_data,

    // Tilemap layer 0/1 gfx ROM -- external.
    output logic         l0_gfxrom_req,
    output logic [21:0] l0_gfxrom_addr,
    input  logic         l0_gfxrom_valid,
    input  logic [63:0] l0_gfxrom_data,
    output logic         l1_gfxrom_req,
    output logic [21:0] l1_gfxrom_addr,
    input  logic         l1_gfxrom_valid,
    input  logic [63:0] l1_gfxrom_data,

    // Sprite gfx ROM + spritelut -- external.
    output logic         sp_gfxrom_req,
    output logic [22:0] sp_gfxrom_addr,
    input  logic         sp_gfxrom_valid,
    input  logic [63:0] sp_gfxrom_data,
    output logic         sp_lut_req,
    output logic [16:0] sp_lut_addr,
    input  logic         sp_lut_valid,
    input  logic [15:0] sp_lut_data,

    // Inputs (raw values -- caller owns debouncing/mapping).
    input  logic [31:0] p1p2_in,
    input  logic [31:0] dsw_in,
    input  logic [31:0] coin_in,

    // Board variant, runtime (from the .mra mod byte) -- see maincpu.sv.
    input  logic         board_gunbird,

    // Sound latch handshake -- to a sound CPU wrapper, not instantiated here.
    output logic [7:0]  latch_data,
    output logic         latch_write,

    // Video output.
    output logic [8:0]  hcnt,
    output logic [8:0]  vcnt,
    output logic         hblank,
    output logic         vblank,
    output logic         hsync,
    output logic         vsync,
    output logic [14:0] rgb,

    // ---- debug tracer (rtl/debug/debug_tracer.sv) ----
    // Live-controlled from the OSD; see that module's header. Compiled out
    // entirely when DEBUG_TRACER = 0.
    input  logic         dbg_overlay,  // overlay is being displayed (frees VRAM read ports)
    // Force-disable rendering per layer, from the OSD. Purely a debugging aid:
    // it isolates which pipeline actually drew a given thing on screen, which
    // is otherwise guesswork once sprites and tilemaps overlap.
    //   [0] sprites  [1] tilemap layer 0  [2] tilemap layer 1
    input  logic [2:0]  dbg_render_dis,
    input  logic         dbg_sprite_vsync_swap,
    input  logic [1:0]  dbg_src,      // which signal group to record
    input  logic [3:0]  dbg_window,   // skip dbg_window*256 events first
    input  logic         dbg_rearm,    // any change restarts capture
    output logic [23:0] dbg_pixel     // one captured entry per scanline
);

    // ---- video timing ----
    logic [7:0] vcnt_active;
    logic         h_active, v_active;
    logic         line_start, frame_start;

    video_timing u_timing (
        .clk(clk), .ce_pix(ce_pix), .reset(reset),
        .hcnt(hcnt), .vcnt(vcnt), .vcnt_active(vcnt_active),
        .h_active(h_active), .v_active(v_active),
        .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .frame_start(frame_start)
    );

    // ---- CPU-facing BRAM region ports (maincpu.sv's own port shapes) ----
    logic [11:0] spr_cpu_addr;
    logic         spr_cpu_wel, spr_cpu_weh;
    logic [15:0] spr_cpu_wdata, spr_cpu_rdata;

    logic [11:0] pal_cpu_addr;
    logic         pal_cpu_wel, pal_cpu_weh;
    logic [15:0] pal_cpu_wdata, pal_cpu_rdata;

    logic [11:0] vram0_cpu_addr;
    logic         vram0_cpu_wel, vram0_cpu_weh;
    logic [15:0] vram0_cpu_wdata, vram0_cpu_rdata;

    logic [11:0] vram1_cpu_addr;
    logic         vram1_cpu_wel, vram1_cpu_weh;
    logic [15:0] vram1_cpu_wdata, vram1_cpu_rdata;

    logic [12:0] vregs_cpu_addr;
    logic         vregs_cpu_wel, vregs_cpu_weh;
    logic [15:0] vregs_cpu_wdata, vregs_cpu_rdata;

    logic [15:0] workram_cpu_addr;
    logic         workram_cpu_wel, workram_cpu_weh;
    logic [15:0] workram_cpu_wdata, workram_cpu_rdata;

    maincpu u_cpu (
        .clk(clk), .reset(reset),
        .rom_req(cpu_rom_req), .rom_addr(cpu_rom_addr), .rom_valid(cpu_rom_valid), .rom_data(cpu_rom_data),
        .spriteram_addr(spr_cpu_addr), .spriteram_wel(spr_cpu_wel), .spriteram_weh(spr_cpu_weh),
        .spriteram_wdata(spr_cpu_wdata), .spriteram_rdata(spr_cpu_rdata),
        .palette_addr(pal_cpu_addr), .palette_wel(pal_cpu_wel), .palette_weh(pal_cpu_weh),
        .palette_wdata(pal_cpu_wdata), .palette_rdata(pal_cpu_rdata),
        .vram0_addr(vram0_cpu_addr), .vram0_wel(vram0_cpu_wel), .vram0_weh(vram0_cpu_weh),
        .vram0_wdata(vram0_cpu_wdata), .vram0_rdata(vram0_cpu_rdata),
        .vram1_addr(vram1_cpu_addr), .vram1_wel(vram1_cpu_wel), .vram1_weh(vram1_cpu_weh),
        .vram1_wdata(vram1_cpu_wdata), .vram1_rdata(vram1_cpu_rdata),
        .vregs_addr(vregs_cpu_addr), .vregs_wel(vregs_cpu_wel), .vregs_weh(vregs_cpu_weh),
        .vregs_wdata(vregs_cpu_wdata), .vregs_rdata(vregs_cpu_rdata),
        .workram_addr(workram_cpu_addr), .workram_wel(workram_cpu_wel), .workram_weh(workram_cpu_weh),
        .workram_wdata(workram_cpu_wdata), .workram_rdata(workram_cpu_rdata),
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in), .board_gunbird(board_gunbird),
        .latch_data(latch_data), .latch_write(latch_write),
        .vblank(vblank)
    );

    // ---- work RAM: CPU-only, port B unused ----
    logic [15:0] workram_unused_b;
    dpram #(.ADDR_WIDTH(16), .DATA_WIDTH(16)) u_workram (
        .clk(clk),
        .a_addr(workram_cpu_addr), .a_wel(workram_cpu_wel), .a_weh(workram_cpu_weh),
        .a_wdata(workram_cpu_wdata), .a_rdata(workram_cpu_rdata),
        .b_addr(16'd0), .b_rdata(workram_unused_b)
    );

    // ---- palette RAM: CPU write, compositor read ----
    logic [11:0] pal_addr;
    logic [15:0] pal_data;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
        .clk(clk),
        .a_addr(pal_cpu_addr), .a_wel(pal_cpu_wel), .a_weh(pal_cpu_weh),
        .a_wdata(pal_cpu_wdata), .a_rdata(pal_cpu_rdata),
        .b_addr(pal_addr), .b_rdata(pal_data)
    );

    // ---- tilemap VRAM: CPU write, per-layer tilemap engine read ----
    logic [11:0] l0_vram_addr;
    logic [15:0] l0_vram_data;
    logic [11:0] l1_vram_addr;
    logic [15:0] l1_vram_data;

    // ---- VRAM debug dump: borrow the tilemap engines' read ports ----
    // The overlay replaces the picture, so tilemap rendering is discarded that
    // frame and the layer engines' VRAM read ports are free. Indexing by
    // {vcnt[3:0],hcnt[7:0]} puts all 4096 words of both layers into 32
    // scanlines, so one screenshot carries the complete tilemap RAM for
    // comparison against a MAME dump. Touches no tilemap RTL.
    logic [11:0] vram0_b_addr, vram1_b_addr;
    logic [15:0] vram0_b_rdata, vram1_b_rdata;

    wire        vram_dump_active = DEBUG_TRACER && dbg_overlay && (vcnt < 9'd32);
    // vregs dump occupies rows 32..47: words 0x000-0xFFF of the video-register
    // region, which covers BOTH rowscroll tables (0x000-0x1FF) and the six
    // control/scroll registers (0x201..0x20B).
    logic [15:0] vregs_dump_data;
    wire         vregs_dump_active = DEBUG_TRACER && dbg_overlay
                                   && (vcnt >= 9'd32) && (vcnt < 9'd48);
    wire [12:0] vregs_dump_addr   = {1'b0, vcnt[3:0], hcnt[7:0]};
    wire [11:0] vram_dump_addr   = {vcnt[3:0], hcnt[7:0]};

    assign vram0_b_addr = vram_dump_active ? vram_dump_addr : l0_vram_addr;
    assign vram1_b_addr = vram_dump_active ? vram_dump_addr : l1_vram_addr;
    assign l0_vram_data = vram0_b_rdata;
    assign l1_vram_data = vram1_b_rdata;

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram0 (
        .clk(clk),
        .a_addr(vram0_cpu_addr), .a_wel(vram0_cpu_wel), .a_weh(vram0_cpu_weh),
        .a_wdata(vram0_cpu_wdata), .a_rdata(vram0_cpu_rdata),
        .b_addr(vram0_b_addr), .b_rdata(vram0_b_rdata)
    );

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
        .clk(clk),
        .a_addr(vram1_cpu_addr), .a_wel(vram1_cpu_wel), .a_weh(vram1_cpu_weh),
        .a_wdata(vram1_cpu_wdata), .a_rdata(vram1_cpu_rdata),
        .b_addr(vram1_b_addr), .b_rdata(vram1_b_rdata)
    );

    // ---- vregs: CPU write, decoded per-layer control + row-scroll reads ----
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

    // BOARD_GUNBIRD selects gunbird/btlkroad, which are exactly the Phase 1
    // boards with MAME's m_ka302c_banking (s1945n is the third, Phase 2).
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
        .ka302c_banking(board_gunbird), .dbg_dump_en(vregs_dump_active), .dbg_dump_addr(vregs_dump_addr),
        .dbg_dump_data(vregs_dump_data)
    );

    // ---- tilemap engines ----
    logic         l0_pixel_valid, l1_pixel_valid;
    logic [3:0]  l0_pixel_index, l1_pixel_index;
    logic [6:0]  l0_pixel_color, l1_pixel_color;
    logic         l0_fetch_overrun, l1_fetch_overrun; // echoed in the debug overlay control band

    tilemap_line_engine #(.LAYER(0)) u_layer0 (
        .clk(clk), .reset(reset),
        .vcnt(vcnt_active), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
        .mode(l0_mode), .base_x_scroll(l0_base_x), .base_y_scroll(l0_base_y), .bank(l0_bank),
        .rowscroll_enable(l0_rs_en), .rowscroll_pertile(l0_rs_pertile),
        .rowscroll_addr(l0_rowscroll_addr), .rowscroll_data(l0_rowscroll_data),
        .vram_addr(l0_vram_addr), .vram_data(l0_vram_data),
        .gfxrom_req(l0_gfxrom_req), .gfxrom_addr(l0_gfxrom_addr),
        .gfxrom_valid(l0_gfxrom_valid), .gfxrom_data(l0_gfxrom_data),
        .pixel_valid(l0_pixel_valid), .pixel_index(l0_pixel_index), .pixel_color(l0_pixel_color),
        .fetch_overrun(l0_fetch_overrun)
    );

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
    );

    // ---- sprite RAM (double-buffered) + sprite pipeline ----
    logic [11:0] dl_addr, at_addr;
    logic [15:0] dl_data, at_data;
    logic         sprites_disable, trans_pen0, trans_pen15;

    spriteram_dbuf u_spriteram (
        .clk(clk), .reset(reset), .frame_start(frame_start),
        .cpu_addr(spr_cpu_addr), .cpu_wel(spr_cpu_wel), .cpu_weh(spr_cpu_weh),
        .cpu_wdata(spr_cpu_wdata), .cpu_rdata(spr_cpu_rdata),
        .dl_addr(dl_addr), .dl_data(dl_data), .at_addr(at_addr), .at_data(at_data),
        .sprites_disable(sprites_disable), .trans_pen0(trans_pen0), .trans_pen15(trans_pen15)
    );

    // frame_start also swaps spriteram_dbuf's roles combinationally with
    // the sprites_disable output latched on that SAME edge -- one cycle
    // late relative to the pulse itself (see module header).
    logic frame_start_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) frame_start_d <= 1'b0;
        else        frame_start_d <= frame_start;
    end

    // NOTE: the frame-buffer swap sequencing experiment has been REVERTED.
    //
    // It moved frame_swap from sp_frame_done to the frame boundary and gated
    // the render start on swap_done, to stop the display bank toggling
    // mid-scanout. sprite_frame_buffer's header does ask for exactly that. But
    // on hardware it stopped the game booting: the CPU ended up parked on the
    // `bra.s *` at 0xB5E (the boot's deliberate die-here stub), with the video
    // registers never programmed. Runtime A/B via the OSD render-disable bits
    // ruled out the tilemap enable and the debug port borrowing as causes, and
    // the pipelining fix (which took slack from -1.889 ns to -0.338 ns) did not
    // help either -- so it is this sequencing change, most likely because
    // holding the render start across frames leaves the engine rendering
    // back-to-back and saturating the SDRAM arbiter that the CPU fetches
    // through.
    //
    // Reverting to the known-good behaviour rather than leaving a
    // non-booting core in the tree. The mid-scanout tear is real and still
    // wants fixing, but it has to be done without starving the CPU -- likely
    // by gating the engine's SDRAM requests rather than its start signal.
    logic sprite_frame_start;
    logic sp_swap_busy, sp_swap_done;
    logic sp_frame_busy, sp_frame_done;

    // ---- sprite output-buffer swap policy, runtime selectable ----
    // 0 (default): frame_swap on sp_frame_done, so the display bank toggles
    //   wherever rendering finishes -- measured at ~61.5% down the VISIBLE
    //   frame, which tears the picture there every frame.
    // 1: swap at the frame boundary and hold the render start until the
    //   buffer's clear completes, as sprite_frame_buffer's header asks.
    // Budget supports either: render 881632 cycles, clear 71680, frame
    // 1433729. A switch rather than an outright change because this was tried
    // once and stopped the core booting for reasons never established; it
    // makes the comparison an A/B on one bitstream. See docs/sprite_buffering.md.
    wire want_frame = frame_start_d & ~sprites_disable & ~dbg_render_dis[0];

    logic bank_ready, start_pending;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bank_ready    <= 1'b1;   // both banks power up cleared
            start_pending <= 1'b0;
        end else begin
            if (sp_swap_done)       bank_ready    <= 1'b1;
            if (want_frame)         start_pending <= 1'b1;
            if (sprite_frame_start) begin
                start_pending <= 1'b0;
                bank_ready    <= 1'b0;
            end
        end
    end

    assign sprite_frame_start = dbg_sprite_vsync_swap
        ? (start_pending & bank_ready & ~sp_frame_busy & ~sp_swap_busy)
        : want_frame;

    wire sprite_swap_now = dbg_sprite_vsync_swap ? (frame_start & ~sp_frame_busy)
                                                  : sp_frame_done;

    // ---- sprite render budget instrumentation ----
    // Does a render pass finish inside one frame? Both sprite artefacts follow
    // if it does not: spriteram_dbuf swaps the engine's SOURCE records at
    // frame_start, and the frame buffer's clear then overlaps the next pass
    // (it ignores writes while swap_busy). sp_overran is sticky since
    // configuration, so it also catches boot transients.
    logic sp_overran = 1'b0;
    logic [19:0] sp_render_cycles = '0;
    logic [19:0] sp_render_max    = '0;
    always_ff @(posedge clk) begin
        if (frame_start && sp_frame_busy) sp_overran <= 1'b1;
        if (sprite_frame_start)      sp_render_cycles <= '0;
        else if (sp_frame_busy)      sp_render_cycles <= sp_render_cycles + 1'b1;
        if (sp_frame_done && (sp_render_cycles > sp_render_max))
            sp_render_max <= sp_render_cycles;
    end



    logic         fb_we;
    logic [8:0]  fb_x;
    logic [7:0]  fb_y;
    logic [3:0]  fb_pixel;
    logic [4:0]  fb_color;
    logic [1:0]  fb_priority;

    sprite_render_engine u_sprite_render (
        .clk(clk), .reset(reset),
        .frame_start(sprite_frame_start), .frame_busy(sp_frame_busy), .frame_done(sp_frame_done),
        .trans_pen0(trans_pen0), .trans_pen15(trans_pen15),
        .dl_addr(dl_addr), .dl_data(dl_data),
        .at_addr(at_addr), .at_data(at_data),
        .lut_req(sp_lut_req), .lut_addr(sp_lut_addr), .lut_valid(sp_lut_valid), .lut_data(sp_lut_data),
        .gfxrom_req(sp_gfxrom_req), .gfxrom_addr(sp_gfxrom_addr),
        .gfxrom_valid(sp_gfxrom_valid), .gfxrom_data(sp_gfxrom_data),
        .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y),
        .fb_pixel(fb_pixel), .fb_color(fb_color), .fb_priority(fb_priority)
    );

    logic         sp_present;
    logic [3:0]  sp_pixel;
    logic [4:0]  sp_color;
    logic [1:0]  sp_priority;

    sprite_frame_buffer u_sprite_fb (
        .clk(clk), .reset(reset),
        .frame_swap(sprite_swap_now), .swap_busy(sp_swap_busy), .swap_done(sp_swap_done),
        .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y),
        .fb_pixel(fb_pixel), .fb_color(fb_color), .fb_priority(fb_priority),
        .rd_x(hcnt), .rd_y(vcnt_active),
        .rd_present(sp_present), .rd_pixel(sp_pixel), .rd_color(sp_color), .rd_priority(sp_priority)
    );

    // ---- compositor ----
    compositor u_compositor (
        .l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
        .l0_ctrl_enable(l0_enable & ~dbg_render_dis[1]), .l0_ctrl_opaque(l0_opaque), .l0_ctrl_transpen_sel(l0_transpen_sel),
        .l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
        .l1_ctrl_enable(l1_enable & ~dbg_render_dis[2]), .l1_ctrl_opaque(l1_opaque), .l1_ctrl_transpen_sel(l1_transpen_sel),
        .sp_present(sp_present), .sp_pixel(sp_pixel), .sp_color(sp_color), .sp_priority(sp_priority),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .rgb(rgb)
    );


    // ---- debug tracer (two buffers, no source selection) ------------------
    // Deliberately NOT selectable at runtime. The OSD source-select bit was
    // tried at status[50:49] and again at status[58:57] and never took effect
    // (the overlay bit in the same byte works, so the CFG path itself is
    // fine). Rather than debug that a third time, both signals of interest
    // are captured simultaneously into separate buffers and read out by
    // scanline:
    //   scanlines   0-127 : CPU ROM read, FULL 19-bit word address
    //   scanlines 128-255 : CPU ROM read, {addr[7:0], data} -- SAME event N
    // Both buffers are strobed by cpu_rom_valid, so entry N of one describes
    // exactly the same bus cycle as entry N of the other: scanline L and
    // scanline L+128 are one read, seen twice.
    //
    // Why the full address is worth a whole buffer: capturing only addr[7:0]
    // cannot distinguish a CPU that is genuinely sweeping ROM (a checksum,
    // address climbing, low bits wrapping every 256 words) from a ROM read
    // path that ALIASES (upper address bits dropped, so word 2048 returns
    // word 0). Those two have completely different causes and the truncated
    // capture looks identical for both. The sprite-write tracer is dropped
    // for this build: sprite writes were already confirmed present, and this
    // question gates everything downstream of it.
    generate if (DEBUG_TRACER) begin : g_tracer
        logic [23:0] rd_addr, rd_data;
        logic        frz_a, frz_d;

        // TRIGGER: word address 8 is bytes 0x10-0x13 = exception vector 4,
        // Illegal Instruction. On hardware the CPU fetches this vector over and
        // over in an 8-read loop, so freezing on the FIRST fetch leaves the
        // buffer holding the 127 ROM reads that preceded it -- the code that
        // caused the exception. MAME's boot never executes any of the loop's
        // addresses, so this is a fault path, not game logic.
        wire trig_vec4 = (cpu_rom_addr == 19'd8);

        // dbg_src[0] = ring (latest N) vs first-N + window walk
        // dbg_src[1] = freeze on trigger
        debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_addr (
            .clk(clk),
            .cap_stb(cpu_rom_valid),
            .cap_data({5'd0, cpu_rom_addr}),
            .ctl_rearm(dbg_rearm),
            .ctl_window(dbg_window),
            .ctl_ring(dbg_src[0]),
            .ctl_trig_en(dbg_src[1]),
            .cap_trig(trig_vec4),
            .rd_index(vcnt - 9'd48),
            .rd_data(rd_addr),
            .frozen(frz_a)
        );

        debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_data (
            .clk(clk),
            .cap_stb(cpu_rom_valid),
            .cap_data({cpu_rom_addr[7:0], cpu_rom_data}),
            .ctl_rearm(dbg_rearm),
            .ctl_window(dbg_window),
            .ctl_ring(dbg_src[0]),
            .ctl_trig_en(dbg_src[1]),
            .cap_trig(trig_vec4),
            .rd_index(vcnt - 9'd176),
            .rd_data(rd_data),
            .frozen(frz_d)
        );

        // Scanlines 216-223 echo the CONTROL INPUTS back out, plus a fixed 0xA5
        // marker byte so a mis-decoded band is obvious rather than silently
        // believable.
        //
        // This exists because three separate captures at ctl_window = 0, 1 and 8
        // returned byte-identical images, which is impossible if the window is
        // reaching the tracer (the skip step is 8191, prime -- no event period
        // can alias with all three). Rather than keep debugging the consequence
        // while assuming the control input is correct, the core now reports what
        // it actually receives. If this band reads back window=0 while the CFG
        // holds window=8, the fault is in the OSD/status path, not the tracer.
        // (The low bit is a constant 1, giving a second fixed bit alongside
        // the 0xA5 marker to catch a mis-decoded band.)
        // Middle byte carries the video-engine health flags. l0/l1_fetch_overrun
        // are STICKY: set once a tilemap line engine wanted to display a pixel
        // whose tile had not been fetched yet, which makes it drop pixel_valid
        // -- and the compositor then silently paints backdrop. Without this
        // readout, a tilemap that cannot keep up is visually identical to the
        // game legitimately drawing nothing there, so a large flat backdrop
        // area is unattributable. The layer enables sit next to them because
        // "no pixels" also happens when a layer is simply switched off, and
        // those two causes need telling apart.
        wire [23:0] ctl_echo = {8'hA5,
                                sp_overran, 1'd0, l0_fetch_overrun, l1_fetch_overrun,
                                l0_enable, l1_enable, frz_a, frz_d,
                                dbg_rearm, dbg_window, dbg_src, 1'b1};

        // Overlay band layout (one screenshot carries all of it):
        //   rows   0- 15 : layer 0 VRAM, all 4096 words  ({vcnt[3:0],hcnt[7:0]})
        //   rows  16- 31 : layer 1 VRAM, all 4096 words
        //   rows  32- 47 : video registers, words 0x000-0xFFF
        //   rows  48-175 : CPU ROM read, full 19-bit address (128 entries)
        //   rows 176-215 : CPU ROM read, {addr[7:0],data}    (40 entries)
        //   rows 216-223 : control echo + video-engine health flags
        // row 215 carries the worst-case sprite render length, in clk cycles
        assign dbg_pixel = (vcnt == 9'd215) ? {4'd0, sp_render_max}
                         : (vcnt >= 9'd216) ? ctl_echo
                         : (vcnt <  9'd16)  ? {8'h00, vram0_b_rdata}
                         : (vcnt <  9'd32)  ? {8'h00, vram1_b_rdata}
                         : (vcnt <  9'd48)  ? {8'h00, vregs_dump_data}
                         : (vcnt <  9'd176) ? rd_addr
                                            : rd_data;
    end else begin : g_no_tracer
        assign dbg_pixel = 24'd0;
    end endgenerate

endmodule
