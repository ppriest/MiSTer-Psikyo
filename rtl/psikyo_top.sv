// Connects rtl/psikyo_core.sv (video+CPU) directly to
// rtl/memory/psikyo_sdram_top.sv (the SDRAM backend) -- both modules were
// built with matching ROM port shapes specifically so this step would be a
// straight port-to-port connection, not new logic (docs/ROADMAP.md's Next
// steps) -- plus the board-appropriate sound CPU wrapper
// (rtl/sound/sound_cpu_sngkace.sv or sound_cpu_gunbird.sv, selected by
// BOARD_GUNBIRD, same parameter psikyo_core.sv already uses), whose
// req/valid ROM port and sound-latch handshake were built to match
// psikyo_core.sv's own latch_data/latch_write output and
// psikyo_sdram_top.sv's audiocpu_rom_* port directly. What's still missing
// before this reaches Psikyo.sv/emu.sv: jt10 (YM2610) itself -- the sound
// CPU's ym_* chip-select bus is exposed at this module's boundary,
// unconnected, since jt10 hasn't had its own audio-domain verification
// pass yet (docs/ROADMAP.md's Next steps) -- and the HPS/DIP/CRT_Offset
// glue that belongs in Psikyo.sv itself, one level up.
//
// audiocpu_rom_addr's width: sound_cpu_sngkace.sv/sound_cpu_gunbird.sv
// both expose a 17-bit rom_addr (already the flattened {bank,addr[14:0]}
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

    // Mirrors MAME's psikyo_state::z80_nmi_r() -- see
    // rtl/sound/sound_cpu_sngkace.sv's own comment for the full derivation.
    // Not looped back into p1p2_in/coin_in internally: which bit position
    // it occupies is board-specific (sngkace's own separate COIN port vs.
    // gunbird's P1P2 port bit 7), so the caller folds this into whichever
    // input word it assembles, same as it already owns all other
    // board-specific bit layout decisions.
    output logic         nmi_pending,

    // Sound chip (YM2610) bus -- to jt10, not instantiated here yet.
    output logic         ym_cs,
    output logic [1:0]  ym_addr,
    output logic         ym_rd,
    output logic         ym_wr,
    output logic [7:0]  ym_dout,
    input  logic [7:0]  ym_din,

    // Video output.
    output logic [8:0]  hcnt,
    output logic [8:0]  vcnt,
    output logic         hblank,
    output logic         vblank,
    output logic         hsync,
    output logic         vsync,
    output logic [14:0] rgb,

    // ---- debug tracer, live-controlled from the OSD ----
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
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in),
        .latch_data(latch_data), .latch_write(latch_write),
        .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync), .rgb(rgb),
        .dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
        .dbg_pixel(dbg_pixel)
    );

    // Board-appropriate sound CPU -- sngkace/samuraia/btlkroad/gunbird all
    // share this same T80+req/valid-ROM wrapper shape, differing only in
    // which of the two wrappers matches their memory map (docs/ROADMAP.md's
    // sound-subsystem notes). Held quiescent by core_reset for the same
    // reason maincpu.sv is -- nothing useful to do with a partially-loaded
    // ROM, and it shares the audiocpu SDRAM region with the download path.
    generate
        if (BOARD_GUNBIRD) begin : g_sound_gunbird
            sound_cpu_gunbird u_sound (
                .clk(clk), .reset(core_reset),
                .rom_req(audiocpu_rom_req_raw), .rom_addr(audiocpu_rom_addr_raw),
                .rom_valid(audiocpu_rom_valid), .rom_data(audiocpu_rom_data),
                .latch_data(latch_data), .latch_write(latch_write),
                .nmi_pending(nmi_pending),
                .ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
                .ym_dout(ym_dout), .ym_din(ym_din)
            );
        end else begin : g_sound_sngkace
            sound_cpu_sngkace u_sound (
                .clk(clk), .reset(core_reset),
                .rom_req(audiocpu_rom_req_raw), .rom_addr(audiocpu_rom_addr_raw),
                .rom_valid(audiocpu_rom_valid), .rom_data(audiocpu_rom_data),
                .latch_data(latch_data), .latch_write(latch_write),
                .nmi_pending(nmi_pending),
                .ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
                .ym_dout(ym_dout), .ym_din(ym_din)
            );
        end
    endgenerate

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
        .ioctl_wait(ioctl_wait),
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
        .audiocpu_rom_valid(audiocpu_rom_valid), .audiocpu_rom_data(audiocpu_rom_data)
    );

endmodule
