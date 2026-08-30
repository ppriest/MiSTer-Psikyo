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
// Top-level HPS/DIP/video glue for the Phase 1 SH201B/KA302C boards
// (Samurai Aces / Sengoku Ace, Gun Bird, Battle K-Road), wiring
// rtl/psikyo_top.sv into the MiSTer framework.
//
// The board variant is selected at RUNTIME from the .mra's mod byte
// (<rom index="1">, arriving as ioctl_index==1), so one .rbf serves all three
// games. It gates the $C00008 COIN-port bit assignments and KA302C tile
// banking. It is latched and NOT reset by `reset`, because MiSTer holds the
// core in reset for the whole ROM download.
//
// Input port bit layout is taken from psikyo.cpp's INPUT_PORTS: sngkace has a
// separate COIN port, gunbird/btlkroad fold coin/service/z80-nmi into the
// P1_P2 low byte instead. DIPs occupy the upper half of the 32-bit DSW long at
// $C00004 with the region jumper in its low byte; see the dsw_in assignment.
// MiSTer joystick bit order (0=Right,1=Left,2=Down,3=Up,4..6=Buttons,
// 10=Start,11=Coin) follows rmonic79/Arcade-Raiden_MiSTer.
//
// Video goes through sys/arcade_video.v (scandoubler, gamma, scanline FX,
// aspect/crop) with rtl/video/screen_rotate_two.sv tapping the output to
// provide rotation and 180-degree flip over HDMI via the HPS framebuffer.
//
// Audio: jt10 (YM2610) is instantiated inside rtl/psikyo_top.sv and its output
// reaches AUDIO_L/R here. ADPCM-A/B sample ROMs are not connected yet, so those
// channels are silent; FM and SSG work.
//
// Not done here: SDRAM_CLK phase tuning
// (rtl/pll/pll_0002.v's -3000ps is inherited, not measured on this board).
module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM is driven by screen_rotate_two (HDMI framebuffer rotation), below.

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Required output once MISTER_FB is enabled; the rotator has no blanking need.
assign FB_FORCE_BLANK = 0;

// Audio comes from jt10 (YM2610) inside psikyo_top. Signed 16-bit, so
// AUDIO_S = 1. YM2610 output is mono on this hardware (MAME routes
// ALL_OUTPUTS to a single "mono" node), and jt10's snd_left/snd_right carry
// the same content; both are wired so the framework's mixer sees a normal
// stereo pair.
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// Rotation controls, declared here because the aspect ratio below depends on
// whether the picture is rotated. Consumed by screen_rotate_two further down.
wire [1:0] rotate_sel = status[48:47];
wire        rotate_en  = |rotate_sel;
wire        rotate_ccw = (rotate_sel == 2'd2);
wire        flip_180   = status[49];

// Aspect ratio. Psikyo boards are vertical, so when the picture is rotated to
// portrait the ORIGINAL aspect is 3:4, not 4:3 -- this was hardcoded 4:3
// regardless, which is why the Original/Full Screen toggle did not appear to
// do anything useful. ar != 0 selects Full Screen / ARC1 / ARC2, where a zero
// ARY means "stretch" in the framework's convention.
//
// Note sys/arcade_video.v does NOT wrap video_freak, so there is no crop
// support here; these two signals are the whole aspect story.
wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? (rotate_en ? 13'd3 : 13'd4) : 13'({ar} - 2'd1);
assign VIDEO_ARY = (!ar) ? (rotate_en ? 13'd4 : 13'd3) : 13'd0;

