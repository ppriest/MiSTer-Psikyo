// Connects rtl/psikyo_core.sv (video+CPU) directly to
// rtl/memory/psikyo_sdram_top.sv (the SDRAM backend) -- both modules were
// built with matching ROM port shapes specifically so this step would be a
// straight port-to-port connection, not new logic (docs/ROADMAP.md's Next
// steps). What's still missing before this reaches Psikyo.sv/emu.sv: the
// sound CPU (audiocpu_rom_* and the sound-latch handshake are exposed here
// but unconnected -- no sound CPU wrapper is wired in yet) and the
// HPS/DIP/CRT_Offset glue that belongs in Psikyo.sv itself, one level up.
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
    parameter bit BOARD_GUNBIRD = 1'b0
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

    // Sound latch handshake -- to a sound CPU wrapper, not instantiated here.
    output logic [7:0]  latch_data,
    output logic         latch_write,

    // audiocpu program fetch -- passed straight through to
    // psikyo_sdram_top.sv's client-shaped port; a future sound CPU wrapper
    // (not yet wired, one level up from here) drives the request side.
    input  logic         audiocpu_rom_req,
    input  logic [17:0] audiocpu_rom_addr,
    output logic         audiocpu_rom_valid,
    output logic [7:0]  audiocpu_rom_data,

    // Video output.
    output logic [8:0]  hcnt,
    output logic [8:0]  vcnt,
    output logic         hblank,
    output logic         vblank,
    output logic         hsync,
    output logic         vsync,
    output logic [14:0] rgb
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

    // Core reset: plain reset OR active download -- see module header.
    logic core_reset;
    assign core_reset = reset | ioctl_download;

    psikyo_core #(.BOARD_GUNBIRD(BOARD_GUNBIRD)) u_core (
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
        .hsync(hsync), .vsync(vsync), .rgb(rgb)
    );

    psikyo_sdram_top u_sdram (
        .clk(clk), .reset(reset), .init(init),
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
