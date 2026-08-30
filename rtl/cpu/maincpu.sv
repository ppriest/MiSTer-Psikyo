// Wraps the vendored TG68K core (rtl/cpu/tg68k/, see its PROVENANCE.md
// for the full integration writeup, including the upstream
// uninitialized-signal issue github.com/TobiFlex/TG68K.C/issues/21).
// Four integration requirements, each documented inline below where it
// applies: HALT must track RESET, RESET/HALT need `tri1` open-collector
// modeling not a plain driven wire, VPA must be gated to
// interrupt-acknowledge cycles only, and (in the vendored core itself,
// not this module) every ALU/kernel signal needs an explicit zero
// initializer.
//
// Verified by sim/maincpu_tb/tb_maincpu.sv: real ROM req/valid fetch, all
// 6 BRAM regions, the 32-bit input-port read, the sound-latch write, and
// the held-autovectored level-4 vblank IRQ (PROVENANCE.md records the
// IRQ case once looking like a CPU fault -- the testbench had zeroed the
// vector table itself; keep vectors real when extending that TB).
//
// Main CPU subsystem for the SH201B/KA302C boards (68EC020 @16MHz,
// psikyo.cpp:254-266 base map + per-board overlay, re-verified against
// current MAME source): TG68K.C + address decode + BRAM-region ports +
// sound-latch write + held-autovectored level-4 IRQ (vblank). YM I/O and
// gfx ROM banking aren't this module's concern -- this is the CPU/bus side
// only, matching the "prove the trusted piece before touching the risky
// one" staging already used for sound_cpu_sngkace/gunbird and jt10.
//
// Board select via BOARD_GUNBIRD: sngkace (0) has a separate coin/service
// port at 0xC00008-0xC0000B; gunbird/btlkroad (1, same overlay -- confirmed
// via the GAME() driver table, see docs/phase1_memory_map.md) fold those
// bits into the P1/P2 word instead and don't decode that address at all.
// Both boards share the same sound-latch address (0xC00013) -- s1945n's
// different address (0xC00011) is a Phase 2 concern, not built here.
//
// Program ROM (0x000000-0x0FFFFF, 1MB = 0x80000 words) is req/valid,
// matching sound_cpu_sngkace.sv's own conversion (same derivation
// approach, same reasoning for why a level-tracked rom_pending flag avoids
// the race class that module's first attempt hit -- see that module's
// header). BRAM regions (sprite RAM, palette, tilemap VRAM x2, video regs,
// work RAM) stay fixed one-wait-cycle, matching this project's synchronous
// 1-cycle BRAM convention used everywhere else.
//
// DTACK generation, derived directly from TG68K.vhd/TG68KdotC_Kernel.vhd
// (read, not assumed): the bus state machine samples DTACK at CLK's
// falling edge while parked in its "wait for data" state (S_state="10")
// and only advances once DTACK reads '0' (active) -- a plain level-sensed
// asynchronous handshake, not tied to any fixed T-state count the way
// Z80's WAIT_n is. AS/UDS/LDS/RW are registered outputs that stay
// asserted for as many cycles as needed and are unconditionally
// deasserted for at least one cycle (S_state="11") before the next bus
// cycle can start, so there's always a real gap between accesses -- the
// same "is_rom_access is a clean, glitch-free level" property
// sound_cpu_sngkace.sv's header derives for Z80 holds here too, for the
// same underlying reason (registered bus-control outputs, not directly
// combinational off raw CPU state).
//
// IPL encoding: TG68KdotC_Kernel.vhd inverts the external IPL input
// (`IPL_nr <= NOT IPL`) before comparing against the current interrupt
// mask -- confirmed directly from source, not assumed from real-68000 pin
// naming alone. Requesting level 4 (Psikyo's vblank IRQ, `irq4_line_hold`
// in MAME) means driving IPL=3'b011 (NOT 3'b100).
//
// VPA is asserted (0) ONLY during an actual interrupt-acknowledge cycle
// (FC=3'b111), not permanently -- confirmed the hard way (this was
// initially tied permanently low and, combined with the RESET/HALT bugs
// documented above, contributed to crashing ModelSim within the first 2
// cycles of simulation, before any real instruction executed and with no
// interrupt ever touched). VPA isn't interrupt-specific by itself: per
// TG68K.vhd's own state machine (`IF waitm='0' OR (vpad='0' AND
// sync_state=sync9) THEN S_state<="11"`), VPA=0 tells the core to
// complete the CURRENT bus cycle via its own 6800-style E-clock
// synchronous path instead of waiting for DTACK -- tying it permanently
// low meant every single ordinary ROM fetch was racing two different
// cycle-termination mechanisms (this module's DTACK scheme and the core's
// own VPA/E-clock path) at once. Gating it to FC=3'b111 restricts that
// alternate termination path to interrupt-acknowledge cycles only, which
// is also the real reason DTACK doesn't need to be (and isn't) driven for
// those cycles -- VPA alone terminates them, matching real 68000
// autovectored-interrupt hardware behavior.
//
// The IRQ is held (not pulsed) from `vblank` until the CPU's own interrupt
// acknowledge bus cycle for it is observed (FC=3'b111, the standard 68000
// interrupt-acknowledge function code, combined with an active bus cycle)
// -- matching real level-sensitive-interrupt hardware behavior (the
// requester clears the line once acknowledged), not a fixed-duration pulse
// that could either be dropped before the CPU notices it or held too long.
//
// RESET/HALT are `inout` on TG68K's real entity (the core can also assert
// its own reset via the RESET instruction) -- simplified here to a plain
// driven wire, not genuine open-collector wire-ANDing; a self-reset
// instruction executing mid-game would not be correctly modeled by this
// simplification, but no test program exercises that, and every other
// MiSTer TG68K integration surveyed does the same simplification.
//
// CRITICAL, confirmed the hard way (a first version of this module
// crashed ModelSim outright within the first few cycles, still inside
// reset, and took two real bugs to fully explain -- not one):
//
//   1. TG68K.vhd derives the kernel's own active-low reset as
//      `cpu1reset <= RESET OR HALT` -- BOTH external RESET and HALT must
//      be driven low SIMULTANEOUSLY to actually reset the core. Driving
//      only RESET (leaving HALT permanently released, as this module's
//      first draft did) resolves the OR to '1' (NOT reset), so the kernel
//      never initializes -- this exact failure mode is already documented
//      in sim/tg68k_spike/tb_tg68k_boot.vhd's own header as that spike's
//      first failed run, and should have been cross-checked against
//      before writing this module's own reset wiring rather than
//      rediscovered by crashing the simulator.
//   2. Fixing (1) alone (tying HALT to the same `reset` input as RESET)
//      was NOT sufficient -- still crashed. Root cause: TG68K.vhd's
//      architecture ALSO drives these ports itself --
//      `RESET <= '0' WHEN nResetOut='0' ELSE 'Z';` (same for HALT) -- a
//      genuine open-collector/wired-AND net (the core can self-assert
//      reset, e.g. via the RESET instruction), not a plain output. A
//      first fix drove RESET/HALT as plain continuous strong 0/1 signals;
//      whenever that strong '1' (not-reset) disagreed with the core's own
//      internal desire to drive '0', VHDL's std_logic resolution produced
//      'X', poisoning the reset net from the very first cycle. Fixed by
//      declaring these as `tri1` (SV's "resolves to weak 1 when
//      undriven" net type) and only ever driving a strong '0' to assert,
//      releasing to 'z' otherwise -- letting either side's low assertion
//      win and the implicit weak pull-up supply the idle-high default,
//      the same open-collector behavior the core's own driver expects.