`include "build_id.v"
// Debug OSD page visibility: every P1 line carries an H1 prefix, so the
// whole page is hidden when status_menumask bit 1 is set. The bit tracks
// the DEBUG_ISSP macro (defined only by the Psikyo_stp revision), so the
// instrumented build shows the Debug page and the release build hides it --
// same source, no code removed, the status bits still function if set by
// a .CFG (only the MENU is hidden).
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
localparam DEBUG_TRACER_EN = 1'b1;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
// Release: the debug tracer (trace buffers, overlay dump bands) compiles
// out entirely alongside the hidden menu -- BRAM back, no debug logic.
localparam DEBUG_TRACER_EN = 1'b0;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;

localparam CONF_STR = {
	"Psikyo;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[48:47],Rotation,Off,CW,CCW;",
	"O[49],Flip 180,Off,On;",
	"H3O[78],Autosave Hiscores,Off,On;",
	"O[64],CRT Adjust,Off,On;",
	"H2O[71:65],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[77:72],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[56],Trace overlay,Off,On;",
	"H1P1O[58:57],Trace source,CPU addr+data,CPU fetch addr,SpriteRAM wr,Palette wr;",
	"H1P1O[62:59],Trace window,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"H1P1O[63],Re-arm capture,A,B;",
	"H1P1-;",
	"H1P1O[40],Sprites,On,Off;",
	"H1P1O[41],Tilemap 0,On,Off;",
	"H1P1O[42],Tilemap 1,On,Off;",
	"H1P1O[43],Sprite swap,FrameStart,EndOfRender;",
	"H1P1O[51],Sound IRQ,On,Off;",
	"H1P1O[53],C00008 bit0,Zero,VBlank;",
	"H1P1O[50],VRAM write auto-pause,Off,On;",
	"H1P1O[54],Frame-count auto-pause,Off,On;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire  [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;

wire         ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire         ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire         ioctl_wait;

`ifdef DEBUG_ISSP
// Which joystick bit is the Pause button? joystick_0[14] (following s32) had
// no effect, and our sys/ is a different revision, so rather than guess again:
// latch a sticky OR of every joystick bit, clear it over JTAG, press only
// Pause, and read back which bit set.
reg [31:0] joy_sticky;
wire [0:0] joy_clear;
always @(posedge clk_sys) begin
	if (joy_clear) joy_sticky <= 32'd0;
	else            joy_sticky <= joy_sticky | joystick_0 | joystick_1;
end

