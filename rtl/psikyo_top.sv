// Connects rtl/psikyo_core.sv (video+CPU) directly to
// rtl/memory/psikyo_sdram_top.sv (the SDRAM backend) -- both modules were
// built with matching ROM port shapes specifically so this step would be a
// straight port-to-port connection, not new logic (docs/ROADMAP.md's Next
// steps) -- plus the board-appropriate sound CPU wrapper
// (rtl/sound/sound_cpu.sv, selected at runtime by board_gunbird, the same
// signal psikyo_core.sv already uses), whose
// req/valid ROM port and sound-latch handshake were built to match
// psikyo_core.sv's own latch_data/latch_write output and
// psikyo_sdram_top.sv's audiocpu_rom_* port directly. What's still missing
// before this reaches Psikyo.sv/emu.sv: jt10 (YM2610) itself -- the sound
// CPU's ym_* chip-select bus is exposed at this module's boundary,
// unconnected, since jt10 hasn't had its own audio-domain verification
// pass yet (docs/ROADMAP.md's Next steps) -- and the HPS/DIP/CRT_Offset
// glue that belongs in Psikyo.sv itself, one level up.
//
// audiocpu_rom_addr's width: sound_cpu.sv exposes a 17-bit rom_addr (already the flattened {bank,addr[14:0]}
// physical byte address across the whole banked ROM window, confirmed
// against real bankswitch source in docs/ROADMAP.md's sound-subsystem
// notes), zero-extended by 1 bit to match psikyo_sdram_top.sv's 18-bit
// audiocpu_rom_addr port (sized for the full 256KB audiocpu SDRAM
// region, docs/phase1_sdram_map.md's address map -- sngkace/gunbird's
// actual ROM content is smaller than that reservation, same padding
// convention the .mra files already use).
//
// Two separate reset domains, not one shared `reset` -- found necessary by
// a real failure, not designed in speculatively: `psikyo_sdram_top.sv`
// must stay out of reset WHILE `ioctl_download` is active (that's exactly
// when it has to actually work, receiving the HPS download), but
// `psikyo_core.sv`'s CPU/video logic must stay held quiescent for that
// same span (nothing useful for it to do with a partially-loaded ROM, and
// real hardware holds the core in reset during load) -- the standard
// MiSTer idiom `reset | ioctl_download` for the core is what implements
// that. Wiring the SAME `reset` into both (the first version of this
// module did exactly that) makes the SDRAM backend's own req/valid
// wrappers reset continuously for the whole download, since the natural
// way to sequence a download-then-run test is to hold reset asserted
// throughout loading -- silently discarding every downloaded byte with no
// error, only visible by tracing dstate stuck at D_IDLE despite ioctl_wr
// pulsing correctly (sim/psikyo_top_tb/tb_psikyo_top.sv's own history).
module psikyo_top #(
    parameter bit BOARD_GUNBIRD = 1'b0,
    parameter bit DEBUG_TRACER  = 1'b1
) (
    input  logic clk,
    input  logic ce_pix,
    input  logic reset,
    input  logic init,

    output logic [12:0] SDRAM_A,
    output logic         SDRAM_DQML,
    output logic         SDRAM_DQMH,
    output logic [1:0]  SDRAM_BA,
    output logic         SDRAM_nCS,
    output logic         SDRAM_nWE,
    output logic         SDRAM_nRAS,
    output logic         SDRAM_nCAS,
    output logic         SDRAM_CLK,
    output logic         SDRAM_CKE,
    inout  wire [15:0]  SDRAM_DQ,

    // HPS ROM download.
    input  logic         ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic         ioctl_wr,
    input  logic [24:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    output logic         ioctl_wait,

    // Inputs (raw values -- caller owns debouncing/mapping).
    input  logic [31:0] p1p2_in,
    input  logic [31:0] dsw_in,
    input  logic [31:0] coin_in,
    input  logic         board_gunbird,
    // SH403/SH404 flags + MCU table download -- docs/phase2_sh404.md.
    input  logic         board_sh404,
    input  logic         snd_latch_c00011,
    input  logic         mcu_table_absent,
    input  logic         mcu_table_we,
    input  logic [7:0]  mcu_table_waddr,
    input  logic [7:0]  mcu_table_wdata,
    input  logic         needs_adpcma_swap,   // see psikyo_sdram_top.sv's port comment

    // Mirrors MAME's psikyo_state::z80_nmi_r() -- see
    // rtl/sound/sound_cpu.sv's own comment for the full derivation.
    // Not looped back into p1p2_in/coin_in internally: which bit position
    // it occupies is board-specific (sngkace's own separate COIN port vs.
    // gunbird's P1P2 port bit 7), so the caller folds this into whichever
    // input word it assembles, same as it already owns all other
    // board-specific bit layout decisions.
    output logic         nmi_pending,

    // Audio, from the YM2610 (jt10) instantiated below.
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,

    // Video output.
    output logic [8:0]  hcnt,
    output logic [8:0]  vcnt,
    output logic         hblank,
    output logic         vblank,
    output logic         hsync,
    output logic         vsync,
    output logic [14:0] rgb,

    // ---- debug tracer, live-controlled from the OSD ----
    input  logic         dbg_overlay,
    input  logic [2:0]  dbg_render_dis,
    input  logic         pause,
`ifdef DEBUG_ISSP
    input  logic         dbg_autopause_wr_en,
    input  logic         dbg_autopause_frame_en,
`endif
    input  logic         snd_irq_en,
    input  logic         dbg_sprite_vsync_swap,
    input  logic [1:0]  dbg_src,
    input  logic [3:0]  dbg_window,
    input  logic         dbg_rearm,
    output logic [23:0] dbg_pixel
);

    logic         cpu_rom_req;
    logic [18:0] cpu_rom_addr;
    logic         cpu_rom_valid;
    logic [15:0] cpu_rom_data;

    logic         l0_gfxrom_req, l1_gfxrom_req;
    logic [21:0] l0_gfxrom_addr, l1_gfxrom_addr;
    logic         l0_gfxrom_valid, l1_gfxrom_valid;
    logic [63:0] l0_gfxrom_data, l1_gfxrom_data;

    logic         sp_gfxrom_req, sp_lut_req;
    logic [22:0] sp_gfxrom_addr;
    logic [16:0] sp_lut_addr;
    logic         sp_gfxrom_valid, sp_lut_valid;
    logic [63:0] sp_gfxrom_data;
    logic [15:0] sp_lut_data;

    // ---- YM2610 chip bus, sound CPU <-> jt10 ----
    // Explicit declarations REQUIRED: without them Quartus silently creates
    // 1-bit implicit nets for ym_dout/ym_din/ym_addr and truncates the bus.
    logic        ym_cs, ym_rd, ym_wr, ym_irq_n;
    logic [1:0] ym_addr;
    logic [7:0] ym_dout, ym_din;

    logic [7:0]  latch_data;
    logic         latch_write;

    logic         audiocpu_rom_req_raw;
    logic [16:0] audiocpu_rom_addr_raw;
    logic         audiocpu_rom_valid;
    logic [7:0]  audiocpu_rom_data;

    // Core reset: plain reset OR active download -- see module header.
    logic core_reset;
    assign core_reset = reset | ioctl_download;

    // SDRAM backend reset -- deliberately NOT plain `reset`, and this is the
    // second time this project has been bitten by the same hazard.
    //
    // The module header already documents that psikyo_sdram_top must stay out
    // of reset while ioctl_download is active, and fixes it by passing plain
    // `reset` here rather than `core_reset`. That is NOT sufficient, because
    // `reset` is ITSELF asserted for the whole download: MiSTer holds core
    // RESET across the ROM transfer (Psikyo.sv builds reset from RESET, and
    // sys_top drives RESET from sysmem_lite's reset_out via reset_core_req,
    // which the HPS asserts around loading). Measured on real hardware: the
    // (reset && ioctl_download) cycle counter saturated -- reset covers the
    // entire transfer.
    //
    // The consequence was total and silent. sdram_download's FSM never left
    // D_IDLE, so dl_req never asserted, the arbiter never selected the
    // download path, and a pin-level counter on {nRAS,nCAS,nWE} confirmed
    // ZERO CMD_WRITE commands ever reached the chip -- while every one of the
    // 0xE00000 bytes was delivered by the HPS and accepted by the FSM. SDRAM
    // stayed completely unwritten, so the CPU read garbage for its reset
    // vector and ran away into unmapped space.
    //
    // Upstream Sorgelig sdram.v has no reset port at all by design -- it is
    // driven purely by `init` -- precisely so a core reset cannot disturb
    // memory. This project's own wrappers added a reset, so they must
    // explicitly hold it off while a download is in flight. Resetting them
    // once the download finishes is harmless: sdram.sv itself has no reset
    // input, its init sequence is driven separately by `init`, and the
    // contents of the chip are unaffected.
    logic sdram_reset;
    assign sdram_reset = reset & ~ioctl_download;




    psikyo_core #(.BOARD_GUNBIRD(BOARD_GUNBIRD), .DEBUG_TRACER(DEBUG_TRACER)) u_core (
        .clk(clk), .ce_pix(ce_pix), .reset(core_reset),
        .cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
        .cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
        .l0_gfxrom_req(l0_gfxrom_req), .l0_gfxrom_addr(l0_gfxrom_addr),
        .l0_gfxrom_valid(l0_gfxrom_valid), .l0_gfxrom_data(l0_gfxrom_data),
        .l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
        .l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
        .sp_gfxrom_req(sp_gfxrom_req), .sp_gfxrom_addr(sp_gfxrom_addr),
        .sp_gfxrom_valid(sp_gfxrom_valid), .sp_gfxrom_data(sp_gfxrom_data),
        .sp_lut_req(sp_lut_req), .sp_lut_addr(sp_lut_addr),
        .sp_lut_valid(sp_lut_valid), .sp_lut_data(sp_lut_data),
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in), .board_gunbird(board_gunbird),
        .board_sh404(board_sh404), .snd_latch_c00011(snd_latch_c00011),
        .mcu_table_absent(mcu_table_absent), .mcu_table_we(mcu_table_we),
        .mcu_table_waddr(mcu_table_waddr), .mcu_table_wdata(mcu_table_wdata),
        .latch_data(latch_data), .latch_write(latch_write),
        .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync), .rgb(rgb),
        .dbg_overlay(dbg_overlay), .dbg_render_dis(dbg_render_dis), .pause(pause),
