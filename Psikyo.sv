//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
// Top-level HPS/DIP/CRT_Offset glue for the Phase 1 SH201B/KA302C board
// (Samurai Aces/Sengoku Ace, Gun Bird, Battle K-Road -- docs/ROADMAP.md's
// "Hardware reality" table), wiring rtl/psikyo_top.sv (video+CPU+SDRAM+
// sound CPU, already verified end to end in simulation, see
// docs/ROADMAP.md's "Progress") into MiSTer-devel/Template_MiSTer's
// framework. BOARD_GUNBIRD is fixed to sngkace's layout here (this
// project's own Phase 1 entry point, per docs/ROADMAP.md); a gunbird/
// btlkroad build needs its own top-level parameter value, same as
// rtl/psikyo_top.sv itself already requires per board.
//
// Input port bit layout (P1P2 32-bit port, separate COIN port) confirmed
// directly from psikyo.cpp's own sngkace_input_r()/INPUT_PORTS_START
// block, not assumed -- see the p1p2_in/coin_in assignments below for the
// exact bit positions. Standard MiSTer joystick_0/1 bit convention
// (0=Right,1=Left,2=Down,3=Up,4=Button1,5=Button2,6=Button3,10=Start,
// 11=Coin) confirmed against a real, already-built, similar-genre
// MiSTer-devel core (rmonic79/Arcade-Raiden_MiSTer, already named in this
// project's own "Component reuse map"), not assumed either.
//
// NOT yet done here (tracked, not silently skipped): jt10/YM2610 (silent
// for now -- rtl/psikyo_top.sv's ym_* bus is exposed but unconnected,
// matching docs/ROADMAP.md's own "Next steps" ordering: jt10's
// audio-domain verification pass hasn't happened yet), per-game DIP
// switch *labels* (the generic "DIP;" CONF_STR entry pulls them from
// whichever .mra is loaded, matching every MiSTer arcade core's standard
// convention -- no per-game RTL needed), and real hardware SDRAM_CLK
// phase-shift tuning (rtl/pll/pll_0002.v's -3000ps is a starting point
// copied from another core's ballpark, not independently verified against
// this board).
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// No sound yet -- jt10 isn't wired in (see module header).
assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Psikyo;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"DIP;",
	"-;",
	"P1,Debug;",
	"P1-;",
	"P1O[56],Trace overlay,Off,On;",
	"P1O[58:57],Trace source,CPU addr+data,CPU fetch addr,SpriteRAM wr,Palette wr;",
	"P1O[62:59],Trace window,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P1O[63],Re-arm capture,A,B;",
	"P1-;",
	"P1O[40],Sprites,On,Off;",
	"P1O[41],Tilemap 0,On,Off;",
	"P1O[42],Tilemap 1,On,Off;",
	"-;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"R[0],Reset;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;

wire         ioctl_download;
wire [15:0] ioctl_index;
wire         ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire         ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({status[5]}),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 85.909091 MHz = 14.31818 MHz (this hardware's real pixel/screen XTAL)
// x 6 -- see rtl/pll/pll_0002.v's own header for the full division-ratio
// and SDRAM-timing-margin reasoning. outclk_1 is the same frequency,
// phase-shifted, driving the real SDRAM_CLK pin directly (NOT through
// rtl/psikyo_top.sv's own SDRAM_CLK output, which is left unconnected --
// that output is simulation-only, tracking rtl/memory/sdram/sdram.sv's
// own `assign SDRAM_CLK = clk;` placeholder, which that file's own header
// explicitly documents as deferring real phase generation to here).
wire clk_sys, clk_sdram_shifted, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// ce_pix: exact 1-in-12 divide of clk_sys down to 7.159091 MHz, matching
// psikyo_v.cpp's real 14.31818MHz/2 screen clock exactly (see pll_0002.v's
// header for why 85.909091/12 lands on this exactly, not approximately).
reg [3:0] ce_pix_cnt = 0;
wire       ce_pix = (ce_pix_cnt == 0);
always @(posedge clk_sys) begin
	ce_pix_cnt <= (ce_pix_cnt == 11) ? 4'd0 : ce_pix_cnt + 4'd1;
end

// Sound-CPU NMI status, mirrored into the input ports on both board
// variants (bit 23 of COIN on sngkace, bit 7 of P1_P2 on gunbird).
wire        nmi_pending;

// ---- board variant, selected at RUNTIME by the .mra ----
// One Arcade-Psikyo.rbf has to serve every game in the family, so the board
// difference cannot be a compile-time parameter (it was BOARD_GUNBIRD, fixed
// to 0, which meant only the sngkace-family games could ever work). MiSTer's
// standard mechanism is a second ROM entry in the .mra:
//
//     <rom index="1"><part>01</part></rom>
//
// which arrives through the same ioctl download path with ioctl_index == 1.
// Bit 0 selects gunbird/btlkroad (KA302C input + tile-banking layout) over
// sngkace/samuraia. Latched, never reset by `reset`, because MiSTer holds the
// core in reset for the whole download -- the same trap that silently
// discarded every SDRAM write earlier in this project.
reg [7:0] mod_board = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd1) mod_board <= ioctl_dout;
end
wire board_gunbird = mod_board[0];

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   INPUTS   ////////////////////////////////

