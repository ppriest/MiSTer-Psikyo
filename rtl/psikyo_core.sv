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
// sprite_render_engine.frame_done then drives sprite_frame_buffer.frame_swap
// directly -- the OUTPUT double buffer swaps once rendering finishes, not
// at frame_start (the write-role bank doesn't hold this frame's sprites
// until rendering actually completes). Whether clear+render always finishes
// before the next frame_start is a real timing-budget question (the clear
// alone is 71680 cycles, sprite_frame_buffer.sv's own header) -- not proven
// here, same "prove wiring first, measure the budget separately" approach
// already used for the SDRAM contention numbers in docs/ROADMAP.md.
module psikyo_core #(
    parameter bit BOARD_GUNBIRD = 1'b0
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
    output logic [14:0] rgb
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

    maincpu #(.BOARD_GUNBIRD(BOARD_GUNBIRD)) u_cpu (
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
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in),
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
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram0 (
        .clk(clk),
        .a_addr(vram0_cpu_addr), .a_wel(vram0_cpu_wel), .a_weh(vram0_cpu_weh),
        .a_wdata(vram0_cpu_wdata), .a_rdata(vram0_cpu_rdata),
        .b_addr(l0_vram_addr), .b_rdata(l0_vram_data)
    );

    logic [11:0] l1_vram_addr;
    logic [15:0] l1_vram_data;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
        .clk(clk),
        .a_addr(vram1_cpu_addr), .a_wel(vram1_cpu_wel), .a_weh(vram1_cpu_weh),
        .a_wdata(vram1_cpu_wdata), .a_rdata(vram1_cpu_rdata),
        .b_addr(l1_vram_addr), .b_rdata(l1_vram_data)
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
    vreg_decode #(.KA302C_BANKING(BOARD_GUNBIRD)) u_vregs (
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
        .layer1_rowscroll_enable(l1_rs_en), .layer1_rowscroll_pertile(l1_rs_pertile)
    );

    // ---- tilemap engines ----
    logic         l0_pixel_valid, l1_pixel_valid;
    logic [3:0]  l0_pixel_index, l1_pixel_index;
    logic [6:0]  l0_pixel_color, l1_pixel_color;
    logic         l0_fetch_overrun, l1_fetch_overrun; // diagnostic only, not consumed here

    tilemap_line_engine #(.LAYER(0)) u_layer0 (
        .clk(clk), .reset(reset),
        .vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
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
        .vcnt(vcnt_active), .h_active(h_active), .line_start(line_start),
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

    logic sprite_frame_start;
    assign sprite_frame_start = frame_start_d & ~sprites_disable;

    logic         sp_frame_busy, sp_frame_done;
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

    logic         sp_swap_busy, sp_swap_done; // diagnostic only, not consumed here
    logic         sp_present;
    logic [3:0]  sp_pixel;
    logic [4:0]  sp_color;
    logic [1:0]  sp_priority;

    sprite_frame_buffer u_sprite_fb (
        .clk(clk), .reset(reset),
        .frame_swap(sp_frame_done), .swap_busy(sp_swap_busy), .swap_done(sp_swap_done),
        .fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y),
        .fb_pixel(fb_pixel), .fb_color(fb_color), .fb_priority(fb_priority),
        .rd_x(hcnt), .rd_y(vcnt_active),
        .rd_present(sp_present), .rd_pixel(sp_pixel), .rd_color(sp_color), .rd_priority(sp_priority)
    );

    // ---- compositor ----
    compositor u_compositor (
        .l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
        .l0_ctrl_enable(l0_enable), .l0_ctrl_opaque(l0_opaque), .l0_ctrl_transpen_sel(l0_transpen_sel),
        .l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
        .l1_ctrl_enable(l1_enable), .l1_ctrl_opaque(l1_opaque), .l1_ctrl_transpen_sel(l1_transpen_sel),
        .sp_present(sp_present), .sp_pixel(sp_pixel), .sp_color(sp_color), .sp_priority(sp_priority),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .rgb(rgb)
    );

endmodule