`ifdef DEBUG_ISSP
        .dbg_autopause_wr_en(dbg_autopause_wr_en), .dbg_autopause_frame_en(dbg_autopause_frame_en),
`endif
        .dbg_sprite_vsync_swap(dbg_sprite_vsync_swap), .dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
        .dbg_pixel(dbg_pixel)
    );

    // Board-appropriate sound CPU. Was selected by the compile-time
    // BOARD_GUNBIRD parameter via two separate modules (sound_cpu_gunbird.sv /
    // sound_cpu_sngkace.sv), but nothing ever overrode that parameter -- this
    // core selects its board at RUNTIME instead (board_gunbird, from the
    // .mra's mod byte), the same way maincpu.sv and every input/DIP path
    // already does, so every build silently got sngkace's memory map
    // regardless of which game was loaded. sound_cpu.sv merges the two (they
    // differed only in memory map / RAM size / I/O decode / bank-register
    // bits) behind a runtime board_gunbird input.
    //
    // Held quiescent by core_reset for the same reason maincpu.sv is --
    // nothing useful to do with a partially-loaded ROM, and it shares the
    // audiocpu SDRAM region with the download path.
`ifdef DEBUG_ISSP
    logic dbg_latch_ack_event;
`endif
    // 4 MHz Z80 clock enable: Bresenham 44/945 (clk_sys = 945/11 MHz), the
    // same scheme as ym_cen below and exactly half its rate -- see
    // sound_cpu.sv's cen_4m port comment for why the rate matters.
    logic [9:0] z80_cen_acc = 10'd0;
    logic        z80_cen;
    always_ff @(posedge clk) begin
        if (z80_cen_acc >= 10'd945 - 10'd44) z80_cen_acc <= z80_cen_acc + 10'd44 - 10'd945;
        else                                   z80_cen_acc <= z80_cen_acc + 10'd44;
    end
    assign z80_cen = (z80_cen_acc >= 10'd945 - 10'd44);

    sound_cpu u_sound (
        .clk(clk), .reset(core_reset), .board_gunbird(board_gunbird), .board_sh404(board_sh404),
        .cen_4m(z80_cen),
        .rom_req(audiocpu_rom_req_raw), .rom_addr(audiocpu_rom_addr_raw),
        .rom_valid(audiocpu_rom_valid), .rom_data(audiocpu_rom_data),
        .latch_data(latch_data), .latch_write(latch_write),
        .nmi_pending(nmi_pending),
        .ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
        .ym_dout(ym_dout), .ym_din(ym_din), .ym_irq_n(ym_irq_n | ~snd_irq_en)
`ifdef DEBUG_ISSP
        , .dbg_latch_ack_event(dbg_latch_ack_event)
`endif
    );

    // ---- YM2610 (jt10) ----
    // 8 MHz on both boards: sngkace XTAL(32MHz)/4, gunbird 16MHz/2 (psikyo.cpp
    // machine configs). clk_sys is 945/11 MHz, so an exact 8 MHz enable is
    // Bresenham 88/945 -- the same denominator as the 68020's 176/945 16 MHz
    // enable, which it is exactly half of.
    logic [9:0] ym_cen_acc = 10'd0;
    logic        ym_cen;
    always_ff @(posedge clk) begin
        if (ym_cen_acc >= 10'd945 - 10'd88) ym_cen_acc <= ym_cen_acc + 10'd88 - 10'd945;
        else                                  ym_cen_acc <= ym_cen_acc + 10'd88;
    end
    assign ym_cen = (ym_cen_acc >= 10'd945 - 10'd88);

    // ---- YM2610 ADPCM-A sample fetch ----
    // jt10 pulls adpcma_roe_n low when it wants the byte at adpcma_addr. The
    // engine is 6 channels at ~18.5 kHz, about one byte every 1.5 us
    // aggregate (~130 clk at 85.909 MHz), so an SDRAM round trip fits easily
    // inside the gap and no prefetch is needed.
    //
    // adpcma_bank is ignored: it exists for NeoGeo's multi-megabyte banked
    // sample ROMs, and psikyo's ADPCM-A region is a single 1MB image, so
    // addr[19:0] covers all of it.
    logic [19:0] adpcma_addr;
    logic [4:0]  adpcma_bank;
    logic         adpcma_roe_n;
    logic [23:0] adpcmb_addr;
    logic         adpcmb_roe_n;

    logic        adpcma_rom_req, adpcma_rom_valid, adpcma_roe_n_d;
    logic [7:0]  adpcma_rom_data, adpcma_data_r;

    always_ff @(posedge clk) begin
        if (core_reset) begin
            adpcma_rom_req <= 1'b0;
            adpcma_data_r  <= 8'd0;
            adpcma_roe_n_d <= 1'b1;
        end else begin
            adpcma_roe_n_d <= adpcma_roe_n;
            if (adpcma_roe_n_d & ~adpcma_roe_n) adpcma_rom_req <= 1'b1;
            else if (adpcma_rom_valid) begin
                adpcma_rom_req <= 1'b0;
                adpcma_data_r  <= adpcma_rom_data;
            end
        end
    end

    // ADPCM-B (delta-T): same roe_n-edge -> req -> latch glue as ADPCM-A
    // above. Address bit 20 selects the delta-T ROM: KA302C boards
    // (gunbird/btlkroad/s1945n) have their OWN delta-T image (u64) at
    // +0x100000 in the sample region, while SH201B (samuraia/sngkace) has
    // none and MAME's YM2610 serves deltat from the adpcma image at +0 --
    // see psikyo_sdram_top.sv's adpcmb_rom_addr port comment.
    logic        adpcmb_rom_req, adpcmb_rom_valid, adpcmb_roe_n_d;
    logic [7:0]  adpcmb_rom_data, adpcmb_data_r;
    logic [20:0] adpcmb_sdram_addr;
    assign adpcmb_sdram_addr = {board_gunbird, adpcmb_addr[19:0]};

    always_ff @(posedge clk) begin
        if (core_reset) begin
            adpcmb_rom_req <= 1'b0;
            adpcmb_data_r  <= 8'd0;
            adpcmb_roe_n_d <= 1'b1;
        end else begin
            adpcmb_roe_n_d <= adpcmb_roe_n;
            if (adpcmb_roe_n_d & ~adpcmb_roe_n) adpcmb_rom_req <= 1'b1;
            else if (adpcmb_rom_valid) begin
                adpcmb_rom_req <= 1'b0;
                adpcmb_data_r  <= adpcmb_rom_data;
            end
        end
    end

    jt10 u_ym2610 (
        .rst        (core_reset),
        .clk        (clk),
        .cen        (ym_cen),
        .din        (ym_dout),
        .addr       (ym_addr),
        .cs_n       (~(ym_cs & (ym_rd | ym_wr))),
        .wr_n       (~ym_wr),
        .dout       (ym_din),
        .irq_n      (ym_irq_n),

        .adpcma_addr(adpcma_addr), .adpcma_bank(adpcma_bank),
        .adpcma_roe_n(adpcma_roe_n), .adpcma_data(adpcma_data_r),
        .adpcmb_addr(adpcmb_addr), .adpcmb_roe_n(adpcmb_roe_n), .adpcmb_data(adpcmb_data_r),

        .psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(),
        .snd_right  (snd_right),
        .snd_left   (snd_left),
        .snd_sample (),
        .ch_enable  (6'b111111)
    );

    logic         audiocpu_rom_req;
    logic [17:0] audiocpu_rom_addr;
    assign audiocpu_rom_req  = audiocpu_rom_req_raw;
    assign audiocpu_rom_addr = {1'b0, audiocpu_rom_addr_raw};

    // TEMPORARY DEBUG TAP -- does the HPS ROM download actually LAND?
    //
    // Established so far: the CPU fetches the reset vector from the correct
    // addresses but SDRAM returns wrong data, identically at two SDRAM_CLK
    // phases a quarter-period apart (8598 ps and 2910 ps) on a build whose
    // CPU closes timing. So it is not read-side interface timing. Every
    // in-ROM-range address returns essentially one constant (0xCDCD), which
    // is what unwritten SDRAM looks like.
    //
    // The one thing real hardware demands that simulation does not is
    // correct ioctl_wait backpressure: the HPS streams bytes continuously,
    // and sdram_download.sv asserts ioctl_wait from a REGISTERED dstate, so
    // it rises one cycle after a write is accepted. Any ioctl_wr arriving in
    // that window is silently dropped -- the byte is simply never written,
    // leaving that location at its power-up value.
    //
    //   R:G:B = 24-bit count of ioctl_wr pulses that arrived while
    //           ioctl_wait was already HIGH, i.e. DROPPED bytes.
    //
    // 0x000000 => backpressure is correct and the download is not the fault.
    // Anything large => bytes are being dropped and the ROM image in SDRAM
    // is incomplete, which would explain the garbage directly.
    // Round 2 of this tap. Round 1 counted only DROPPED bytes and read
    // 0x000000 -- which was inconclusive, because zero drops is also exactly
    // what a download that never happened at all looks like. Count totals
    // instead, both scaled by >>12 (4096-byte granularity) so each fits in
    // 12 bits:
    //   R:G[7:4]  = total ioctl_wr pulses seen   >> 12
    //   G[3:0]:B  = SDRAM byte writes issued     >> 12
    //
    // The MRA reserves 0xE00000 bytes, so BOTH should read 0xE00 (3584) if
    // the HPS sent the whole image and every byte reached the SDRAM write
    // path. 0x000 on the first => the core never received a download at all.
    // First large, second small => bytes are being lost inside the download
    // path rather than at the ioctl handshake.
    // Round 3 of this tap. Rounds 1 and 2 both read 0x000000 but were BOTH
    // inconclusive for the same reason: their counters were cleared by
    // `reset`, so a zero could equally mean "held in reset" as "never
    // happened". These have NO reset at all -- Quartus powers registers up
    // to 0 -- so whatever they show is what actually occurred since
    // configuration, and cannot be an artefact of reset timing.
    //
    //   R:G[7:4]  = ioctl_download RISING EDGES (did a download ever start?)
    //   G[3:0]:B  = ioctl_wr pulses >> 12 (4096-byte units; 0xE00 = the full
    //               0xE00000 the MRA reserves)
    //
    // 0x000/0x000 => the core never sees a download at all: the fault is in
    //   hps_io/CONF_STR/MRA delivery, not in any of the SDRAM RTL.
    // >=1 / 0xE00  => the download is fine and the loss is downstream.
    // >=1 / small  => the download starts but stalls partway.
    // Round 4 of this tap. Round 3 (no reset, so trustworthy) proved the HPS
    // delivers the COMPLETE image: 0xE00 * 4096 = 0xE00000 ioctl_wr pulses,
    // exactly the MRA's reservation. So the bytes arrive at this module and
    // are lost downstream.
    //
    // sdram_download.sv accepts a byte only when ioctl_index == 16'd0. If
    // MiSTer tags MRA ROM data with any other index, every byte is discarded
    // in silence while the delivery counters still look perfect. Measure the
    // index directly, and count bytes that actually pass the FSM's accept
    // condition:
    //   R:G[7:4]  = ioctl_index[11:0] latched during download
    //   G[3:0]:B  = bytes ACCEPTED (index==0 && !ioctl_wait) >> 12
    //
    // index 0 + 0xE00 => acceptance is fine; look further down the chain.
    // index != 0      => root cause: sdram_download.sv's index filter.
    // index 0 + small => the FSM is stalling and losing bytes.
    // Round 5 of this tap. Round 4 proved the download FSM ACCEPTS all
    // 0xE00000 bytes (the index filter is fine -- the 254 that showed up is
    // MiSTer's DIP-settings transfer, sent after the ROM). So delivery and
    // acceptance are both perfect, and the bytes are lost between the FSM
    // and the chip.
    //
    // Measure at the SDRAM PINS themselves, which are top-level signals
    // here, so this counts what the chip actually sees rather than what the
    // RTL intended. sdram.sv encodes commands on {nRAS,nCAS,nWE}:
    //   CMD_WRITE = 3'b100, CMD_READ = 3'b101.
    //
    //   R:G[7:4]  = WRITE commands issued to the chip >> 12
    //   G[3:0]:B  = READ  commands issued to the chip >> 12
    //
    // The download is byte-at-a-time single-word writes, so writes should
    // reach 0xE00 (0xE00000). If it does, the commands genuinely reach the
    // chip and the chip is not storing them -- an init/electrical problem
    // rather than an RTL one. If it stays near zero, sdram.sv never issues
    // the writes and the fault is in the controller or arbiter.

    psikyo_sdram_top u_sdram (
        .clk(clk), .reset(sdram_reset), .init(init),
        .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait), .needs_adpcma_swap(needs_adpcma_swap),
        .l0_gfxrom_req(l0_gfxrom_req), .l0_gfxrom_addr(l0_gfxrom_addr),
        .l0_gfxrom_valid(l0_gfxrom_valid), .l0_gfxrom_data(l0_gfxrom_data),
        .l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
        .l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
        .sp_gfxrom_req(sp_gfxrom_req), .sp_gfxrom_addr(sp_gfxrom_addr),
        .sp_gfxrom_valid(sp_gfxrom_valid), .sp_gfxrom_data(sp_gfxrom_data),
        .sp_lut_req(sp_lut_req), .sp_lut_addr(sp_lut_addr),
        .sp_lut_valid(sp_lut_valid), .sp_lut_data(sp_lut_data),
        .cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
        .cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
        .audiocpu_rom_req(audiocpu_rom_req), .audiocpu_rom_addr(audiocpu_rom_addr),
        .audiocpu_rom_valid(audiocpu_rom_valid), .audiocpu_rom_data(audiocpu_rom_data),
        .adpcma_rom_req(adpcma_rom_req), .adpcma_rom_addr(adpcma_addr),
        .adpcma_rom_valid(adpcma_rom_valid), .adpcma_rom_data(adpcma_rom_data),
        // These four were MISSING until 2026-08-30: the delta-T glue above
        // existed but never reached the SDRAM backend, so adpcmb_rom_valid
        // was undriven, the request stuck high, and the channel decoded
        // constant zeros -- the persistent audio crackle.
        .adpcmb_rom_req(adpcmb_rom_req), .adpcmb_rom_addr(adpcmb_sdram_addr),
        .adpcmb_rom_valid(adpcmb_rom_valid), .adpcmb_rom_data(adpcmb_rom_data)
    );


`ifdef DEBUG_ISSP
    // Sound chain instrumentation. FM has never been heard, and FM does not
    // depend on ADPCM, so the break is upstream. These four counts separate
    // the cases: no Z80 fetches -> sound CPU dead; no YM writes -> Z80 running
    // but not driving the chip; no latch writes -> the 68020 never sends a
    // command; samples always zero -> chip driven but silent.
    issp_probe #(.INSTANCE_ID("A")) u_issp_snd (
        .clk(clk),
        .wr_issued(audiocpu_rom_valid),
        .wr_acked(ym_cs & ym_wr),
        .cpu_rd_acked(latch_write),
        .cpu_rd_nonzero(1'b1),
        .sdram_ready(|snd_left),
        // dl_req repurposed: sticky "has the Z80 ever completed its NMI
        // handler" (io_latch_ack, the 0x0C write clearing latch_pending) --
        // proof the ISR ran to completion, not merely that NMI was
        // asserted. ADPCM tracking was here; secondary to getting the Z80's
        // own sound driver running at all.
        .dl_req(dbg_latch_ack_event),
        .ioctl_download(adpcma_rom_valid),
        .reset(core_reset),
        .cpu_rd_addr({4'd0, adpcma_addr[19:5]}),
        .cpu_rd_data({8'd0, adpcma_data_r})
    );
`endif

endmodule
