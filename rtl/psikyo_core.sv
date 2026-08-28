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
//   1. Same cycle: spriteram_dbuf.frame_start -- begins a full COPY of the
//      live sprite RAM into the snapshot the render engine reads, and latches
//      this frame's sprites_disable/trans_pen* control bits.
//   2. ~4098 cycles later (snapshot_done, the falling edge of copy_busy):
//      sprite_render_engine.frame_start, gated by sprites_disable. Starting
//      earlier would render from a half-copied snapshot. If sprites are
//      disabled the engine is never kicked, which is "no sprites drawn".
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
    // Freeze the main CPU, so a frame can be captured and compared against a
    // MAME dump of the same moment without the game advancing underneath it.
    input  logic         pause,
`ifdef DEBUG_ISSP
    // Two automatic ways to reach `pause` without a human pressing the
    // button, each independently OSD-gated so neither fires unless asked
    // for -- see the auto-pause block below for what each does and why.
    input  logic         dbg_autopause_wr_en,
    input  logic         dbg_autopause_frame_en,
`endif
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
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in), .board_gunbird(board_gunbird), .pause(effective_pause),
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
    logic [11:0] pal_b_addr;
    logic [15:0] pal_b_rdata;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
        .clk(clk),
        .a_addr(pal_cpu_addr), .a_wel(pal_cpu_wel), .a_weh(pal_cpu_weh),
        .a_wdata(pal_cpu_wdata), .a_rdata(pal_cpu_rdata),
        .b_addr(pal_b_addr), .b_rdata(pal_b_rdata)
    );
    // Palette dump: rows 48..63 carry all 4096 xRGB_555 entries, addressed as
    // {vcnt[3:0],hcnt[7:0]}. The compositor's read port is free while the
    // overlay is up because the picture is discarded that frame.
    wire        pal_dump_active = DEBUG_TRACER && dbg_overlay
                                && (vcnt >= 9'd48) && (vcnt < 9'd64);
    wire [11:0] pal_dump_addr   = {vcnt[3:0], hcnt[7:0]};

    // ---- sprite palette snapshot ----
    // Sprites display pixels rendered one frame earlier (spriteram snapshot
    // -> render -> display), but palette lookups happen at scanout -- so a
    // scene change that rewrites the palette recolors the PREVIOUS scene's
    // still-displayed sprites for a frame. Sprites therefore read a
    // snapshot of their palette half (entries 0x000-0x1FF, the only range
    // sp_pal_offset can address), copied from the live palette during
    // vblank at frame_start -- the same boundary the sprite frame buffer
    // swaps on -- so sprite pixels and sprite colors change scene together.
    // Tilemaps render live and keep the live palette. The copy borrows the
    // live palette's read port for 513 cycles of vblank, long before
    // active display (or the overlay's dump rows) needs it.
    logic [9:0]  pal_copy_addr;
    logic         pal_copy_busy;
    logic [8:0]  pal_snap_waddr;
    logic         pal_snap_we;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            pal_copy_busy <= 1'b0;
            pal_copy_addr <= '0;
            pal_snap_we   <= 1'b0;
        end else if (frame_start) begin
            pal_copy_busy <= 1'b1;
            pal_copy_addr <= '0;
            pal_snap_we   <= 1'b0;
        end else if (pal_copy_busy) begin
            // the write trails the read by one cycle (BRAM read latency)
            pal_snap_we    <= (pal_copy_addr < 10'd512);
            pal_snap_waddr <= pal_copy_addr[8:0];
            if (pal_copy_addr == 10'd512) pal_copy_busy <= 1'b0;
            else                            pal_copy_addr <= pal_copy_addr + 10'd1;
        end else begin
            pal_snap_we <= 1'b0;
        end
    end

    logic [8:0]  pal_s_addr;
    logic [15:0] pal_s_data;
    logic         comp_sprite_sel, comp_sprite_sel_d;
    dpram #(.ADDR_WIDTH(9), .DATA_WIDTH(16)) u_palette_snap (
        .clk(clk),
        .a_addr(pal_snap_waddr), .a_wel(pal_snap_we), .a_weh(pal_snap_we),
        .a_wdata(pal_b_rdata), .a_rdata(),
        .b_addr(pal_s_addr), .b_rdata(pal_s_data)
    );

    assign pal_b_addr = pal_copy_busy   ? {3'd0, pal_copy_addr[8:0]} :
                         pal_dump_active ? pal_dump_addr : pal_addr;
    assign pal_data    = pal_b_rdata;

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

`ifdef DEBUG_ISSP
    // Two automatic ways to reach a paused CPU without a human pressing the
    // button, each independently OSD-gated (dbg_autopause_*_en) so neither
    // fires unless explicitly turned on -- otherwise every boot would auto
    // -pause, which would get in the way of any OTHER use of this build.
    //
    // 1. Write-triggered: pause the instant the CPU writes a SPECIFIC value
    //    to a SPECIFIC VRAM cell. Precise on the first try when the target
    //    address+value are already known (e.g. from a MAME investigation),
    //    and immune to any timing jitter in the boot sequence, because it
    //    fires on the semantic event itself rather than a fixed offset.
    //    Fixed to word 0x080 / value 0x2010 for now -- the specific cell
    //    this session's tilemap investigation is chasing.
    logic auto_pause_wr;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) auto_pause_wr <= 1'b0;
        else if (dbg_autopause_wr_en && (vram1_cpu_wel || vram1_cpu_weh) &&
                 vram1_cpu_addr == 12'h080 && vram1_cpu_wdata == 16'h2010)
            auto_pause_wr <= 1'b1;
        else if (!dbg_autopause_wr_en)
            auto_pause_wr <= 1'b0;   // OSD-disabling also clears a latched pause
    end

    // 2. Frame-count-triggered: pause N frames after the last (re)arm.
    //    Complements #1 for cases where the target SCREEN is known (e.g.
    //    from screenshot polling) but no specific address/value is --
    //    needs calibrating (arm, check the result, adjust N), but requires
    //    no ROM/VRAM knowledge at all. Source layout: bit 16 = rearm pulse
    //    (rising edge starts a fresh count), bits 15:0 = target frame count.
    wire [16:0] frame_pause_src;
    logic         frame_pause_rearm_d, frame_pause_armed, frame_pause_fired;
    logic [15:0] frame_pause_target, frame_pause_count;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            frame_pause_rearm_d <= 1'b0;
            frame_pause_armed    <= 1'b0;
            frame_pause_fired    <= 1'b0;
            frame_pause_count    <= 16'd0;
        end else begin
            frame_pause_rearm_d <= frame_pause_src[16];
            if (frame_pause_src[16] & ~frame_pause_rearm_d) begin
                frame_pause_target <= frame_pause_src[15:0];
                frame_pause_count  <= 16'd0;
                frame_pause_armed  <= 1'b1;
                frame_pause_fired  <= 1'b0;
            end else if (!dbg_autopause_frame_en) begin
                frame_pause_armed <= 1'b0;
                frame_pause_fired <= 1'b0;   // OSD-disabling also clears it
            end else if (frame_pause_armed && frame_start) begin
                if (frame_pause_count == frame_pause_target) begin
                    frame_pause_fired <= 1'b1;
                    frame_pause_armed <= 1'b0;
                end else begin
                    frame_pause_count <= frame_pause_count + 1'b1;
                end
            end
        end
    end

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .instance_id("F"),
        .probe_width(16),
        .source_width(17),
        .source_initial_value("0"),
        .enable_metastability("NO"),
        .lpm_type("altsource_probe")
    ) u_issp_framepause (
        .probe(frame_pause_count),
        .source(frame_pause_src),
        .source_clk(clk),
        .source_ena(1'b1)
    );

    wire auto_pause_frame = dbg_autopause_frame_en && frame_pause_fired;
`endif

    // Combined pause: the manual button plus whichever auto-triggers exist
    // and are enabled. In a non-DEBUG_ISSP build this reduces to exactly
    // `pause`, unchanged.
    wire effective_pause = pause
`ifdef DEBUG_ISSP
        | auto_pause_wr | auto_pause_frame
`endif
        ;

`ifdef DEBUG_ISSP
    // JTAG write probe for layer-1 VRAM -- to test the theory that a specific
    // screen position's render reads a DIFFERENT VRAM word than the one the
    // map says it should. Writes ONLY the value the theory predicts should
    // fix the visible bug; it does not (and structurally cannot) prove or
    // disprove the theory by itself -- the display result after the write is
    // the evidence, not the write succeeding.
    //
    // SAFETY: gated on `pause` -- the write is muxed onto port A, the SAME
    // port the CPU's own writes use, so a debug write landing the same cycle
    // as a real CPU write would be a genuine race with no defined winner.
    // With the CPU paused, cpu_wel/cpu_weh are naturally low and there is no
    // such race. Source layout: bit 28 = trigger, bits 27:12 = data,
    // bits 11:0 = address (word index, e.g. 0x081 for byte 0x802102).
    wire [28:0] vram1_wr_src;
    logic         vram1_wr_trig_d, dbg_vram1_wr_en;
    wire  [11:0] dbg_vram1_wr_addr = vram1_wr_src[11:0];
    wire  [15:0] dbg_vram1_wr_data = vram1_wr_src[27:12];
    logic [11:0] vram1_wr_last_addr;
    logic [15:0] vram1_wr_last_data;
    logic [15:0] vram1_wr_apply_count;

    always_ff @(posedge clk) begin
        if (reset) begin
            vram1_wr_trig_d       <= 1'b0;
            dbg_vram1_wr_en        <= 1'b0;
            vram1_wr_apply_count <= 16'd0;
        end else begin
            vram1_wr_trig_d <= vram1_wr_src[28];
            // Edge-triggered: one write per rising edge of the trigger bit,
            // regardless of how long it's held, and gated on pause so it can
            // only ever land when nothing else is writing this port.
            dbg_vram1_wr_en <= effective_pause & vram1_wr_src[28] & ~vram1_wr_trig_d;
            if (dbg_vram1_wr_en) begin
                vram1_wr_last_addr     <= dbg_vram1_wr_addr;
                vram1_wr_last_data     <= dbg_vram1_wr_data;
                if (vram1_wr_apply_count != 16'hFFFF)
                    vram1_wr_apply_count <= vram1_wr_apply_count + 1'b1;
            end
        end
    end

    wire [11:0] vram1_a_addr_muxed = dbg_vram1_wr_en ? dbg_vram1_wr_addr : vram1_cpu_addr;
    wire         vram1_a_wel_muxed  = dbg_vram1_wr_en ? 1'b1                : vram1_cpu_wel;
    wire         vram1_a_weh_muxed  = dbg_vram1_wr_en ? 1'b1                : vram1_cpu_weh;
    wire [15:0] vram1_a_wdata_muxed = dbg_vram1_wr_en ? dbg_vram1_wr_data : vram1_cpu_wdata;

    // probe readback: whether pause was actually asserted when the trigger's
    // rising edge occurred (so a write attempted without pausing first shows
    // up as "attempted, not applied" rather than silently doing nothing),
    // plus the count of writes actually applied and the last addr/data.
    logic wr_attempted_unpaused;
    always_ff @(posedge clk) begin
        if (reset) wr_attempted_unpaused <= 1'b0;
        else if (vram1_wr_src[28] & ~vram1_wr_trig_d & ~effective_pause)
            wr_attempted_unpaused <= 1'b1;
        else if (~vram1_wr_src[28]) // clears when trigger bit drops
            wr_attempted_unpaused <= 1'b0;
    end

    wire [63:0] vram1_wr_probe = {18'd0, wr_attempted_unpaused, effective_pause,
                                   vram1_wr_apply_count, vram1_wr_last_addr,
                                   vram1_wr_last_data};

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .instance_id("W"),
        .probe_width(64),
        .source_width(29),
        .source_initial_value("0"),
        .enable_metastability("NO"),
        .lpm_type("altsource_probe")
    ) u_issp_vram1wr (
        .probe(vram1_wr_probe),
        .source(vram1_wr_src),
        .source_clk(clk),
        .source_ena(1'b1)
    );

    // JTAG READ probe for spriteram (instance "S"), added 2026-08-29 during
    // the sprite/tilemap priority investigation -- the debug-overlay VRAM
    // dump (l0/l1/vregs/palette) never covered spriteram at all (no row
    // budget left in the 224-line overlay; see decode_vram.py), and MAME's
    // own buffered spriteram made it hard to confirm a specific sprite's
    // live attribute word by eye. Reads the CPU-VISIBLE buffer (the one
    // spriteram_dbuf's cpu_addr/cpu_rdata port serves, i.e. the SAME
    // buffer MAME's own debugger/memory viewer shows -- not the render
    // engine's snapshot copy) so a probed value is directly comparable to
    // a MAME-side dump at the same word address, no double-buffering
    // translation needed.
    //
    // Read-only, so simpler than the vram1_wr write probe: no wel/weh
    // override needed at all, and no trigger/edge-detect -- the source
    // address is just an ordinary combinational select, gated on
    // effective_pause the same way vram1_wr's writes are (with the CPU
    // paused, spr_cpu_wel/weh are naturally low, so overriding cpu_addr
    // alone can't collide with a real write). One register of read latency
    // (spriteram_dbuf's cpu_rdata is a normal synchronous BRAM output), so
    // the probe echoes effective_pause back too -- if it reads 0, the
    // returned data is whatever the LIVE game's own current address
    // happened to be, not the requested one.
    //
    // Usage (scripts/read_spriteram.tcl, word index 0-4095 -- attribute
    // table 0x000-0xBFF per docs/phase1_memory_map.md, display list
    // 0xC00-0xFFE, control word 0xFFF):
    //   quartus_stp -t scripts/read_spriteram.tcl <addr_hex>
    wire [11:0] dbg_spr_rd_addr;
    wire [11:0] spr_a_addr_muxed = effective_pause ? dbg_spr_rd_addr : spr_cpu_addr;

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .instance_id("S"),
        .probe_width(17),
        .source_width(12),
        .source_initial_value("0"),
        .enable_metastability("NO"),
        .lpm_type("altsource_probe")
    ) u_issp_sprrd (
        .probe({effective_pause, spr_cpu_rdata}),
        .source(dbg_spr_rd_addr),
        .source_clk(clk),
        .source_ena(1'b1)
    );
`endif

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
        .clk(clk),
`ifdef DEBUG_ISSP
        .a_addr(vram1_a_addr_muxed), .a_wel(vram1_a_wel_muxed), .a_weh(vram1_a_weh_muxed),
        .a_wdata(vram1_a_wdata_muxed), .a_rdata(vram1_cpu_rdata),
`else
        .a_addr(vram1_cpu_addr), .a_wel(vram1_cpu_wel), .a_weh(vram1_cpu_weh),
        .a_wdata(vram1_cpu_wdata), .a_rdata(vram1_cpu_rdata),
`endif
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
    // KNOWN BUG, NOT YET FIXED: both layers render one tile off in X on
    // screen (a one-tile vertical error once rotated, since X is the
    // rotated screen's Y axis; visible e.g. on the samuraia hiscore table).
    //
    // A -16 (one tile) compensating offset was tried here 2026-08-29 and
    // measured WRONG on hardware -- it moved the tilemaps the wrong way, so
    // the sign derivation from tilemap_x(screen_col) = base_x_scroll +
    // screen_col*16 does not hold as reasoned. Removed rather than flipped:
    // guessing the sign a second time from the same reasoning that was
    // already wrong once is not worth another build. base_x_scroll is fed to
    // the fetch pipeline unmodified again.
    //
    // Ruled out as a MAME register-level offset: psikyo_v.cpp's video_start()
    // calls tilemap_create with no set_scrolldx/set_scrolldy at all, and
    // get_tile_info<Layer> applies m_vram[Layer] directly with no per-layer
    // adjustment. So the cause is specific to this core's own fetch pipeline,
    // not the game data.
    //
    // Also checked and ruled out: an off-by-one in tilemap_coord.sv /
    // tilemap_addrgen.sv's col/row -> vram_index derivation. That arithmetic
    // is symmetric masking/bit-select with no added constant (verified
    // exhaustively by sim). And
    // tile_number/color are decoded from ONE vram_cell at ONE address in
    // tile_cell_decode, so a pure addressing bug there would shift graphics
    // and palette TOGETHER -- it cannot explain a tile that looks like the
    // right shape with the wrong colour (reported on Gunbird's logo), which
    // is a separate, still-open symptom. See docs/LESSONS_LEARNED.md.

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
`ifdef DEBUG_ISSP
        ,
        .dbg_fetch_vram_addr(l1_dbg_fetch_vram_addr), .dbg_vram_data(l1_dbg_vram_data),
        .dbg_cell_tile_number(l1_dbg_cell_tile_number), .dbg_cell_color(l1_dbg_cell_color),
        .dbg_mode_latched(l1_dbg_mode_latched), .dbg_bank_latched(l1_dbg_bank_latched),
        .dbg_pixel_src_addr(l1_dbg_pixel_src_addr), .dbg_pixel_src_word(l1_dbg_pixel_src_word)
`endif
    );

`ifdef DEBUG_ISSP
    // Wrong-palette/one-tile-shift investigation, layer 1. Snapshot every
    // stage of the fetch pipeline the moment the display shows the target
    // pixel, so what the hardware actually computed can be read directly
    // instead of inferred from source. See issp_probe.sv's header for why
    // ISSP rather than SignalTap (GUI-only in Quartus Lite 17.0).
    //
    // Trigger: latch once, on the first h_active pixel of vcnt==dbg_l1_trig_y
    // (an OSD-set target scanline, so this can be aimed at whatever row the
    // bad tile is on without a rebuild) after a clear. Held stable after
    // that -- read it at leisure over JTAG.
    logic [11:0] l1_dbg_fetch_vram_addr;
    logic [15:0] l1_dbg_vram_data;
    logic [14:0] l1_dbg_cell_tile_number;
    logic [6:0]  l1_dbg_cell_color;
    logic [1:0]  l1_dbg_mode_latched, l1_dbg_bank_latched;
    logic [11:0] l1_dbg_pixel_src_addr;   // DISPLAY side: which VRAM address the
                                          // pixel currently on screen came from
    logic [15:0] l1_dbg_pixel_src_word;   // ...and the raw word fetched for it

    logic [11:0] l1_snap_src_addr;   // which VRAM address caused the trigger
    logic [15:0] l1_snap_src_word;   // ...and its raw fetched word
    logic [11:0] l1_snap_vram_addr;
    logic [15:0] l1_snap_vram_data;
    logic [14:0] l1_snap_tile_number;
    logic [6:0]  l1_snap_color;
    logic [1:0]  l1_snap_mode, l1_snap_bank;
    logic [3:0]  l1_snap_pixel_index;
    logic [6:0]  l1_snap_pixel_color;
    logic [11:0] l1_snap_pal_addr;
    logic         l1_snap_taken;
    logic [0:0]  l1_snap_clear;
    logic [11:0] l1_dbg_trig_addr;

    // History of this trigger, in order:
    //   1. Scanline-triggered: fired on the first h_active pixel of a raster
    //      line, capturing whatever the fetch pipeline happened to be doing
    //      at that instant. Given PREFETCH_DEPTH tiles of run-ahead, that is
    //      essentially never the specific cell of interest -- measured twice,
    //      same trig_y, same paused frame, fetch_vram_addr=0x109 both times.
    //   2. Fetch-address-triggered: fired when the FETCH side read the target
    //      address. This reliably hits the address, but l1_snap_pixel_color/
    //      pal_addr below were captured from the DISPLAY side at that same
    //      instant, which -- again because of prefetch run-ahead -- is a
    //      DIFFERENT tile, dozens of tiles behind whatever is being fetched.
    //      Measured 7 times, including once during the visually-confirmed
    //      bug frame: fetch+decode was correct every single time. That is
    //      real evidence the bug is not in the fetch/decode path, but it
    //      could not answer the actual question, because it was comparing
    //      two different tiles.
    //   3. Display-address-triggered: buf_src_addr[] tags each prefetch slot
    //      with the address it was fetched from, and triggering when
    //      dbg_pixel_src_addr matches a target address gives a true
    //      same-tile correlation. Correct design, but still needs the RIGHT
    //      MOMENT: caught the Gunbird logo scene precisely (screenshot
    //      confirmed) and measured pixel_color=70 -- neither the expected
    //      "correct" (65) nor the known "bug" (64) value, because the logo
    //      turned out to be animated and word 0x080's content changes
    //      across the sequence. The single paused-frame reproduction
    //      (0x2010/field=1 -> should be 65) does not generalize to every
    //      instant of a moving scene, and there is no way to pause the
    //      game without a user present.
    //   4. Self-consistency-triggered (this version): tilemap_line_engine.sv
    //      now ALSO tags each slot with the raw word it was fetched from
    //      (buf_src_word[]), so the display side can check its OWN
    //      prediction against itself: does buf_color[slot] (what's actually
    //      being shown) match what buf_src_word[slot]'s color field
    //      predicts? This needs no external reference and no timing
    //      coordination at all -- it fires automatically, on whatever tile,
    //      the instant a genuine buffer-level corruption occurs, if one
    //      ever does. Left running unattended; see whether it has fired
    //      when read back.
    always_ff @(posedge clk) begin
        if (reset || l1_snap_clear) begin
            l1_snap_taken <= 1'b0;
        end else if (!l1_snap_taken &&
                     ({4'd0, l1_dbg_pixel_src_word[15:13]} + 7'd64 != l1_pixel_color)) begin
            // SELF-CONSISTENCY trigger: fires the instant the color actually
            // being displayed disagrees with what the slot's OWN tagged raw
            // word predicts. Needs no external reference, no address guess,
            // no timing coordination with a screenshot -- if this ever
            // fires, it is proof of a genuine buffer-level corruption,
            // caught automatically whenever it happens, on whatever tile.
            // l1_dbg_trig_addr/arm do not gate triggering; they are kept
            // in the readout for context only.
            l1_snap_taken       <= 1'b1;
            l1_snap_src_addr     <= l1_dbg_pixel_src_addr;
            l1_snap_src_word     <= l1_dbg_pixel_src_word;
            l1_snap_vram_addr   <= l1_dbg_fetch_vram_addr;
            l1_snap_vram_data   <= l1_dbg_vram_data;
            l1_snap_tile_number <= l1_dbg_cell_tile_number;
            l1_snap_color        <= l1_dbg_cell_color;
            l1_snap_mode         <= l1_dbg_mode_latched;
            l1_snap_bank         <= l1_dbg_bank_latched;
            l1_snap_pixel_index <= l1_pixel_index;
            l1_snap_pixel_color <= l1_pixel_color;
            l1_snap_pal_addr     <= pal_addr;
        end
    end

    wire [117:0] l1_probe_bus = {l1_snap_taken, l1_dbg_trig_addr,
                                 l1_snap_src_addr, l1_snap_src_word,
                                 l1_snap_vram_addr, l1_snap_vram_data,
                                 l1_snap_tile_number, l1_snap_color,
                                 l1_snap_mode, l1_snap_bank,
                                 l1_snap_pixel_index, l1_snap_pixel_color,
                                 l1_snap_pal_addr};
    wire [12:0] l1_probe_src;
    assign l1_snap_clear    = l1_probe_src[0];
    assign l1_dbg_trig_addr = l1_probe_src[12:1];

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .instance_id("V"),
        .probe_width(118),
        .source_width(13),
        .source_initial_value("0"),
        .enable_metastability("NO"),
        .lpm_type("altsource_probe")
    ) u_issp_l1vram (
        .probe(l1_probe_bus),
        .source(l1_probe_src),
        .source_clk(clk),
        .source_ena(1'b1)
    );
`endif

    // ---- sprite RAM (double-buffered) + sprite pipeline ----
    logic [11:0] dl_addr, at_addr;
    logic [15:0] dl_data, at_data;
    logic         sprites_disable, trans_pen0, trans_pen15;
    logic         spr_copy_busy;

    spriteram_dbuf u_spriteram (
        .clk(clk), .reset(reset), .frame_start(frame_start),
        .copy_busy(spr_copy_busy),
`ifdef DEBUG_ISSP
        .cpu_addr(spr_a_addr_muxed),
`else
        .cpu_addr(spr_cpu_addr),
`endif
        .cpu_wel(spr_cpu_wel), .cpu_weh(spr_cpu_weh),
        .cpu_wdata(spr_cpu_wdata), .cpu_rdata(spr_cpu_rdata),
        .dl_addr(dl_addr), .dl_data(dl_data), .at_addr(at_addr), .at_data(at_data),
        .sprites_disable(sprites_disable), .trans_pen0(trans_pen0), .trans_pen15(trans_pen15)
    );

    // Render must not start until the sprite-RAM snapshot is complete, so the
    // start pulse is the falling edge of copy_busy, not frame_start.
    logic spr_copy_busy_d, snapshot_done;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) spr_copy_busy_d <= 1'b0;
        else        spr_copy_busy_d <= spr_copy_busy;
    end
    assign snapshot_done = spr_copy_busy_d & ~spr_copy_busy;

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
    wire want_frame = snapshot_done & ~sprites_disable & ~dbg_render_dis[0];

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



    // fb_y is still needed: the frame buffer is 2D.
    logic [7:0]  fb_y;

    // ---- sprite render + double-buffered frame buffer ----
    sprite_render_engine u_sprite_render (
        .clk(clk), .reset(reset),
        .frame_start(sprite_frame_start), .frame_busy(sp_frame_busy), .frame_done(sp_frame_done),
        .trans_pen0(trans_pen0), .trans_pen15(trans_pen15),
        .dl_addr(dl_addr), .dl_data(dl_data),
        .at_addr(at_addr), .at_data(at_data),
        .lut_req(sp_lut_req), .lut_addr(sp_lut_addr), .lut_valid(sp_lut_valid), .lut_data(sp_lut_data),
        .gfxrom_req(sp_gfxrom_req), .gfxrom_addr(sp_gfxrom_addr),
        .gfxrom_valid(sp_gfxrom_valid), .gfxrom_data(sp_gfxrom_data),
        .fb_we(fe_fb_we), .fb_x(fe_fb_x), .fb_y(fb_y),
        .fb_pixel(fe_fb_pixel), .fb_color(fe_fb_color), .fb_priority(fe_fb_priority)
    );

    logic         fe_fb_we;
    logic [8:0]  fe_fb_x;
    logic [3:0]  fe_fb_pixel;
    logic [4:0]  fe_fb_color;
    logic [1:0]  fe_fb_priority;

    logic         sp_present;
    logic [3:0]  sp_pixel;
    logic [4:0]  sp_color;
    logic [1:0]  sp_priority;

    sprite_frame_buffer u_sprite_fb (
        .clk(clk), .reset(reset),
        .frame_swap(sprite_swap_now), .swap_busy(sp_swap_busy), .swap_done(sp_swap_done),
        .fb_we(fe_fb_we), .fb_x(fe_fb_x), .fb_y(fb_y),
        .fb_pixel(fe_fb_pixel), .fb_color(fe_fb_color), .fb_priority(fe_fb_priority),
        .rd_x(hcnt), .rd_y(vcnt_active),
        .rd_present(sp_present), .rd_pixel(sp_pixel), .rd_color(sp_color), .rd_priority(sp_priority)
    );

    // ---- compositor ----
    compositor u_compositor (
        .l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
        .l0_ctrl_enable(l0_enable & ~dbg_render_dis[1]), .l0_ctrl_opaque(l0_opaque), .l0_ctrl_transpen_sel(l0_transpen_sel),
        .l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
        .l1_ctrl_enable(l1_enable & ~dbg_render_dis[2]), .l1_ctrl_opaque(l1_opaque), .l1_ctrl_transpen_sel(l1_transpen_sel),
        // dbg_render_dis[0] already stops sprite_frame_buffer from starting a
        // NEW render pass (want_frame, above) -- but with the frame double-
        // buffered, that alone just freezes the display bank at whatever it
        // last rendered instead of blanking it: nothing ever un-swaps it.
        // Tilemaps don't have this problem (l0/l1_ctrl_enable gate the
        // compositor's LIVE per-pixel input directly, taking effect
        // instantly), which is why "disable sprites" looked like it did
        // nothing while "disable tilemap" worked. Gate the compositor input
        // the same way tilemaps do, so the OSD toggle blanks sprites
        // immediately regardless of what's sitting in the display bank.
        .sp_present(sp_present & ~dbg_render_dis[0]), .sp_pixel(sp_pixel), .sp_color(sp_color), .sp_priority(sp_priority),
        .pal_addr(pal_addr), .pal_s_addr(pal_s_addr), .sprite_sel(comp_sprite_sel)
    );

    // Final RGB mux: both palette RAMs (live for tilemap/backdrop, snapshot
    // for sprites) are read in parallel; their outputs arrive one cycle
    // after the compositor chose a winner, so the select is registered to
    // match -- the same alignment a single address-side mux would have.
    always_ff @(posedge clk) comp_sprite_sel_d <= comp_sprite_sel;
    assign rgb = comp_sprite_sel_d ? pal_s_data[14:0] : pal_data[14:0];


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
            .rd_index(vcnt - 9'd64),
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
            .rd_index(vcnt - 9'd192),
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
        //   rows  48- 63 : palette RAM, all 4096 xRGB_555 entries
        assign dbg_pixel = (vcnt == 9'd215) ? {4'd0, sp_render_max}
                         : (vcnt >= 9'd216) ? ctl_echo
                         : (vcnt <  9'd16)  ? {8'h00, vram0_b_rdata}
                         : (vcnt <  9'd32)  ? {8'h00, vram1_b_rdata}
                         : (vcnt <  9'd48)  ? {8'h00, vregs_dump_data}
                         : (vcnt <  9'd64)  ? {8'h00, pal_b_rdata}
                         : (vcnt <  9'd192) ? rd_addr
                                            : rd_data;
    end else begin : g_no_tracer
        assign dbg_pixel = 24'd0;
    end endgenerate

endmodule