// Confirmed against psikyo.cpp's sngkace_input_r()/INPUT_PORTS_START
// (docs/ROADMAP.md's own "Progress" cites the exact fetch), not assumed:
// P1P2 is a 32-bit port with P2 in bits 23:16 and P1 in bits 31:24 (each
// laid out UP,DOWN,RIGHT,LEFT,B1,B2,B3,START from the top bit down), all
// IP_ACTIVE_LOW (0 = pressed) -- hence the `~` on every joystick bit
// below, since hps_io's joystick_N convention is active-HIGH (1 = pressed,
// confirmed against Arcade-Raiden_MiSTer's own joystick_0/1 usage, see
// module header). Bits 15:0 are unused by sngkace's P1P2 port (this
// board's coin/service/z80-nmi bits live in the separate COIN port
// instead, unlike gunbird/btlkroad which fold them into THIS port's low
// bits -- a real, confirmed board difference, not a simplification).
// P1_P2 high half is identical on both boards. The LOW half differs: sngkace
// leaves it unused and puts coin/service/z80-nmi in the separate COIN port at
// $C00008, while gunbird/btlkroad have no COIN port and fold those same bits
// into this port's low byte instead (psikyo.cpp INPUT_PORTS):
//     bit0 COIN1, bit1 COIN2, bit4 SERVICE1, bit5 SERVICE(no toggle),
//     bit6 TILT   -- all IP_ACTIVE_LOW -- and bit7 z80_nmi_r, ACTIVE HIGH.
wire [15:0] p1p2_low = board_gunbird
	? {8'hFF,                                 // bits 15:8 unused
	   nmi_pending,                            // bit 7  z80_nmi_r, active HIGH
	   1'b1,                                   // bit 6  TILT
	   1'b1,                                   // bit 5  SERVICE (no toggle)
	   1'b1,                                   // bit 4  SERVICE1
	   2'b11,                                  // bits 3:2 unused
	   ~joystick_1[11], ~joystick_0[11]}      // bit 1 COIN2, bit 0 COIN1
	: 16'hFFFF;

wire [31:0] p1p2_in = {
	~joystick_0[3], ~joystick_0[2], ~joystick_0[0], ~joystick_0[1],  // P1 UP,DOWN,RIGHT,LEFT
	~joystick_0[4], ~joystick_0[5], ~joystick_0[6], ~joystick_0[10], // P1 B1,B2,B3,START
	~joystick_1[3], ~joystick_1[2], ~joystick_1[0], ~joystick_1[1],  // P2 UP,DOWN,RIGHT,LEFT
	~joystick_1[4], ~joystick_1[5], ~joystick_1[6], ~joystick_1[10], // P2 B1,B2,B3,START
	p1p2_low
};

// (coin_in is declared further down, after the video timing wires it uses)

