// STATUS (2026-08-22): the ModelSim crash that used to block this module
// entirely is FIXED -- root cause was uninitialized signals in the
// vendored TG68K core (rtl/cpu/tg68k/TG68K_ALU.vhd +
// TG68KdotC_Kernel.vhd), a publicly known upstream issue
// (github.com/TobiFlex/TG68K.C/issues/21); full writeup in
// rtl/cpu/tg68k/PROVENANCE.md's "Phase 1 integration" section. Four real,
// necessary fixes went into getting here, all documented inline below
// where each applies: HALT must track RESET, RESET/HALT need `tri1`
// open-collector modeling not a plain driven wire, VPA must be gated to
// interrupt-acknowledge cycles only, and (in the vendored core itself,
// not this module) every previously-uninitialized ALU/kernel signal needed
// an explicit zero initializer.
//
// This module's own address-decode/DTACK logic is now verified correct:
// sim/maincpu_tb/tb_maincpu.sv's Case 1 (real ROM req/valid fetch, all 6
// BRAM regions, the 32-bit input-port read, the sound-latch write) passes
// cleanly. Case 2 (the held-autovectored level-4 vblank IRQ) does not yet
// pass -- root-caused further than "crashes" (the IACK cycle and the
// vector-offset computation pushed into the exception frame are both
// correct; the actual vector-table fetch address comes out wrong, 0x0
// instead of 0x70) but not resolved -- see PROVENANCE.md for exactly
// where to look next. This is a narrower, separate issue from the crash
// and does not block using this module for non-interrupt-driven
// top-level integration work in the meantime.
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

module maincpu #(
    parameter bit BOARD_GUNBIRD = 1'b0
) (
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
    // docs/maincpu_kernel_rewrite.md for the chain of failures that caused.
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
    assign is_coin       = !BOARD_GUNBIRD && (addr24 >= 24'hC00008) && (addr24 <= 24'hC0000B);
    assign is_soundlatch = (addr24 == 24'hC00013);

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
    // An earlier version of this rewrite held req, on the strength of a
    // hold-until-acknowledged comment in sdram_arbiter5.sv, and "fixed" the
    // testbench to accept that. The bridge's own state machine is the
    // authority and it wants a pulse; the old pre-rewrite maincpu pulsed it
    // too. Restored.
    logic rom_req_sent;
    assign rom_req = mem_needed && !is_write && is_rom && !acc_ready && !rom_req_sent;

    // ---- read mux (BRAM + input ports; ROM comes via rom_data) ----
    logic [15:0] read_mux;
    always_comb begin
        if      (is_spriteram) read_mux = spriteram_rdata;
        else if (is_palette)   read_mux = palette_rdata;
        else if (is_vram0)     read_mux = vram0_rdata;
        else if (is_vram1)     read_mux = vram1_rdata;
        else if (is_vregs)     read_mux = vregs_rdata;
        else if (is_workram)   read_mux = workram_rdata;
        else if (is_p1p2)      read_mux = a32[1] ? p1p2_in[15:0] : p1p2_in[31:16];
        else if (is_dsw)       read_mux = a32[1] ? dsw_in[15:0]  : dsw_in[31:16];
        else if (is_coin)      read_mux = a32[1] ? coin_in[15:0] : coin_in[31:16];
        else                   read_mux = 16'hFFFF;   // unmapped read, open bus
    end

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

    assign latch_write = wr_now && is_soundlatch;
    assign latch_data  = cpu_dout[7:0];

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
