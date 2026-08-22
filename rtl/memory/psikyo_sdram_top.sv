// The complete Phase 1 SDRAM backend: one real SDRAM chip
// (rtl/memory/sdram/sdram.sv), its 3 physical ports wrapped in req/valid
// (rtl/memory/sdram_phy.sv), Port 2 fanned out to 5 logical consumers
// (rtl/memory/sdram_arbiter5.sv) with narrow clients bridged through
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
    output logic [7:0]  audiocpu_rom_data
);

    // docs/phase1_sdram_map.md's "Address map" table -- byte offsets into
    // the 32MB SDRAM chip.
    localparam logic [24:0] MAINCPU_BASE   = 25'h0000000;
    localparam logic [24:0] AUDIOCPU_BASE  = 25'h0200000;
    localparam logic [24:0] SPRITES_BASE   = 25'h0240000;
    localparam logic [24:0] TILES_BASE      = 25'h0A40000;
    localparam logic [24:0] SPRITELUT_BASE = 25'h0DC0000;

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

    // ---- Port 0: tilemap layer 0 gfxrom, dedicated ----
    logic         l0_req, l0_we, l0_busy, l0_valid_raw;
    logic [24:0] l0_addr;
    logic [63:0] l0_rdata_raw;

    sdram_phy phy0 (
        .clk(clk), .reset(reset),
        .port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh),
        .port_din(p0_din), .port_dout(p0_dout), .port_req(p0_req), .port_ack(p0_ack),
        .req(l0_req), .we(l0_we), .addr(l0_addr), .wdata(8'd0),
        .busy(l0_busy), .valid(l0_valid_raw), .rdata(l0_rdata_raw)
    );

    assign l0_req  = l0_gfxrom_req;
    assign l0_we    = 1'b0;
    assign l0_addr = TILES_BASE + {3'd0, l0_gfxrom_addr};
    assign l0_gfxrom_valid = l0_valid_raw;

    gfxrom_byte_reorder u_l0_reorder (.sdram_granule(l0_rdata_raw), .gfxrom_data(l0_gfxrom_data));

    // ---- Port 1: tilemap layer 1 gfxrom, dedicated ----
    logic         l1_req, l1_we, l1_busy, l1_valid_raw;
    logic [24:0] l1_addr;
    logic [63:0] l1_rdata_raw;

    sdram_phy phy1 (
        .clk(clk), .reset(reset),
        .port_addr(p1_addr), .port_wrl(p1_wrl), .port_wrh(p1_wrh),
        .port_din(p1_din), .port_dout(p1_dout), .port_req(p1_req), .port_ack(p1_ack),
        .req(l1_req), .we(l1_we), .addr(l1_addr), .wdata(8'd0),
        .busy(l1_busy), .valid(l1_valid_raw), .rdata(l1_rdata_raw)
    );

    assign l1_req  = l1_gfxrom_req;
    assign l1_we    = 1'b0;
    assign l1_addr = TILES_BASE + {3'd0, l1_gfxrom_addr};
    assign l1_gfxrom_valid = l1_valid_raw;

    gfxrom_byte_reorder u_l1_reorder (.sdram_granule(l1_rdata_raw), .gfxrom_data(l1_gfxrom_data));

    // ---- Port 2: 5-way arbiter (sprite gfxrom, spritelut, maincpu, audiocpu, download) ----
    logic         p2phy_req, p2phy_we, p2phy_busy, p2phy_valid;
    logic [24:0] p2phy_addr;
    logic [7:0]  p2phy_wdata;
    logic [63:0] p2phy_rdata;

    sdram_phy phy2 (
        .clk(clk), .reset(reset),
        .port_addr(p2_addr), .port_wrl(p2_wrl), .port_wrh(p2_wrh),
        .port_din(p2_din), .port_dout(p2_dout), .port_req(p2_req), .port_ack(p2_ack),
        .req(p2phy_req), .we(p2phy_we), .addr(p2phy_addr), .wdata(p2phy_wdata),
        .busy(p2phy_busy), .valid(p2phy_valid), .rdata(p2phy_rdata)
    );

    logic         c0_req, c1_req, c2_req, c3_req;
    logic [24:0] c0_addr, c1_addr, c2_addr, c3_addr;
    logic         c0_valid, c1_valid, c2_valid, c3_valid;
    logic [63:0] c0_data, c1_data, c2_data, c3_data;
    logic         dl_req, dl_busy;
    logic [24:0] dl_addr;
    logic [7:0]  dl_data;

    sdram_arbiter5 u_arbiter (
        .clk(clk), .reset(reset),
        .phy_req(p2phy_req), .phy_we(p2phy_we), .phy_addr(p2phy_addr), .phy_wdata(p2phy_wdata),
        .phy_busy(p2phy_busy), .phy_valid(p2phy_valid), .phy_rdata(p2phy_rdata),
        .c0_req(c0_req), .c0_addr(c0_addr), .c0_valid(c0_valid), .c0_data(c0_data),
        .c1_req(c1_req), .c1_addr(c1_addr), .c1_valid(c1_valid), .c1_data(c1_data),
        .c2_req(c2_req), .c2_addr(c2_addr), .c2_valid(c2_valid), .c2_data(c2_data),
        .c3_req(c3_req), .c3_addr(c3_addr), .c3_valid(c3_valid), .c3_data(c3_data),
        .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy)
    );

    // c0: sprite gfxrom -- already granule-shaped, no narrow bridge, just byte-reorder.
    assign c0_req  = sp_gfxrom_req;
    assign c0_addr = SPRITES_BASE + {2'd0, sp_gfxrom_addr};
    assign sp_gfxrom_valid = c0_valid;
    gfxrom_byte_reorder u_sp_reorder (.sdram_granule(c0_data), .gfxrom_data(sp_gfxrom_data));

    // c1: spritelut -- 16-bit word client, sp_lut_addr is a WORD address.
    sdram_narrow_bridge #(.WORD_BYTES(2)) u_lut_bridge (
        .clk(clk), .reset(reset),
        .req(sp_lut_req), .addr(SPRITELUT_BASE + {7'd0, sp_lut_addr, 1'b0}),
        .valid(sp_lut_valid), .data(sp_lut_data),
        .g_req(c1_req), .g_addr(c1_addr), .g_valid(c1_valid), .g_data(c1_data)
    );

    // c2: maincpu program fetch -- 16-bit word client, cpu_rom_addr is a WORD address.
    sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
        .clk(clk), .reset(reset),
        .req(cpu_rom_req), .addr(MAINCPU_BASE + {5'd0, cpu_rom_addr, 1'b0}),
        .valid(cpu_rom_valid), .data(cpu_rom_data),
        .g_req(c2_req), .g_addr(c2_addr), .g_valid(c2_valid), .g_data(c2_data)
    );

    // c3: audiocpu program fetch -- 8-bit byte client, address already byte-oriented.
    sdram_narrow_bridge #(.WORD_BYTES(1)) u_audiocpu_bridge (
        .clk(clk), .reset(reset),
        .req(audiocpu_rom_req), .addr(AUDIOCPU_BASE + {7'd0, audiocpu_rom_addr}),
        .valid(audiocpu_rom_valid), .data(audiocpu_rom_data),
        .g_req(c3_req), .g_addr(c3_addr), .g_valid(c3_valid), .g_data(c3_data)
    );

    // HPS ROM download -- ioctl_addr is already an absolute byte address
    // across the whole flat map (docs/phase1_sdram_map.md), no per-region
    // base to add here.
    sdram_download u_download (
        .clk(clk), .reset(reset),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),
        .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy)
    );

endmodule