// DIP switches -> the 32-bit value the CPU reads at $C00004.
//
// MAME's psikyo DSW port (psikyo.cpp, PORT_START("DSW") /* c00004 -> c00007 */)
// puts every DIP in the UPPER half of that long and leaves the lower half
// unused:
//     PORT_BIT( 0x0000ffff, IP_ACTIVE_LOW, IPT_UNUSED )
//     0x00010000 Flip Screen      0x00020000 Demo Sounds
//     0x000c0000 Difficulty       0x00300000 Lives
//     0x00400000 Bonus Life       0x00800000 PORT_SERVICE_DIPLOC "SW2:8"
//     0x01000000 Coin Slot        0x0e000000 Coin A
//     0x70000000 Coin B           0x80000000 2C Start, 1C Continue
//
// This used to be `status[47:16]`, which mapped .mra bit 16 onto dsw_in[0] --
// EVERY DIP LANDED 16 BITS LOW, in the half MAME defines as unused. The OSD
// menu items therefore did nothing, and the bit the game actually reads as
// Service Mode (dsw_in[23]) was driven by status[39], a bit no menu entry
// touched: with a default-ish .CFG that bit is 0 and PORT_SERVICE is
// ACTIVE_LOW, so the board came up stuck in Service Mode.
//
// The .mra's <dip bits="..."> entries already use MAME's own bit numbers
// (16..31), so aligning them is just a matter of feeding status[31:16] into
// the upper half.
//
// The LOW BYTE is not spare -- it is the region/country jumper. samuraia's
// ports carry PORT_CONFNAME( 0x000000ff, 0x000000ff, Region ) with
// ff=World, ef=USA & Canada, df=Korea, bf=Hong Kong, 7f=Taiwan (sngkace
// overrides that same byte to IPT_UNKNOWN, which is why it looks unused if
// you only read the sngkace block). It comes from the .mra's third
// <switches> byte, status[39:32]. Tying it high would silently lock every
// board to World.
//
// Byte 1 (dsw_in[15:8]) genuinely is unused and reads back as 1s, matching
// MAME's IP_ACTIVE_LOW default for undefined bits.
wire [31:0] dsw_in = {status[31:16], 8'hFF, status[39:32]};

// ---- debug tracer controls (rtl/debug/debug_tracer.sv) ----
// Live from the OSD, so the capture window can be walked across a long boot
// WITHOUT a rebuild -- that is the whole point of the module. status[55] is a
// plain level whose CHANGE re-arms, so toggling it between A and B retriggers
// capture without resetting the core and disturbing CPU state.
// Bits placed in status[63:56] -- CFG byte 7 -- per docs/mister_framework_notes.md.
// Two constraints, both learned the hard way:
//   * The official docs state the classic O/o option syntax addresses bits
//     0-63 ONLY (O = upper 32, o = lower 32, i.e. +32). Bits placed at 64-71
//     were outside that window and the source select never responded.
//   * This .mra declares FIVE <switches> bytes, and MRA switches consume
//     8*N bits from status[16], so the DIP mechanism owns status[55:16] --
//     even though the core only reads dsw_in = status[47:16]. Bits at 48-55
//     were contested by it.
// status[63:56] is above the DIP range and inside the documented window, and
// still lands in a single CFG byte so all four controls are one byte write to
// /media/fat/config/<core>.CFG:
//   bit0 overlay, bits2:1 source, bits6:3 window, bit7 re-arm
wire        dbg_overlay = status[56];

// Force-disable rendering per pipeline, for isolating what is actually drawing
// what. status[55:40] is free: the .mra's three <switches> bytes occupy
// status[39:16] and the tracer controls sit at status[63:56].
//   [0] sprites  [1] tilemap layer 0  [2] tilemap layer 1
wire [2:0] dbg_render_dis = status[42:40];
wire [1:0] dbg_src     = status[58:57];
wire [3:0] dbg_window  = status[62:59];
wire        dbg_rearm   = status[63];
wire [23:0] dbg_pixel;

///////////////////////   VIDEO   ///////////////////////////////

wire [8:0] hcnt, vcnt;
wire        hblank, vblank, hsync, vsync;

// COIN port (sngkace-only): COIN1 = bit16, COIN2 = bit17, both
// IP_ACTIVE_LOW; bit23 is MAME's z80_nmi_r() (IP_ACTIVE_HIGH, not
// inverted) -- rtl/psikyo_top.sv's own nmi_pending output mirrors that
// exact status (see rtl/sound/sound_cpu_sngkace.sv's own comment for the
// full derivation).
//
// BIT 0 IS A VBLANK STATUS FLAG, ACTIVE LOW (0 while in vblank). It used to
// be tied high with the rest of bits 15:0, which hung the boot: on hardware
// the CPU sat forever in
//     000436: move.l $c00008.l, D0
//     00043C: addq.w #1, $fffe0000.l      (a timeout counter)
//     000442: andi.l #$1, D0
//     000448: bne    $436                 <- spins while bit 0 is SET
// which MAME executes too, but MAME's falls through to 00044A and then
// copies 0x800 longs from $fffee000 to $400000 -- a sprite-RAM DMA, which is
// exactly the thing you time to vertical blanking. So the poll is "wait for
// vblank", and a permanently-set bit 0 means it never arrives.
//
// Inferred from the code's behaviour and MAME's execution path rather than
// read out of psikyo.cpp's INPUT_PORTS (not available locally), so treat the
// exact bit position as verified-by-experiment, not by source.
//
// This sits below the video wires purely because it uses vblank. Feeding a
// psikyo_top output back into one of its inputs is safe here: vblank is
// derived from the video counters, never from coin_in, so there is no
// combinational loop.
wire [31:0] coin_in = {
	8'hFF,                                    // bits 31:24 unused
	nmi_pending,                                // bit 23
	5'h1F,                                      // bits 22:18 unused
	// COIN1/COIN2 live here on sngkace only. On gunbird/btlkroad the same
	// buttons are read from the P1_P2 low byte instead, so hold these
	// inactive (1) there rather than presenting the coin twice.
	board_gunbird ? 2'b11 : {~joystick_1[11], ~joystick_0[11]},
	15'h7FFF,                                   // bits 15:1 unused
	~vblank                                     // bit 0 = VBLANK, active low
};
wire [14:0] rgb;

wire         ym_cs, ym_rd, ym_wr;
wire [1:0]  ym_addr;
wire [7:0]  ym_dout;

psikyo_top #(.BOARD_GUNBIRD(1'b0)) psikyo_top
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.reset(reset),
	.init(~pll_locked),

	.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(), // real pin driven directly from clk_sdram_shifted above
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.p1p2_in(p1p2_in),
	.dsw_in(dsw_in),
	.coin_in(coin_in),
	.board_gunbird(board_gunbird),

	.nmi_pending(nmi_pending),
	.ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
	.ym_dout(ym_dout), .ym_din(8'h00), // no jt10 yet -- see module header

	.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
	.hsync(hsync), .vsync(vsync), .rgb(rgb),

	.dbg_overlay(dbg_overlay), .dbg_render_dis(dbg_render_dis), .dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
	.dbg_pixel(dbg_pixel)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync;
assign VGA_VS = vsync;

// xRGB_555 -> 8 bits/channel, standard MSB-replication expansion (not
// zero-padding, which would darken max-brightness colors) -- rgb[14:10]=R,
// rgb[9:5]=G, rgb[4:0]=B, MAME's own xRGB555 convention (R in the high
// bits), matching docs/phase1_memory_map.md's "Palette format is xRGB_555".
// Normal path is the real xRGB_555 picture. When the OSD's "Trace overlay"
// is on, the debug tracer's captured entry for this scanline is driven
// instead -- decode it with scripts/decode_debug_screenshot.py --mode
// scanline. No rebuild is needed to switch, so instrumentation no longer
// costs a 12-minute round trip.
assign VGA_R = dbg_overlay ? dbg_pixel[23:16] : {rgb[14:10], rgb[14:12]};
assign VGA_G = dbg_overlay ? dbg_pixel[15:8]  : {rgb[9:5],   rgb[9:7]};
assign VGA_B = dbg_overlay ? dbg_pixel[7:0]   : {rgb[4:0],   rgb[4:2]};

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
