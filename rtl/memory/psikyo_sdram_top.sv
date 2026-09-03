// The complete SDRAM backend: one real SDRAM chip
// (rtl/memory/sdram/sdram.sv), its 3 physical ports wrapped in req/valid
// (rtl/memory/sdram_phy.sv), Port 0 shared by both tilemap layers, Port 1
// dedicated to sprite gfxrom, and Port 2 fanned out to 5 logical clients
// plus the ROM download (rtl/memory/sdram_arbiter6.sv) with narrow clients
// bridged through
// rtl/memory/sdram_narrow_bridge.sv, gfx-ROM-row consumers corrected for
// byte order (rtl/memory/gfxrom_byte_reorder.sv), and HPS ROM download
// bridged in (rtl/memory/sdram_download.sv) -- see
// docs/phase1_sdram_map.md's "Arbiter architecture" table and address map
// for the design this wires up exactly, and "Port 2: built and measured"
// / tb_video_pipeline_sdram.sv / tb_port2_sdram.sv for how each piece was
// already independently verified before being assembled here.
//
// Client-facing ports match rtl/psikyo_core.sv's external ROM port shapes
// directly (l0_gfxrom_*/l1_gfxrom_*/sp_gfxrom_*/sp_lut_*/cpu_rom_*) so this
// module is meant to be wired straight onto that one -- see rtl/Psikyo.sv
// (not yet built) for where the two get connected. audiocpu's port is
// exposed but not yet consumed by anything (the sound CPU wrapper isn't
// wired into psikyo_core.sv yet, docs/ROADMAP.md's Next steps).
//
// Client engines address each region with their OWN local convention
// (tilemap/sprite gfxrom_addr are already byte offsets from tile-row/
// sprite-row arithmetic; spritelut/maincpu addresses are WORD addresses,
// matching each engine's own port comment) -- this module is what adds
// each region's fixed base offset (docs/phase1_sdram_map.md's "Address
// map" table) and does the word->byte conversion where needed, so no
// client engine needs to know its own placement in the flat SDRAM map.
module psikyo_sdram_top (
	input  logic clk,
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

	// HPS ROM download (hps_io's real ioctl_* interface -- see
	// rtl/memory/sdram_download.sv's own header).
	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	// samuraia/samuraiak/sngkace/sngkacea ONLY (not gunbird/btlkroad,
	// despite identical sound hardware) -- MAME's init_sngkace() applies
	// out[7]=in[6], out[6]=in[7] to the whole ymsnd:adpcma ROM region, a
	// real ROM-mastering artifact that can't be expressed in the .mra
	// (byte-level bit transform, not an offset/size). Applied at download
	// time, gated by address range, so every other client of this region
	// (the read side, u_adpcma_bridge above) needs no knowledge of it.
	input  logic         needs_adpcma_swap,

	// Fast ROM load: rom_loader drives the SDRAM write port directly while
	// ldr_active is high, in place of the byte-wise ioctl path. Both cannot
	// run at once -- ldr_active is only asserted once the HPS has finished
	// DMAing the ROM into DDR3, and the core is held in reset throughout.
	input  logic         ldr_active,
	input  logic         ldr_req,
	input  logic [24:0] ldr_addr,
	input  logic [15:0] ldr_data,
	input  logic         ldr_we16,
	output logic         ldr_busy,

	// Tilemap layer 0/1 gfxrom -- dedicated ports (docs/phase1_sdram_map.md
	// Port 0/Port 1), matches rtl/psikyo_core.sv's l0_gfxrom_*/l1_gfxrom_*.
	input  logic         l0_gfxrom_req,
	input  logic [21:0] l0_gfxrom_addr,
	output logic         l0_gfxrom_valid,
	output logic [63:0] l0_gfxrom_data,

	input  logic         l1_gfxrom_req,
	input  logic [21:0] l1_gfxrom_addr,
	output logic         l1_gfxrom_valid,
	output logic [63:0] l1_gfxrom_data,

	// Sprite gfxrom + spritelut -- Port 2, arbiter clients c0/c1.
	input  logic         sp_gfxrom_req,
	input  logic [22:0] sp_gfxrom_addr,
	output logic         sp_gfxrom_valid,
	output logic [63:0] sp_gfxrom_data,

	input  logic         sp_lut_req,
	input  logic [16:0] sp_lut_addr,
	output logic         sp_lut_valid,
	output logic [15:0] sp_lut_data,

	// maincpu program fetch -- Port 2, arbiter client c2.
	input  logic         cpu_rom_req,
	input  logic [18:0] cpu_rom_addr,
	output logic         cpu_rom_valid,
	output logic [15:0] cpu_rom_data,

	// audiocpu program fetch -- Port 2, arbiter client c3. Not yet driven
	// by a real sound CPU wrapper (docs/ROADMAP.md's Next steps).
	input  logic         audiocpu_rom_req,
	input  logic [17:0] audiocpu_rom_addr,   // byte address within the 256KB audiocpu region
	output logic         audiocpu_rom_valid,
	output logic [7:0]  audiocpu_rom_data,

	// YM2610 ADPCM-A samples -- Port 2, arbiter client c4. Byte address
	// within the 4MB sample region: the low 1MB is the ADPCM-A image on
	// the YM2610 boards; on SH403/SH404 this same client serves the OPL4's
	// wave-ROM reads across the whole region (psikyo_top muxes the two --
	// each board type leaves the other requester idle).
	input  logic         adpcma_rom_req,
	input  logic [21:0] adpcma_rom_addr,
	output logic         adpcma_rom_valid,
	output logic [7:0]  adpcma_rom_data,

	// YM2610 ADPCM-B (delta-T) samples -- Port 2, arbiter client c0 (freed
	// by the sprite Port-1 re-partition). 2MB window from ADPCMA_BASE:
	// bit 20 is the caller's ROM select. SH201B (samuraia/sngkace) has no
	// separate delta-T ROM -- MAME's YM2610 serves the deltat channel from
	// the adpcma image, so the caller keeps bit 20 low and the
	// samuraia/sngkace bit 6/7 download swap covers B automatically.
	// KA302C (gunbird/btlkroad, later s1945n) has its own delta-T ROM
	// (u64), which the .mra places at ADPCMA_BASE+0x100000 -- the caller
	// sets bit 20. Its own bridge instance (own granule cache): A and B
	// are independent concurrent streams from jt10.
	input  logic         adpcmb_rom_req,
	input  logic [20:0] adpcmb_rom_addr,
	output logic         adpcmb_rom_valid,
	output logic [7:0]  adpcmb_rom_data
);

	// docs/phase1_sdram_map.md's "Address map" table -- byte offsets into
	// the 32MB SDRAM chip. Every region is sized for the LARGEST set that
	// ships in it (docs/phase2_sh404.md "SDRAM re-layout"): sprites 8MB
	// (s1945), tiles 4MB (tengai), samples 4MB (SH404's OPL4 wave ROMs;
	// the YM2610 boards use the first 2MB as ADPCM-A + delta-T below).
	// The .mra files pad each region to these bases -- they and this table
	// must change together.
	localparam logic [24:0] MAINCPU_BASE   = 25'h0000000;
	localparam logic [24:0] AUDIOCPU_BASE  = 25'h0200000;
	localparam logic [24:0] SPRITES_BASE   = 25'h0240000;
	localparam logic [24:0] TILES_BASE      = 25'h0A40000;
	localparam logic [24:0] SPRITELUT_BASE = 25'h1240000;
	// Sample-ROM region. YM2610 boards: ADPCM-A image at +0 (1MB max);
	// boards with a SEPARATE delta-T ROM (gunbird/btlkroad/s1945n's u64)
	// place it at +0x100000, while SH201B (samuraia/sngkace) has no such
	// ROM and delta-T shares the ADPCM-A image at +0 -- the caller selects
	// via adpcmb_rom_addr[20] (see that port's comment).
	localparam logic [24:0] ADPCMA_BASE     = 25'h0E40000;

	// ---- raw SDRAM chip, 3 physical ports ----
	logic [24:1] p0_addr, p1_addr, p2_addr;
	logic         p0_wrl, p0_wrh, p1_wrl, p1_wrh, p2_wrl, p2_wrh;
	logic [15:0] p0_din, p1_din, p2_din;
	logic [63:0] p0_dout, p1_dout, p2_dout;
	logic         p0_req, p1_req, p2_req;
	logic         p0_ack, p1_ack, p2_ack;

	sdram mem_ctrl (
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.init(init), .clk(clk),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(p1_wrl), .wrh1(p1_wrh), .din1(p1_din), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
		.addr2(p2_addr), .wrl2(p2_wrl), .wrh2(p2_wrh), .din2(p2_din), .dout2(p2_dout), .req2(p2_req), .ack2(p2_ack)
	);

	// ---- Port 0: BOTH tilemap layers, via sdram_arbiter2 ----
	// The tilemap layers have enormous slack (21 fetches x ~30 clk worst
	// per 5472-clk line, ~12% duty even stalled -- PREFETCH_DEPTH=32
	// absorbs the arbitration jitter, see tilemap_line_engine.sv), so they
	// share Port 0 through one arbiter2, keeping Port 1 as the sprite
	// engine's DEDICATED port -- the sprite pass is the bandwidth-critical
	// consumer (it can approach a whole frame time under load).
	logic         p0arb_req, p0arb_busy, p0arb_valid;
	logic [24:0] p0arb_addr;
	logic [63:0] p0arb_rdata;

	sdram_phy phy0 (
		.clk(clk), .reset(reset),
		.port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh),
		.port_din(p0_din), .port_dout(p0_dout), .port_req(p0_req), .port_ack(p0_ack),
		.req(p0arb_req), .we(1'b0), .we16(1'b0), .addr(p0arb_addr), .wdata(16'd0),
		.busy(p0arb_busy), .valid(p0arb_valid), .rdata(p0arb_rdata)
	);

	logic [63:0] l0_rdata_raw, l1_rdata_raw;
	logic         l0_valid_raw, l1_valid_raw;

	sdram_arbiter2 u_tilemap_arb (
		.clk(clk), .reset(reset),
		.phy_req(p0arb_req), .phy_addr(p0arb_addr),
		.phy_busy(p0arb_busy), .phy_valid(p0arb_valid), .phy_rdata(p0arb_rdata),
		.c0_req(l0_gfxrom_req), .c0_addr(TILES_BASE + {3'd0, l0_gfxrom_addr}),
		.c0_valid(l0_valid_raw), .c0_data(l0_rdata_raw),
		.c1_req(l1_gfxrom_req), .c1_addr(TILES_BASE + {3'd0, l1_gfxrom_addr}),
		.c1_valid(l1_valid_raw), .c1_data(l1_rdata_raw)
	);

	assign l0_gfxrom_valid = l0_valid_raw;
	assign l1_gfxrom_valid = l1_valid_raw;
	gfxrom_byte_reorder u_l0_reorder (.sdram_granule(l0_rdata_raw), .gfxrom_data(l0_gfxrom_data));
	gfxrom_byte_reorder u_l1_reorder (.sdram_granule(l1_rdata_raw), .gfxrom_data(l1_gfxrom_data));

	// ---- Port 1: sprite gfxrom, DEDICATED (see the Port 0 comment) ----
	//
	// The pulse shim below is REQUIRED, not decorative. sp_gfxrom_req
	// (sprite_render_engine.sv) is a held-until-valid signal: its registered
	// clear is scheduled the same cycle it samples gfxrom_valid, so req is
	// still high one cycle after valid -- the convention for every
	// gfxrom_req/lut_req consumer here (ddram_arbiter.sv's header). But
	// sdram_phy's contract is an explicit PULSE, and its `valid` lands on
	// the same cycle it returns to S_IDLE, where it immediately re-samples
	// `req`. The arbiters (sdram_arbiter2/6) mask this by asserting c_valid
	// one cycle before their own state returns to idle, giving the
	// consumer's req-clear a head start; a single client wired straight
	// into sdram_phy has no such grace and latches a spurious second
	// transaction on the cycle valid pulses (seen on hardware as corrupted
	// sprites and a worse sp_render_max). The shim reproduces the arbiters'
	// "valid one cycle before idle" timing, keeping the invariant that
	// every sdram_phy port has something pulse-shaping its req.
	logic         sp_valid_raw;
	logic [63:0] sp_rdata_raw;
	logic         sp_phy_req, sp_phy_busy;

	typedef enum logic [1:0] {SP_IDLE, SP_ISSUE, SP_WAIT} spstate_t;
	spstate_t sp_astate;

	assign sp_phy_req = (sp_astate == SP_ISSUE) && !sp_phy_busy;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			sp_astate <= SP_IDLE;
		end else begin
			case (sp_astate)
				SP_IDLE:  if (sp_gfxrom_req) sp_astate <= SP_ISSUE;
				SP_ISSUE: if (!sp_phy_busy)  sp_astate <= SP_WAIT;
				SP_WAIT:  if (sp_valid_raw)  sp_astate <= SP_IDLE;
				default: ;
			endcase
		end
	end

	sdram_phy phy1 (
		.clk(clk), .reset(reset),
		.port_addr(p1_addr), .port_wrl(p1_wrl), .port_wrh(p1_wrh),
		.port_din(p1_din), .port_dout(p1_dout), .port_req(p1_req), .port_ack(p1_ack),
		.req(sp_phy_req), .we(1'b0), .we16(1'b0), .addr(SPRITES_BASE + {2'd0, sp_gfxrom_addr}), .wdata(16'd0),
		.busy(sp_phy_busy), .valid(sp_valid_raw), .rdata(sp_rdata_raw)
	);

	assign sp_gfxrom_valid = sp_valid_raw;
	gfxrom_byte_reorder u_sp_reorder2 (.sdram_granule(sp_rdata_raw), .gfxrom_data(sp_gfxrom_data));

	// ---- Port 2: 5-way arbiter (sprite gfxrom, spritelut, maincpu, audiocpu, download) ----
	logic         p2phy_req, p2phy_we, p2phy_busy, p2phy_valid;
	logic [24:0] p2phy_addr;
	logic [15:0] p2phy_wdata;
	logic        p2phy_we16;
	logic [63:0] p2phy_rdata;

	sdram_phy phy2 (
		.clk(clk), .reset(reset),
		.port_addr(p2_addr), .port_wrl(p2_wrl), .port_wrh(p2_wrh),
		.port_din(p2_din), .port_dout(p2_dout), .port_req(p2_req), .port_ack(p2_ack),
		.req(p2phy_req), .we(p2phy_we), .we16(p2phy_we16), .addr(p2phy_addr), .wdata(p2phy_wdata),
		.busy(p2phy_busy), .valid(p2phy_valid), .rdata(p2phy_rdata)
	);

	logic         c0_req, c1_req, c2_req, c3_req, c4_req;
	logic [24:0] c0_addr, c1_addr, c2_addr, c3_addr, c4_addr;
	logic         c0_valid, c1_valid, c2_valid, c3_valid, c4_valid;
	logic [63:0] c0_data, c1_data, c2_data, c3_data, c4_data;
	logic         dl_req, dl_busy;
	logic [24:0] dl_addr;
	logic [15:0] dl_data;
	logic        dl_we16;
	logic         arb_dl_req, arb_dl_we16, arb_dl_busy;
	logic [24:0] arb_dl_addr;
	logic [15:0] arb_dl_data;

	sdram_arbiter6 u_arbiter (
		.clk(clk), .reset(reset),
		.phy_req(p2phy_req), .phy_we(p2phy_we), .phy_we16(p2phy_we16), .phy_addr(p2phy_addr), .phy_wdata(p2phy_wdata),
		.phy_busy(p2phy_busy), .phy_valid(p2phy_valid), .phy_rdata(p2phy_rdata),
		.c0_req(c0_req), .c0_addr(c0_addr), .c0_valid(c0_valid), .c0_data(c0_data),
		.c1_req(c1_req), .c1_addr(c1_addr), .c1_valid(c1_valid), .c1_data(c1_data),
		.c2_req(c2_req), .c2_addr(c2_addr), .c2_valid(c2_valid), .c2_data(c2_data),
		.c3_req(c3_req), .c3_addr(c3_addr), .c3_valid(c3_valid), .c3_data(c3_data),
		.c4_req(c4_req), .c4_addr(c4_addr), .c4_valid(c4_valid), .c4_data(c4_data),
		.dl_req(arb_dl_req), .dl_addr(arb_dl_addr), .dl_data(arb_dl_data),
		.dl_we16(arb_dl_we16), .dl_busy(arb_dl_busy)
	);

	// Bulk loader wins the write port whenever it is running; otherwise the
	// ioctl download path keeps it, so an .mra without the DDR3 address
	// attribute still loads exactly as before.
	assign arb_dl_req   = ldr_active ? ldr_req   : dl_req;
	assign arb_dl_addr  = ldr_active ? ldr_addr  : dl_addr;
	assign arb_dl_data  = ldr_active ? ldr_data  : dl_data;
	assign arb_dl_we16  = ldr_active ? ldr_we16  : dl_we16;
	assign dl_busy      = ldr_active ? 1'b0      : arb_dl_busy;
	assign ldr_busy     = ldr_active ? arb_dl_busy : 1'b0;

	// c0: YM2610 ADPCM-B (delta-T) -- byte client into the shared ADPCM
	// region, see the port comment above. (This slot was freed when sprite
	// gfxrom moved to its dedicated Port 1.)
	sdram_narrow_bridge #(.WORD_BYTES(1)) u_adpcmb_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(adpcmb_rom_req), .addr(ADPCMA_BASE + {4'd0, adpcmb_rom_addr}),
		.valid(adpcmb_rom_valid), .data(adpcmb_rom_data),
		.g_req(c0_req), .g_addr(c0_addr), .g_valid(c0_valid), .g_data(c0_data)
	);

	// c1: spritelut -- 16-bit word client, sp_lut_addr is a WORD address.
	sdram_narrow_bridge #(.WORD_BYTES(2)) u_lut_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(sp_lut_req), .addr(SPRITELUT_BASE + {7'd0, sp_lut_addr, 1'b0}),
		.valid(sp_lut_valid), .data(sp_lut_data),
		.g_req(c1_req), .g_addr(c1_addr), .g_valid(c1_valid), .g_data(c1_data)
	);

	// c2: maincpu program fetch -- 16-bit word client, cpu_rom_addr is a WORD address.
	//
	// Byte swap at the maincpu-specific seam: sdram_narrow_bridge.sv packs
	// 16-bit words little-endian (its own header: "EVEN byte address...
	// LOW byte, ODD... HIGH byte") -- correct for spritelut
	// (`ROM_REGION16_LE`, docs/phase1_video_engine.md's "LUT ROM format"),
	// but the 68020 program ROM is plain `ROM_REGION` (big-endian, see
	// sim/maincpu_tb/gen_rom_hex.py's own big-endian packing). The swap
	// lives HERE rather than in sdram_narrow_bridge.sv, which is correct
	// as-is for spritelut's genuinely little-endian content and for
	// audiocpu's WORD_BYTES=1 single-byte fetches (no endianness question).
	logic [15:0] cpu_rom_data_le;
	assign cpu_rom_data = {cpu_rom_data_le[7:0], cpu_rom_data_le[15:8]};

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(cpu_rom_req), .addr(MAINCPU_BASE + {5'd0, cpu_rom_addr, 1'b0}),
		.valid(cpu_rom_valid), .data(cpu_rom_data_le),
		.g_req(c2_req), .g_addr(c2_addr), .g_valid(c2_valid), .g_data(c2_data)
	);

	// c3: audiocpu program fetch -- 8-bit byte client, address already byte-oriented.
	sdram_narrow_bridge #(.WORD_BYTES(1)) u_audiocpu_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(audiocpu_rom_req), .addr(AUDIOCPU_BASE + {7'd0, audiocpu_rom_addr}),
		.valid(audiocpu_rom_valid), .data(audiocpu_rom_data),
		.g_req(c3_req), .g_addr(c3_addr), .g_valid(c3_valid), .g_data(c3_data)
	);

	// HPS ROM download -- ioctl_addr is already an absolute byte address
	// across the whole flat map (docs/phase1_sdram_map.md), no per-region
	// base to add here.
	// c4: YM2610 ADPCM-A samples (and, on SH403/SH404, the OPL4 wave reads
	// muxed onto the same client by psikyo_top). NOT sdram_narrow_bridge: this
	// client feeds a FIXED-LATENCY consumer that cannot be made to wait, and
	// the bridge's single granule entry is thrashed by six interleaved ADPCM
	// channels so every fetch missed. See adpcma_sample_cache.sv's header for
	// the deadline arithmetic and the 241-misses-in-four-minutes measurement
	// that motivated it.
	adpcma_sample_cache #(.ENTRIES(16)) u_adpcma_cache (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(adpcma_rom_req), .addr(ADPCMA_BASE + {3'd0, adpcma_rom_addr}),
		.valid(adpcma_rom_valid), .data(adpcma_rom_data),
		.g_req(c4_req), .g_addr(c4_addr), .g_valid(c4_valid), .g_data(c4_data)
	);

	// samuraia/sngkace ADPCM-A bit 6/7 swap (see needs_adpcma_swap's port
	// comment) -- gated purely on the incoming byte's address falling
	// inside the 1MB ADPCM-A window, so it's a no-op for every other
	// region regardless of the select signal.
	wire in_adpcma_window = (ioctl_addr >= ADPCMA_BASE) &&
							 (ioctl_addr <  ADPCMA_BASE + 25'h100000);
	wire [7:0] ioctl_dout_swapped = (needs_adpcma_swap && in_adpcma_window)
		? {ioctl_dout[6], ioctl_dout[7], ioctl_dout[5:0]}
		: ioctl_dout;

	sdram_download u_download (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout_swapped),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
	);

endmodule