module maincpu (
    input  logic clk,
    input  logic reset,

    // program ROM, req/valid -- 19-bit WORD address into the 1MB region
    output logic         rom_req,
    output logic [18:0] rom_addr,
    input  logic         rom_valid,
    input  logic [15:0] rom_data,

    // sprite RAM (0x400000-0x401FFF, 4096 words), 1-cycle sync BRAM port
    output logic [11:0] spriteram_addr,
    output logic         spriteram_wel, spriteram_weh,
    output logic [15:0] spriteram_wdata,
    input  logic [15:0] spriteram_rdata,

    // palette RAM (0x600000-0x601FFF, 4096 words)
    output logic [11:0] palette_addr,
    output logic         palette_wel, palette_weh,
    output logic [15:0] palette_wdata,
    input  logic [15:0] palette_rdata,

    // tilemap layer 0 VRAM (0x800000-0x801FFF, 4096 words)
    output logic [11:0] vram0_addr,
    output logic         vram0_wel, vram0_weh,
    output logic [15:0] vram0_wdata,
    input  logic [15:0] vram0_rdata,

    // tilemap layer 1 VRAM (0x802000-0x803FFF, 4096 words)
    output logic [11:0] vram1_addr,
    output logic         vram1_wel, vram1_weh,
    output logic [15:0] vram1_wdata,
    input  logic [15:0] vram1_rdata,

    // video regs (0x804000-0x807FFF, 8192 words)
    output logic [12:0] vregs_addr,
    output logic         vregs_wel, vregs_weh,
    output logic [15:0] vregs_wdata,
    input  logic [15:0] vregs_rdata,

    // work RAM (0xFE0000-0xFFFFFF, 65536 words)
    output logic [15:0] workram_addr,
    output logic         workram_wel, workram_weh,
    output logic [15:0] workram_wdata,
    input  logic [15:0] workram_rdata,

    // input ports (read-only, raw values -- caller owns debouncing/mapping)
    input  logic [31:0] p1p2_in,
    input  logic [31:0] dsw_in,
    input  logic [31:0] coin_in,   // sngkace board only; ignored on gunbird

    // Board variant, RUNTIME (from the .mra's <rom index="1"> mod byte), not a
    // compile-time parameter: one .rbf has to serve every game in the family,
    // and MiSTer selects the game from the .mra. sngkace has a separate
    // coin/service port at 0xC00008; gunbird/btlkroad fold those bits into the
    // P1_P2 port's low byte instead and have nothing at 0xC00008.
    input  logic         board_gunbird,

    // SH403/SH404 (s1945/tengai): security MCU at 0xC00006-0xC0000B, sound
    // latch at 0xC00011, MCU status toggle in P1_P2 bit 2, MCU data/bctrl
    // readback replacing DSW bits 15:4 -- docs/phase2_sh404.md. The two
    // flags are separate because s1945n (unprotected) moves ONLY the sound
    // latch, on otherwise-gunbird hardware.
    input  logic         board_sh404,
    input  logic         snd_latch_c00011,
    input  logic         mcu_table_absent,
    input  logic         mcu_table_we,
    input  logic [7:0]  mcu_table_waddr,
    input  logic [7:0]  mcu_table_wdata,
    output logic [7:0]  mcu_bctrl,      // SH404 tile banks live here (bits 7:4)

    // Freeze the CPU (debug). Gates the 16 MHz clock enable, so the 68020
    // simply stops stepping; video timing and the debug overlay keep running,
    // which is what makes a frame comparable against a MAME dump.
    input  logic         pause,

    // sound latch, to the sound CPU side
    output logic [7:0]  latch_data,
    output logic         latch_write,   // pulse: this CPU wrote a new command byte

    // vblank IRQ (level 4, held/autovectored -- see header)
    input  logic         vblank
);

    // =====================================================================
    // CPU: TG68KdotC_Kernel driven DIRECTLY, at a 16 MHz clock enable.
    //
    // This module used to instantiate the TG68K.vhd WRAPPER. That wrapper is
    // an async-68000-BUS ADAPTER, not the CPU: it emulates real 68000 bus
    // phases (AS/UDS/LDS/DTACK) and therefore contains falling-edge
    // registers, and it assumes CLK *is* the CPU clock. Rate-limiting it to
    // 16 MHz meant fighting its design -- see docs/LESSONS_LEARNED.md and
    // docs/LESSONS_LEARNED.md ("TG68K.C") for the chain of failures that caused.
    //
    // The kernel underneath is entirely rising-edge and exposes clkena_in
    // for exactly this purpose. Established cores drive it directly and own
    // the bus interface themselves; mist-devel/plus_too's tg68k.v is the
    // reference. Its interface is synchronous and far simpler:
    //
    //   busstate: 00 fetch code, 10 read data, 11 write data, 01 no access
    //   data_in / data_write are SEPARATE ports -- no bidirectional DATA net
    //
    // Consequences, all of which delete code that existed only to serve the
    // wrapper: no DATA tri-state, no AS/UDS/LDS phase emulation, no DTACK
    // handshake, and no VPA/E-clock autovector games (IPL_autovector is
    // simply tied high). It also removes the need for any CPU
    // set_multicycle_path in Psikyo.sdc -- an all-rising-edge kernel gated
    // by a real clock enable has no half-cycle paths to mis-constrain.
    // =====================================================================

    // ---- 16 MHz CPU clock enable ----
    // The real SH201B/KA302C board clocks the 68EC020 at 32MHz/2 = 16 MHz
    // (MAME psikyo.cpp sngkace(), "verified on pcb"). clk_sys is this
    // hardware's 14.318181...MHz screen XTAL x 6 = 945/11 MHz, and the CPU
    // wants 176/11 MHz, so the enable rate is EXACTLY 176/945 -- a Bresenham
    // accumulator hits it with zero error, where /5 would be 7.4% fast and
    // /6 10.5% slow. Ticks land 5 or 6 clk_sys cycles apart.
    localparam int CE_NUM = 176;   // 16 MHz        numerator   (x 1/11 MHz)
    localparam int CE_DEN = 945;   // 85.909091 MHz denominator (x 1/11 MHz)

    logic [10:0] ce_acc;
    logic        cpu_ce;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ce_acc <= 11'd0;
            cpu_ce <= 1'b0;
        end else if (pause) begin
            cpu_ce <= 1'b0;
        end else if (ce_acc + CE_NUM >= CE_DEN) begin
            ce_acc <= 11'(ce_acc + CE_NUM - CE_DEN);
            cpu_ce <= 1'b1;
        end else begin
            ce_acc <= 11'(ce_acc + CE_NUM);
            cpu_ce <= 1'b0;
        end
    end

    // ---- kernel instance ----
    logic [31:0] a32;
    logic [15:0] cpu_din, cpu_dout;
    logic [1:0]  busstate;
    logic        nWr, nUDS, nLDS;
    logic [2:0]  fc;
    logic [2:0]  ipl;
    logic        cpu_clkena;

    TG68KdotC_Kernel #(
        .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
        .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
        .BarrelShifter(0), .MUL_Hardware(1)
    ) u_cpu (
        .clk(clk),
        .nReset(~reset),
        .clkena_in(cpu_clkena),
        .data_in(cpu_din),
        .IPL(ipl),
        .IPL_autovector(1'b1),   // Psikyo's level-4 vblank IRQ is autovectored
        .berr(1'b0),             // active HIGH in the kernel; no bus errors here
        .CPU(2'b11),             // 68020
        .addr_out(a32),
        .data_write(cpu_dout),
        .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
        .busstate(busstate),
        .longword(),
        .nResetOut(),
        .FC(fc),
        .clr_berr(),
        .skipFetch(),
        .regin_out(), .CACR_out(), .VBR_out()
    );

    // ---- address decode (unchanged from the previous implementation) ----
    logic [23:0] addr24;
    assign addr24 = a32[23:0];

    logic is_rom, is_spriteram, is_palette, is_vram0, is_vram1, is_vregs, is_workram;
    logic is_p1p2, is_dsw, is_coin, is_soundlatch;

    assign is_rom        = (addr24 <= 24'h0FFFFF);
    assign is_spriteram  = (addr24 >= 24'h400000) && (addr24 <= 24'h401FFF);
    assign is_palette    = (addr24 >= 24'h600000) && (addr24 <= 24'h601FFF);
    assign is_vram0      = (addr24 >= 24'h800000) && (addr24 <= 24'h801FFF);
    assign is_vram1      = (addr24 >= 24'h802000) && (addr24 <= 24'h803FFF);
    assign is_vregs      = (addr24 >= 24'h804000) && (addr24 <= 24'h807FFF);
    assign is_workram    = (addr24 >= 24'hFE0000) && (addr24 <= 24'hFFFFFF);

    assign is_p1p2       = (addr24 >= 24'hC00000) && (addr24 <= 24'hC00003);
    assign is_dsw        = (addr24 >= 24'hC00004) && (addr24 <= 24'hC00007);
    // $C00008 is decoded on BOTH boards. psikyo.cpp maps 0xc00000-0xc0000b to
    // the input reader for sngkace and gunbird alike -- three longs: P1_P2, DSW,
    // COIN. What differs between the boards is only WHICH BITS the COIN long
    // carries: sngkace puts coin/service/z80-nmi there, gunbird/btlkroad move
    // those into the P1_P2 low byte. Bit 0 -- the status bit the boot polls
    // before its sprite DMA -- is present either way.
    //
    // This was briefly gated with !board_gunbird, which left gunbird reading
    // open bus (0xFFFF) at $C00008. Bit 0 could then never clear and the game
    // hung in the poll loop at 0x4CA..0x4D8, the exact analogue of samuraia's
    // loop at 0x436.
    assign is_coin       = (addr24 >= 24'hC00008) && (addr24 <= 24'hC0000B);
    // Sound latch: byte 0xC00013. Match the WORD (0xC00012-13) and let the
    // lane strobe pick the byte (latch_write below requires !nLDS), the
    // same pattern every BRAM region above uses -- NOT an exact byte-
    // address compare. The exact compare only fired for a move.b addressed
    // at 0xC00013 itself; a move.w to 0xC00012 or move.l to 0xC00010
    // (whose second word beat is 0xC00012 with the command byte on the low
    // lane -- byte-lane dispatch MAME's address map performs transparently)
    // never matched, so the 68020's sound commands never reached the Z80:
    // measured on hardware 2026-08-29 as "sound latch writes: 0" across
    // boot, attract, AND real gameplay, while the Z80 dutifully serviced
    // timer IRQs -- total silence beyond the Z80's own boot jingle.
    // s1945n/s1945/tengai moved the latch to byte 0xC00011 (word 0xC00010);
    // the lane strobe below (!nLDS) picks the odd byte either way.
    assign is_soundlatch = snd_latch_c00011 ? (addr24[23:1] == 23'h600008)    // word 0xC00010
                                             : (addr24[23:1] == 23'h600009);   // word 0xC00012

    // word-address translation (drop bit 0 -- every region is word-granular)
    assign rom_addr       = a32[19:1];
    assign spriteram_addr = a32[12:1];
    assign palette_addr   = a32[12:1];
    assign vram0_addr     = a32[12:1];
    assign vram1_addr     = a32[12:1];
    assign vregs_addr     = a32[13:1];
    assign workram_addr   = a32[16:1];

    // ---- bus access state ----
    // The CPU is stalled purely by holding cpu_clkena low; there is no DTACK.
    // acc_ready is a LEVEL, not a pulse, so it cannot be missed by the 16 MHz
    // enable the way a one-cycle valid could -- the CPU simply advances on the
    // first cpu_ce tick after the access completes.
    logic        acc_ready;
    logic [15:0] acc_data;

    // Settle/latency phase counter. The CPU's address (a32) is a registered
    // kernel output that changes on a cpu_ce tick, but its downstream path
    // measures ~14 ns -- longer than one 11.64 ns clock -- so it is NOT
    // settled during the first cycle after a step. Acting in that cycle
    // would commit a BRAM write to a half-settled ADDRESS, which repeating
    // the write later does not undo.
    //   acc_ph == 0 : address still settling, do nothing
    //   acc_ph == 1 : address settled -> commit writes here
    //   acc_ph == 2 : BRAM has output data for the settled address -> capture
    // (BRAM registers its address each edge and returns data one cycle
    // later, so the first output that corresponds to a settled address
    // appears at phase 2.)
    logic [1:0]  acc_ph;

    wire mem_needed = (busstate != 2'b01);
    wire is_write   = (busstate == 2'b11);

    assign cpu_clkena = cpu_ce && (!mem_needed || acc_ready);

    // ROM req is a ONE-CYCLE PULSE, not a held level.
    //
    // rtl/memory/sdram_narrow_bridge.sv latches the request in B_IDLE
    // (`if (req) begin word_sel <= addr[2:1]; bstate <= B_WAIT; end`) and
    // returns to B_IDLE once g_valid arrives. If req is still asserted then,
    // it immediately re-enters B_WAIT and issues ANOTHER granule read, and
    // keeps doing so until req drops -- burning SDRAM bandwidth and making
    // cpu_rom_valid pulse repeatedly for a single CPU access.
    //
    // The bridge's own state machine is the authority on the req shape,
    // and it wants a PULSE -- not held-until-acknowledged (sdram_arbiter5.sv
    // documents a different contract for its own port; it does not apply
    // here).
    logic rom_req_sent;
    assign rom_req = mem_needed && !is_write && is_rom && !acc_ready && !rom_req_sent;

    // ---- SH403/SH404 security MCU (rtl/cpu/s1945_mcu.sv) ----
    // Bus-facing glue only; the protocol lives in the module. All strobes
    // are gated on board_sh404 so the other boards see no behavior change.
    logic [7:0] mcu_data_byte, mcu_control_byte;
    logic        mcu_status;
    logic        mcu_rd_consume, mcu_rd_status_toggle;
    logic        mcu_wr_data, mcu_wr_bctrl, mcu_wr_control, mcu_wr_direction, mcu_wr_command;

    s1945_mcu u_mcu (
        .clk(clk), .reset(reset),
        .wr_data(mcu_wr_data), .wr_bctrl(mcu_wr_bctrl),
        .wr_control(mcu_wr_control), .wr_direction(mcu_wr_direction),
        .wr_command(mcu_wr_command),
        .wdata_h(cpu_dout[15:8]), .wdata_l(cpu_dout[7:0]),
        .data_byte(mcu_data_byte), .control_byte(mcu_control_byte),
        .bctrl(mcu_bctrl), .mcu_status(mcu_status),
        .rd_consume(mcu_rd_consume), .rd_status_toggle(mcu_rd_status_toggle),
        .table_absent(mcu_table_absent),
        .table_we(mcu_table_we), .table_waddr(mcu_table_waddr), .table_wdata(mcu_table_wdata)
    );

    // ---- read mux (BRAM + input ports; ROM comes via rom_data) ----
    // SH404 overrides (each replaces only the bits MAME's s1945 handlers
    // own -- docs/phase2_sh404.md "Bit polarity" for why every bit here is
    // deliberate):
    //  - P1_P2 low word bit 2: the ACTIVE_HIGH mcu_status toggle, injected
    //    RAW -- it must NOT pass through the active-low joystick inversion.
    //  - DSW low word: {MCU data byte, bctrl[7:4], region nibble}. The
    //    gunbird boards' vblank bit at DSW bit 7 does NOT exist here --
    //    bits 7:4 are bctrl readback.
    //  - COIN word 0xC00008 high byte: mcu control read (latching | 0x08).
    logic [15:0] read_mux;
    always_comb begin
        if      (is_spriteram) read_mux = spriteram_rdata;
        else if (is_palette)   read_mux = palette_rdata;
        else if (is_vram0)     read_mux = vram0_rdata;
        else if (is_vram1)     read_mux = vram1_rdata;
        else if (is_vregs)     read_mux = vregs_rdata;
        else if (is_workram)   read_mux = workram_rdata;
        else if (is_p1p2)      read_mux = a32[1]
            ? (board_sh404 ? {p1p2_in[15:3], mcu_status, p1p2_in[1:0]} : p1p2_in[15:0])
            : p1p2_in[31:16];
        else if (is_dsw)       read_mux = a32[1]
            ? (board_sh404 ? {mcu_data_byte, mcu_bctrl[7:4], dsw_in[3:0]} : dsw_in[15:0])
            : dsw_in[31:16];
        else if (is_coin)      read_mux = a32[1]
            ? coin_in[15:0]
            : (board_sh404 ? {mcu_control_byte, coin_in[23:16]} : coin_in[31:16]);
        else                   read_mux = 16'hFFFF;   // unmapped read, open bus
    end

    // Read side effects: exactly one pulse per bus access, on the same
    // cycle the data is captured (acc_ph == 2). A 68020 long read splits
    // into two word cycles on this 16-bit bus, so the consume fires only
    // on the word that actually carries the MCU byte (0xC00006) -- firing
    // on the 0xC00004 half would invalidate the latch before the second
    // half returned it (docs/phase2_sh404.md "Read side effects").
    wire rd_now = mem_needed && !is_write && !is_rom && !acc_ready && (acc_ph == 2'd2);
    assign mcu_rd_consume        = board_sh404 && rd_now && is_dsw  && a32[1];
    assign mcu_rd_status_toggle  = board_sh404 && rd_now && is_p1p2 && a32[1];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            acc_ready    <= 1'b0;
            acc_data     <= 16'h0000;
            acc_ph       <= 2'd0;
            rom_req_sent <= 1'b0;
        end else if (cpu_clkena) begin
            // CPU has consumed this access; arm for the next one
            acc_ready    <= 1'b0;
            acc_ph       <= 2'd0;
            rom_req_sent <= 1'b0;
        end else if (mem_needed && !acc_ready) begin
            if (rom_req) rom_req_sent <= 1'b1;   // one pulse per access
            if (acc_ph != 2'd3) acc_ph <= acc_ph + 2'd1;
            if (is_rom && !is_write) begin
                // SDRAM latency dominates; rom_req is held until valid
                if (rom_valid) begin
                    acc_data  <= rom_data;
                    acc_ready <= 1'b1;
                end
            end else if (is_write) begin
                if (acc_ph >= 2'd1) acc_ready <= 1'b1;   // committed this cycle
            end else begin
                if (acc_ph >= 2'd2) begin
                    acc_data  <= read_mux;
                    acc_ready <= 1'b1;
                end
            end
        end
    end

    assign cpu_din = acc_data;   // registered and stable -- never combinational

    // ---- writes ----
    // Held for exactly the cycle at which the address is settled and the
    // access completes (acc_ph == 1) -- see acc_ph's comment. One cycle is
    // all a synchronous BRAM port needs, and it gives the sound latch the
    // single pulse its receiver expects.
    wire wr_now = mem_needed && is_write && !acc_ready && (acc_ph == 2'd1);

    assign spriteram_wel   = wr_now && is_spriteram && !nLDS;
    assign spriteram_weh   = wr_now && is_spriteram && !nUDS;
    assign spriteram_wdata = cpu_dout;

    assign palette_wel   = wr_now && is_palette && !nLDS;
    assign palette_weh   = wr_now && is_palette && !nUDS;
    assign palette_wdata = cpu_dout;

    assign vram0_wel   = wr_now && is_vram0 && !nLDS;
    assign vram0_weh   = wr_now && is_vram0 && !nUDS;
    assign vram0_wdata = cpu_dout;

    assign vram1_wel   = wr_now && is_vram1 && !nLDS;
    assign vram1_weh   = wr_now && is_vram1 && !nUDS;
    assign vram1_wdata = cpu_dout;

    assign vregs_wel   = wr_now && is_vregs && !nLDS;
    assign vregs_weh   = wr_now && is_vregs && !nUDS;
    assign vregs_wdata = cpu_dout;

    assign workram_wel   = wr_now && is_workram && !nLDS;
    assign workram_weh   = wr_now && is_workram && !nUDS;
    assign workram_wdata = cpu_dout;

    // !nLDS: byte 0xC00013 is the word's LOW byte lane -- true for a
    // move.b to 0xC00013, a move.w to 0xC00012, and a move.l to 0xC00010's
    // second beat alike; cpu_dout[7:0] carries that lane's data in all
    // three cases.
    assign latch_write = wr_now && is_soundlatch && !nLDS;
    assign latch_data  = cpu_dout[7:0];

    // SH404 MCU register writes, byte-lane addressed exactly like MAME's
    // byte handlers: a word write to 0xC00006 hits data (UDS) and bctrl
    // (LDS) in the same cycle, each from its own lane.
    assign mcu_wr_data      = board_sh404 && wr_now && is_dsw  &&  a32[1] && !nUDS; // 0xC00006
    assign mcu_wr_bctrl     = board_sh404 && wr_now && is_dsw  &&  a32[1] && !nLDS; // 0xC00007
    assign mcu_wr_control   = board_sh404 && wr_now && is_coin && !a32[1] && !nUDS; // 0xC00008
    assign mcu_wr_direction = board_sh404 && wr_now && is_coin && !a32[1] && !nLDS; // 0xC00009
    assign mcu_wr_command   = board_sh404 && wr_now && is_coin &&  a32[1] && !nLDS; // 0xC0000B

    // ---- vblank IRQ: level 4, held until the CPU acknowledges ----
    // vblank is a LEVEL held for the full 38-line vertical blank (~2.4 ms).
    // The CPU acknowledges within microseconds, i.e. while vblank is still
    // high, so set-priority would discard the acknowledge and pin ipl at
    // level 4 forever -- the ISR would re-enter after every RTE. Match MAME's
    // irq4_line_hold: assert on the RISING edge, hold until acknowledged, and
    // let the acknowledge win.
    //
    // An interrupt-acknowledge cycle is FC=3'b111 during a real memory access.
    logic irq_pending, vblank_d;

    wire iack = mem_needed && (fc == 3'b111);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            irq_pending <= 1'b0;
            vblank_d    <= 1'b0;
        end else begin
            vblank_d <= vblank;
            if (iack)                      irq_pending <= 1'b0;
            else if (vblank && !vblank_d)  irq_pending <= 1'b1;
        end
    end

    // The kernel inverts IPL internally (IPL_nr <= NOT IPL), so level 4 is
    // requested by driving 3'b011, NOT 3'b100.
    assign ipl = irq_pending ? 3'b011 : 3'b111;

endmodule