altsource_probe #(
	.sld_auto_instance_index("YES"),
	.instance_id("J"),
	.probe_width(32),
	.source_width(1),
	.source_initial_value("0"),
	.enable_metastability("NO"),
	.lpm_type("altsource_probe")
) u_joy_probe (
	.probe(joy_sticky),
	.source(joy_clear),
	.source_clk(clk_sys),
	.source_ena(1'b1)
);
`endif

// NOTE: hps_io stays in BYTE mode (no WIDE). WIDE(1) would halve the
// HPS-side transfers, but sys/hiscore.v parses the ioctl stream a byte at
// a time (field positions from ioctl_addr[2:0], byte-cascaded registers)
// and returns 8-bit upload data, so it cannot run on a 16-bit ioctl.
// ROM loading is sped up on the SDRAM side instead -- sdram_download
// coalesces byte pairs into single word writes, which also halves the
// ioctl_wait stalls since even bytes are accepted without any SDRAM
// transaction at all.
hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~hs_configured, ~status[64], debug_menu_hide, status[5]}),  // H2: CRT sub-options while CRT Adjust On; H3: autosave only if the .mra carried hiscore data

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// hiscore save/restore (rtl/hiscore.v): index 3 is the config the .mra
	// carries, index 4 the saved score dump read back and written out.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 85.909091 MHz = 14.31818 MHz (this hardware's real pixel/screen XTAL)
// x 6 -- see rtl/pll/pll_0002.v's own header for the full division-ratio
// and SDRAM-timing-margin reasoning.
//
// outclk_1 is SDRAM_CLK, phase-shifted 180 degrees (5820 ps of the 11641 ps
// period). It was 8598 ps = 266 degrees, tuned for the previous controller;
// sdram_s32 captures DQ on a different pipeline and expects the centred
// 180-degree clock its own PLL provides (outclk2_clk = ~c0). With 266
// degrees the core came up as a frozen blue/black pattern -- the CPU never
// booted, because commands and read data were latched on the wrong edge.
// Simulation cannot catch this: the chip model has no notion of clock phase.
//
// It drives the real SDRAM_CLK pin directly (NOT through
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
wire signed [15:0] snd_left, snd_right;

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
// The index-1 payload is now multi-byte (docs/phase2_sh404.md "Mod byte"):
// byte 0 = board flags, bytes 4..47 = the SH404 security MCU's answer
// table (s1945 sets only; forwarded raw to rtl/cpu/s1945_mcu.sv's table
// RAM). The flags latch is gated on ioctl_addr == 0 -- without that gate
// it would re-latch on EVERY payload byte and end up holding the last
// table byte instead of the flags.
reg [7:0] mod_board = 8'd0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 25'd0) mod_board <= ioctl_dout;
end
wire mcu_table_we = ioctl_wr && (ioctl_index == 16'd1)
				  && (ioctl_addr >= 25'd4) && (ioctl_addr < 25'd260);
wire [7:0] mcu_table_waddr = 8'(ioctl_addr - 25'd4);
wire board_gunbird = mod_board[0];
// bit 1: samuraia/samuraiak/sngkace/sngkacea's ADPCM-A ROM needs MAME's
// init_sngkace() bit 6/7 swap applied at download time -- gunbird/btlkroad
// do not, despite sharing the same sound hardware (mod_board bit 0 alone
// can't distinguish them: btlkroad is board_gunbird=1 like gunbird, not
// grouped with samuraia/sngkace despite being neither literally). See
// rtl/memory/psikyo_sdram_top.sv's needs_adpcma_swap port comment.
wire needs_adpcma_swap = mod_board[1];
// bit 2: sound latch at 0xC00011 instead of 0xC00013 (s1945n and all
// SH404 sets). bit 3: SH404 board (security MCU, bctrl tile banking,
// s1945 sound I/O map). bit 4: the MCU has no answer table (tengai) --
// distinct from an all-zero table, see rtl/cpu/s1945_mcu.sv.
wire snd_latch_c00011 = mod_board[2];
wire board_sh404      = mod_board[3];
wire mcu_table_absent = mod_board[4];

// ldr_active is deliberately NOT in `reset` -- rom_loader is itself reset by
// it. The core sees the copy as an extended download instead.
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
// DIP switches arrive as an ioctl download with index 254 (8 bytes, LE
// uint64), NOT through the status word -- see mra_loader.cpp's
// arcade_sw_send(). Saved state lives in config/dips/<mra name>, not the .CFG.
//
// The .mra's <dip bits="..."> numbering must match dip_cur's layout: dip_def
// |= binary[i] << (i*8), so <switches> default byte 0 is bits 7:0, byte 1 is
// 15:8, byte 2 is 23:16. There is no 16-bit offset.
//
// Byte 2 is the region/country jumper, not spare: samuraia has
// PORT_CONFNAME(0x000000ff, ..., Region) with ff=World, ef=USA & Canada,
// df=Korea, bf=Hong Kong, 7f=Taiwan. dsw_in[15:8] genuinely is unused and
// reads as 1s, matching MAME's IP_ACTIVE_LOW default.
reg [63:0] dip_sw;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 254) && !ioctl_addr[24:3])
		dip_sw[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;
end

wire [31:0] dsw_in = {dip_sw[15:8], dip_sw[7:0], 8'hFF, dip_sw[23:16]};

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
//   * At the time, DIPs were (wrongly) read from the status word, so bits
//     48-55 were contested. DIPs now arrive via ioctl index 254 and consume
//     no status bits, but these controls are left where they are.
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
// Freeze the 68020 so a frame can be captured and compared against a MAME dump
// of the same moment. Video and the debug overlay keep running.
// Pause is toggled by the Pause button rather than an OSD entry.
//
// The bit comes from the .mra's <buttons> element, NOT from CONF_STR's J1 list
// -- when an .mra declares buttons, that mapping governs:
//
//   names="Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause"
//
// Names map to joystick bits from bit 4, so the three "-" placeholders pad
// positions 3-5 and put Start at 10, Coin at 11 (which is exactly what the
// input wiring below already uses) and Pause at 12 -- the bit is a function
// of THIS .mra's button list, never a constant copied from another core's.
//
// Edge-triggered toggle, not a level: the button is momentary, so holding it
// would only pause while held.
wire        pause_btn = joystick_0[12] | joystick_1[12];
`ifdef DEBUG_ISSP
// Master enables for the two auto-pause triggers added for the tilemap
// investigation (rtl/psikyo_core.sv). Off by default (status bit 0), so
// neither fires unless deliberately turned on from the OSD -- otherwise
// every boot would auto-pause, in the way of any other use of this build.
wire        dbg_autopause_wr_en    = status[50];
wire        dbg_autopause_frame_en = status[54];
`endif
reg         pause_btn_d, pause;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                        pause <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause <= ~pause;
end
// The CPU is also paused while hiscore touches work RAM; it borrows the CPU's
// RAM port for writes, so the core must actually be stopped first. hiscore
// waits ACCESS_PAUSEPAD cycles after asserting this before it reads or writes.
wire pause_core = pause | hs_pause;
// YM2610 IRQ -> Z80 INT. MAME wires ymsnd.irq_handler() to the audiocpu.
// FM timers drive music tempo -- with the IRQ disabled samuraia plays no
// music at all (verified by ear on hardware). Default ON: status[51] is
// INVERTED so an all-zero/fresh CFG gets music, and the OSD option order
// matches ("On" first = value 0 = default).
wire        snd_irq_en = ~status[51];
// status[52] is free.
// See the coin_in comment: 0 = constant 0 (matches MAME), 1 = ~vblank.
wire        vblank_wait_en   = status[53];
// Experimental: swap the sprite output buffer at the frame boundary rather
// than at end-of-render. Default 0 = the behaviour known to boot.
// Swap the sprite output buffer at the FRAME BOUNDARY by default. MAME's
// memory map calls the sprites "buffered by two frames (list buffered + fb
// buffered)": the list buffer is spriteram_dbuf's snapshot, and this is the
// fb half. Swapping at end-of-render instead (the old default, still
// selectable) shows a pass ~61% down the same frame it was drawn in, so the
// fb contributes only a fraction of a frame and sprites lead the live-VRAM
// tilemaps on screen. Inverted so a cleared .CFG gets the correct behaviour.
wire        dbg_sprite_vsync_swap = ~status[43];
wire [1:0] dbg_src     = status[58:57];
wire [3:0] dbg_window  = status[62:59];
wire        dbg_rearm   = status[63];
wire [23:0] dbg_pixel;

// ---- MAME hiscore.dat support (rtl/hiscore.v) ----
// Restores the score table into work RAM once the game has initialised it,
// and reads it back out to be saved. The .mra carries the hiscore.dat entry
// as rom index 3 (address/length plus the start/end sentinel bytes that
// tell the module the table is initialised and safe to write); index 4 is
// the saved dump. With no index-3 data the module stays unconfigured and
// nothing ever touches game RAM.
//
// HS_ADDRESSWIDTH=17: the entries are 0xFExxxx and work RAM is the 128KB at
// 0xFE0000, so the low 17 bits of the configured address ARE the offset.
// HS_SCOREWIDTH=8: the largest table here is 0x9E bytes (samuraia).
wire        hs_configured;
wire [16:0] hs_address;
wire  [7:0] hs_data_in, hs_data_out;
wire        hs_write;
wire        hs_read;
wire        hs_pause;

hiscore #(
	.HS_ADDRESSWIDTH(17),
	.HS_SCOREWIDTH(8),
	// One hiscore.dat entry per game here, so the config tables are tiny;
	// the default depth of 16 cost four whole M10K blocks and this design
	// is BRAM-bound (the fitter reported 553/553 with logic at 40%).
	.CFG_ADDRESSWIDTH(2),
	.CFG_LENGTHWIDTH(1)
) u_hiscore (
	.clk(clk_sys),
	.reset(reset),
	.paused(pause_core),
	.autosave(status[78]),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_index(ioctl_index[7:0]),
	.OSD_STATUS(OSD_STATUS),
	.data_from_hps(ioctl_dout),
	.data_from_ram(hs_data_out),
	.ram_address(hs_address),
	.data_to_hps(ioctl_din),
	.data_to_ram(hs_data_in),
	.ram_write(hs_write),
	.ram_intent_read(hs_read),
	.ram_intent_write(),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

///////////////////////   VIDEO   ///////////////////////////////

wire [8:0] hcnt, vcnt;
wire        hblank, vblank, hsync, vsync;

// COIN port (sngkace-only): COIN1 = bit16, COIN2 = bit17, both
// IP_ACTIVE_LOW; bit23 is MAME's z80_nmi_r() (IP_ACTIVE_HIGH, not
// inverted) -- rtl/psikyo_top.sv's own nmi_pending output mirrors that
// exact status (see rtl/sound/sound_cpu_sngkace.sv's own comment for the
// full derivation).
//
// BIT 0: the boot polls this and spins until it CLEARS, then DMAs sprite RAM.
// Tying it HIGH hangs the boot. Tying it to ~vblank boots but makes the game
// wait up to a whole frame at every poll, which is a strong candidate for the
// observed HALF SPEED. In MAME the equivalent read returns 0 almost
// immediately (the poll loop exits after a handful of iterations), so a
// constant 0 is the MAME-matching behaviour and costs no waiting.
//
// vblank_wait_en (OSD bit 53) selects: 0 = constant 0 (MAME-like, default),
// 1 = ~vblank (the previous behaviour). A switch because "it boots" was the
// only evidence for the vblank version and that is weak.
//
// Original note, kept because it explains the hang: on hardware the CPU sat
// forever in
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
	vblank_wait_en & ~vblank                    // bit 0, see above
};
wire [14:0] rgb;


psikyo_top #(.BOARD_GUNBIRD(1'b0), .DEBUG_TRACER(DEBUG_TRACER_EN)) psikyo_top
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
	.board_sh404(board_sh404),
	.snd_latch_c00011(snd_latch_c00011),
	.mcu_table_absent(mcu_table_absent),
	.mcu_table_we(mcu_table_we),
	.mcu_table_waddr(mcu_table_waddr),
	.mcu_table_wdata(ioctl_dout),
	.needs_adpcma_swap(needs_adpcma_swap),
	.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
	.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),
	.snd_left(snd_left), .snd_right(snd_right),

	.nmi_pending(nmi_pending),

	.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
	.hsync(hsync), .vsync(vsync), .rgb(rgb),

	.dbg_overlay(dbg_overlay), .dbg_render_dis(dbg_render_dis), .pause(pause_core),
	.hs_address(hs_address), .hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out), .hs_read(hs_read), .hs_write(hs_write),
`ifdef DEBUG_ISSP
	.dbg_autopause_wr_en(dbg_autopause_wr_en), .dbg_autopause_frame_en(dbg_autopause_frame_en),
`endif
	.snd_irq_en(snd_irq_en), .dbg_sprite_vsync_swap(dbg_sprite_vsync_swap), .dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
	.dbg_pixel(dbg_pixel)
);

// ---- video output via sys/arcade_video.v ----
// This core used to drive VGA_R/G/B, VGA_DE/HS/VS, CLK_VIDEO and CE_PIXEL by
// hand, bypassing the framework's video path entirely. That worked, but gave
// up everything arcade_video provides: the scandoubler (so a VGA/CRT setup got
// no 31 kHz option), gamma correction, scanline effects, and video_freak's
// aspect-ratio and cropping handling. sys/arcade_video.v, video_mixer.sv and
// video_freak.sv were all sitting in the tree unused.
//
// The picture is xRGB_555 internally; arcade_video takes a packed bus, so each
// 5-bit channel is expanded to 8 by replicating its top bits (NOT zero-padded,
// which would darken full-brightness colours).
//
// The debug overlay is injected BEFORE arcade_video so it still works, but note
// that scanlines/gamma will alter the pixel values the decoder reads -- keep
// fx=0 and gamma off when capturing a trace, or the decode is meaningless.
// ---- CRT Offset (rtl/video/crt_adjust.sv, vendored from Arcade-Raiden_MiSTer) ----
// Slides the picture on an analog CRT without ever touching the sync: the
// CONTENT is moved inside a line buffer while HSync/VSync stay native, so the
// monitor keeps its lock while you adjust. Sits between the core's raster and
// arcade_video, so (as the module documents for the core-side variant) HDMI
// follows the adjustment too -- leave CRT Adjust Off for an untouched HDMI
// image. NOTE this core is rotated: on the HDMI/rotated output H-Position
// moves the image vertically and V-Shift horizontally, since both act on the
// NATIVE raster, which is what a real CRT in a TATE cabinet wants.
//
// Only the two offsets are wired ("CRT Offset"); hsize is tied to 0, the
// module's documented no-scaling case, which also makes the read rate equal
// the write rate so pxl2_cen is just ce_pix. H-Size would additionally need a
// variable read-rate generator (Raiden builds one from clk quarters).
wire crt_adj_on = status[64];
// H-Position: the OSD stores the INDEX into the option list, and that list has
// 97 entries (0, +1..+48, -48..-1) -- so the negative half wraps at 97, NOT at
// 128. Raiden hit exactly this: wrapping at 128 made "-1" jump 32 pixels.
wire  [6:0] crt_hpos_idx = crt_adj_on ? status[71:65] : 7'd0;
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48)
	? $signed({2'b00, crt_hpos_idx})
	: $signed({2'b00, crt_hpos_idx}) - 9'sd97;
// V-Shift is a plain signed 6-bit field: its 64-entry list (0..+31, -32..-1)
// IS two's complement, so no wrap fixup is needed.
wire signed [5:0] crt_voffset = crt_adj_on ? $signed(status[77:72]) : 6'sd0;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

crt_adjust #(
	.VTOTAL   (262),
	.HTOTAL   (456),
	// CONTENTSHIFT keeps HSync byte-for-byte native (SYNCSHIFT moves the sync
	// itself); this is the mode Raiden ships and the safer one for sync lock.
	.HPOS_MODE(1)
) u_crt_adjust (
	.clk      (clk_sys),
	.pxl_cen  (ce_pix),
	.pxl2_cen (ce_pix),      // hsize tied 0 -> read rate == write rate
	.active   (crt_adj_on),
	.hsize    (5'sd0),
	.hoffset  (crt_hoffset),
	.voffset  (crt_voffset),
	.r_in(r8_raw), .g_in(g8_raw), .b_in(b8_raw),
	.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb),
	.hs_ref_out()
);

wire [7:0] r8_raw = dbg_overlay ? dbg_pixel[23:16] : {rgb[14:10], rgb[14:12]};
wire [7:0] g8_raw = dbg_overlay ? dbg_pixel[15:8]  : {rgb[9:5],   rgb[9:7]};
wire [7:0] b8_raw = dbg_overlay ? dbg_pixel[7:0]   : {rgb[4:0],   rgb[4:2]};

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),

	.RGB_in({crt_r, crt_g, crt_b}),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// ---- Fast ROM loading (rtl/memory/rom_loader.sv) ----
// The .mra's <rom index="0"> carries address="0x30000000", which makes the HPS
// DMA the ROM straight into DDR3: the core sees ioctl_download assert and
// deassert with NO ioctl_wr pulses at all. That is how the mode is detected --
// if any ioctl_wr arrives for index 0 the .mra is an old byte-streaming one and
// sdram_download handles it exactly as before, so both kinds still load.
// (Mechanism from srg320/Arcade-PsikyoSH2_MiSTer.)
// Trigger, mirroring srg320/Arcade-PsikyoSH2_MiSTer: the copy is started out of
// RESET, not from a download-completion edge. With address=0x30000000 the HPS
// DMAs the ROM into DDR3 without the byte-wise ioctl handshake, so an
// end-of-download edge is not a signal the core can rely on seeing at all --
// which is why the first attempt loaded nothing and left SDRAM unwritten.
// MiSTer resets the core once the ROM is in place, so reset-release is the
// point at which DDR3 is known good.
//
// dl_seen_wr still selects the mode: if any ioctl_wr arrived for index 0 the
// .mra is an old byte-streaming one, sdram_download has already filled SDRAM,
// and copying DDR3 over it would destroy a working load.
reg  dl_seen_wr  = 1'b0;   // any byte streamed through the FPGA for index 0
reg  dl_active_d = 1'b0;
reg  ldr_pending = 1'b0;
reg  ldr_start   = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);
always @(posedge clk_sys) begin
	ldr_start   <= 1'b0;
	dl_active_d <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;   // a new index-0 load begins
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;   // ...and it is streaming bytes

	if (reset) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		// only when the ROM did NOT come through the byte path
		if (!dl_seen_wr) ldr_start <= 1'b1;
	end
end

wire        ldr_active;
wire        ldr_req, ldr_we16, ldr_busy;
wire [24:0] ldr_addr;
wire [15:0] ldr_data;
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;

rom_loader u_rom_loader (
	.clk(clk_sys), .reset(reset),
	.start(ldr_start), .busy(ldr_active),
	.needs_adpcma_swap(needs_adpcma_swap), .adpcma_base(25'h0E40000),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.dl_req(ldr_req), .dl_addr(ldr_addr), .dl_data(ldr_data),
	.dl_we16(ldr_we16), .dl_busy(ldr_busy)
);

// DDR3 read port for the loader. DDRAM is otherwise owned by the rotator, so
// the physical pins are muxed below: the loader only runs with the core in
// reset, when there is no picture to rotate.
wire [7:0]  ldr_DDRAM_BURSTCNT;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;
wire [7:0]  ldr_DDRAM_BE;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

`ifdef DEBUG_ISSP
// Fast ROM load visibility. The first attempt produced an unbootable core with
// no way to tell whether the copy never ran or ran against the wrong data, so
// the loader now reports its own progress. reset is tied low so the counters
// survive the core resets that bracket a load.
issp_probe #(.INSTANCE_ID("L")) u_issp_loader (
	.clk(clk_sys),
	.wr_issued(ldr_start),               // times the copy was started
	.wr_acked(ldr_ddr_valid),            // DDR3 granules actually returned
	.cpu_rd_acked(ldr_req & ~ldr_busy),  // SDRAM word writes issued
	.cpu_rd_nonzero(1'b1),
	.sdram_ready(ldr_active),
	.dl_req(dl_seen_wr),                 // 1 = the byte path was used
	.ioctl_download(dl_index0),
	.reset(1'b0),
	.cpu_rd_addr({4'd0, ldr_addr[24:10]}),
	.cpu_rd_data(ldr_data)
);
`endif

// ---- HDMI rotation / flip via the HPS framebuffer (sys DDRAM) ----
// Psikyo boards are vertical (TATE), and flip_screen is not implemented in
// the video pipeline itself -- both orientation and flip are handled here.
//
// screen_rotate_two is Sorgelig's standard MiSTer rotator (GPL v2), taken
// from Arcade-SKNS_MiSTer. It is a TAP, not a filter:
// VGA_R/G/B/HS/VS/DE still drive the analog output directly for CRT use,
// while this writes a rotated (and optionally 180-flipped) copy into DDRAM
// and points the HPS framebuffer at it for HDMI. So CRT keeps the native
// raster and HDMI gets rotation and flip, which is why this also gives us
// flip "for free" without touching the tilemap or sprite paths.
//
// The rotator owns DDRAM. two_screen is 0 -- an SKNS-specific dual-screen
// mode.

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO     (CLK_VIDEO),
	.CE_PIXEL      (CE_PIXEL),

	.VGA_R         (VGA_R),
	.VGA_G         (VGA_G),
	.VGA_B         (VGA_B),
	.VGA_HS        (VGA_HS),
	.VGA_VS        (VGA_VS),
	.VGA_DE        (VGA_DE),

	.rotate_ccw    (rotate_ccw),
	.no_rotate     (~rotate_en),
	.flip          (flip_180),
	.two_screen    (1'b0),
	.video_rotated (),

	.FB_EN         (FB_EN),
	.FB_FORMAT     (FB_FORMAT),
	.FB_WIDTH      (FB_WIDTH),
	.FB_HEIGHT     (FB_HEIGHT),
	.FB_BASE       (FB_BASE),
	.FB_STRIDE     (FB_STRIDE),
	.FB_VBL        (FB_VBL),
	.FB_LL         (FB_LL),

	.DDRAM_CLK     (rot_DDRAM_CLK),
	.DDRAM_BUSY    (DDRAM_BUSY),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR    (rot_DDRAM_ADDR),
	.DDRAM_DIN     (rot_DDRAM_DIN),
	.DDRAM_BE      (rot_DDRAM_BE),
	.DDRAM_WE      (rot_DDRAM_WE),
	.DDRAM_RD      (rot_DDRAM_RD)
);

// DDRAM pin mux: the ROM loader takes the bus while it is copying (core in
// reset, nothing to display), the rotator has it the rest of the time.
wire        rot_DDRAM_CLK;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
wire        rot_DDRAM_WE, rot_DDRAM_RD;

assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

assign AUDIO_L = snd_left;
assign AUDIO_R = snd_right;

endmodule
