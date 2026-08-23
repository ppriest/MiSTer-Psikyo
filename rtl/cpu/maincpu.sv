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
    logic [31:0] a;
    logic [2:0]  fc;
    logic         as_n, uds_n, lds_n, rw;
    logic         dtack_n;
    logic [2:0]  ipl;
    logic         vpa;
    wire  [15:0] cpu_data;
    tri1          cpu_reset_n, cpu_halt_n;   // open-collector, see header

    // Real-hardware bring-up (docs/ROADMAP.md): CONFIRMED root cause of
    // the CPU never generating a single bus cycle on real hardware, found
    // and fixed via a real Quartus quartus_fit run plus live hardware
    // bisection (a debug tap driving a real screen color, since a
    // SystemVerilog hierarchical reference into TG68K.vhd's internal
    // signals does not elaborate for Quartus synthesis at all -- Error
    // (10207) -- unlike ModelSim, where it works fine). cpu_reset_n/
    // cpu_halt_n are tri1 (open-collector) because TG68K.vhd's own
    // architecture ALSO drives RESET/HALT (it can self-assert reset via
    // the 68k RESET instruction) -- reaching the idle-high default
    // requires both sides to release to Z and resolve via a weak
    // pull-up. A real quartus_fit run showed Quartus synthesizing that
    // resolution as a plain selector (Warning (13048), TG68K.vhd) rather
    // than genuine wired-AND resolution, and live hardware confirmed the
    // idle-high default never actually resolves -- TG68K.vhd's own
    // `cpu1reset` net reads permanently stuck low, holding the CPU in
    // reset forever. Two attempts to fix cpu_reset_n/cpu_halt_n directly
    // (making them non-tri-state, both then just one) both hit real
    // Quartus synthesis errors (13076, "multiple drivers") on TG68K.vhd's
    // own internal nets -- any non-tri-state alternative on RESET/HALT
    // themselves is a genuine conflict with TG68K.vhd's own driver, not
    // an ambiguity Quartus can optimize around. The actual fix doesn't
    // touch RESET/HALT at all: TG68K.vhd's `ext_force_run` port is a
    // separate, single-driver signal ORed into cpu1reset's computation
    // (and into an equivalent `effective_reset` signal gating TG68K.vhd's
    // own bus-cycle state machine, which used raw RESET directly and had
    // the exact same problem one level further down) -- wired below.
    // Confirmed on real hardware: the CPU now generates real ROM bus
    // cycles and successfully fetches valid data.
    assign cpu_reset_n = reset ? 1'b0 : 1'bz;
    assign cpu_halt_n  = reset ? 1'b0 : 1'bz;   // MUST move with RESET -- see header

    // Asserted only during an actual interrupt-acknowledge cycle -- see
    // header for why permanently asserting this broke every ordinary bus
    // cycle, not just interrupts.
    assign vpa = (fc == 3'b111) ? 1'b0 : 1'b1;

    // ---- 16 MHz CPU clock enable ----
    // The real SH201B/KA302C board clocks the 68EC020 at 32MHz/2 = 16 MHz
    // (MAME psikyo.cpp's sngkace(), commented "verified on pcb"; the Z80 is
    // the same 32MHz XTAL /8 = 4 MHz and the YM2610 /4 = 8 MHz).
    //
    // TG68K.C used to free-run on clk_sys, which was wrong twice over.
    // Accuracy: 85.909091 MHz is 5.37x the real CPU speed. Correctness --
    // and this is what actually broke real hardware -- it is physically
    // unachievable. A real quartus_sta run on the post-fit netlist put the
    // clk_sys domain's Fmax at 48.74 MHz against an 85.909091 MHz clock:
    // setup slack -8.879 ns, TNS -21031 ns, and every one of the 50 worst
    // paths in the entire design inside TG68KdotC_Kernel (its register file
    // and the regfile bypass network, needing ~19.6 ns against an 11.64 ns
    // budget). Nothing else in the design failed timing at all. That is why
    // the core booted on hardware but read back garbage that simulation
    // could never reproduce, and why it was completely insensitive to
    // SDRAM_CLK phase -- the failing paths were internal fabric logic, not
    // the memory interface.
    //
    // Exact ratio, no rounding needed: clk_sys is this hardware's real
    // 14.318181...MHz screen XTAL x 6 = 945/11 MHz, and the CPU wants
    // 176/11 MHz, so the enable rate is exactly 176/945. A Bresenham
    // accumulator hits that average precisely (a fixed /5 would be 7.4%
    // fast, /6 10.5% slow). Consecutive ticks are 5 or 6 clk_sys cycles
    // apart, so the shortest window the kernel's ~19.6 ns critical path
    // ever gets is 5 x 11.64 = 58.2 ns -- a 3x margin.
    localparam int CE_NUM = 176;   // 16 MHz       numerator   (x 1/11 MHz)
    localparam int CE_DEN = 945;   // 85.909091MHz denominator (x 1/11 MHz)

    logic [10:0] ce_acc;
    logic        cpu_ce;

    // Companion enable for TG68K.vhd's falling-edge processes: the SAME
    // pulse delayed one clk_sys period. A rising-edge register samples the
    // enable held during the preceding period, so the rising-edge work for
    // a pulse in period P fires at the END of P, while the falling edge
    // inside P is half a period EARLIER -- one shared enable would run each
    // CPU cycle's two halves in the wrong order. See ext_clkena_f's port
    // comment in TG68K.vhd for the failure this actually produced.
    logic        cpu_ce_f;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ce_acc   <= 11'd0;
            cpu_ce   <= 1'b0;
            cpu_ce_f <= 1'b0;
        end else begin
            cpu_ce_f <= cpu_ce;
            if (ce_acc + CE_NUM >= CE_DEN) begin
                ce_acc <= 11'(ce_acc + CE_NUM - CE_DEN);
                cpu_ce <= 1'b1;
            end else begin
                ce_acc <= 11'(ce_acc + CE_NUM);
                cpu_ce <= 1'b0;
            end
        end
    end

    TG68K #(
        .CPU(2'b11)   // 68020 mode, matching the Phase 0 spike's verified config
    ) u_cpu (
        .CLK(clk),
        .RESET(cpu_reset_n),
        .HALT(cpu_halt_n),
        .BERR(1'b0),
        .IPL(ipl),
        .ADDR(a),
        .FC(fc),
        .DATA(cpu_data),
        .AS(as_n),
        .UDS(uds_n),
        .LDS(lds_n),
        .RW(rw),
        .DTACK(dtack_n),
        .E(),
        .VPA(vpa),
        .VMA(),
        .ext_force_run(~reset), // real-hardware fix -- see TG68K.vhd's own header comment
        .ext_clkena(cpu_ce),    // 16 MHz CPU step -- see cpu_ce's own comment above
        .ext_clkena_f(cpu_ce_f) // same pulse, delayed one cycle -- see cpu_ce_f
    );

    // Declared here (right after the CPU instance), not next to where each
    // is conceptually driven further down -- this toolchain (vlog -sv)
    // does not resolve forward references to body-local declarations used
    // in an `assign` before their own declaration appears (same class of
    // issue already documented in rtl/memory/sdram/sdram.sv's
    // PROVENANCE.md and rtl/video/tilemap_line_engine.sv's PTR_W comment).
    logic access_started;
    logic latch_write_done;

    // Declared up here for the same forward-reference reason as the two
    // above -- read_mux (further down) consumes rom_data_l. See the
    // "ROM read capture" block near dtack_n for why these exist at all.
    logic        rom_ready;
    logic [15:0] rom_data_l;

    // ---- address decode ----
    logic [23:0] addr24;
    assign addr24 = a[23:0];

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
    assign is_dsw         = (addr24 >= 24'hC00004) && (addr24 <= 24'hC00007);
    assign is_coin        = !BOARD_GUNBIRD && (addr24 >= 24'hC00008) && (addr24 <= 24'hC0000B);
    assign is_soundlatch = (addr24 == 24'hC00013);

    // ---- word-address translation (drop bit 0 -- byte address -> word
    // address for every region below; all regions are word-granular BRAM,
    // matching every other BRAM port convention in this project) ----
    assign rom_addr        = a[19:1];
    assign spriteram_addr  = a[12:1];
    assign palette_addr    = a[12:1];
    assign vram0_addr      = a[12:1];
    assign vram1_addr      = a[12:1];
    assign vregs_addr      = a[13:1];
    assign workram_addr    = a[16:1];

    // ---- bus cycle state ----
    logic mem_active_rd, mem_active_wr;
    assign mem_active_rd = !as_n && rw;
    assign mem_active_wr = !as_n && !rw;

    logic is_rom_access;
    assign is_rom_access = mem_active_rd && is_rom;   // ROM is read-only, no write path

    // ---- read data mux (drives cpu_data during an active read cycle only) ----
    logic [15:0] read_mux;
    always_comb begin
        if (is_rom)              read_mux = rom_data_l;   // latched, NOT raw -- see below
        else if (is_spriteram)   read_mux = spriteram_rdata;
        else if (is_palette)      read_mux = palette_rdata;
        else if (is_vram0)         read_mux = vram0_rdata;
        else if (is_vram1)         read_mux = vram1_rdata;
        else if (is_vregs)         read_mux = vregs_rdata;
        else if (is_workram)      read_mux = workram_rdata;
        else if (is_p1p2)          read_mux = a[1] ? p1p2_in[15:0] : p1p2_in[31:16];
        else if (is_dsw)            read_mux = a[1] ? dsw_in[15:0]   : dsw_in[31:16];
        else if (is_coin)           read_mux = a[1] ? coin_in[15:0]  : coin_in[31:16];
        else                          read_mux = 16'hFFFF;   // unmapped read, open bus
    end

    assign cpu_data = mem_active_rd ? read_mux : 16'bz;

    // ---- writes: BRAM regions + sound latch ----
    // Byte-lane write enables (wel=low byte/D7-0, weh=high byte/D15-8) --
    // matches rtl/memory/sdram/sdram.sv's own wrl/wrh convention, kept
    // consistent project-wide. Held for every cycle the write is active
    // (mem_active_wr stays high for the whole, possibly multi-cycle,
    // wait-extended window) -- matches sound_cpu_sngkace.sv's own proven
    // write scheme exactly: a synchronous single-port memory repeatedly
    // written with the same stable value every cycle is harmless, and
    // this avoids needing a separate "write exactly once" edge/level flag
    // that would just be one more thing to get subtly wrong.
    //
    // ...with one addition: every enable is also gated on `access_started`,
    // which suppresses the FIRST clk_sys cycle of the access. This is not
    // cosmetic. TG68K.C's combinational output paths (register file ->
    // internal data-out mux -> the DATA tri-state net -> this module's
    // decode -> BRAM address/data ports) measure ~14 ns on real silicon,
    // which is LONGER than one 11.64 ns clk_sys period. The CPU now only
    // steps on the 16 MHz cpu_ce tick, so for the first cycle or two after
    // each step `a`/`cpu_data` are still settling. Committing a write in
    // that window writes real data to a WRONG, half-settled ADDRESS -- a
    // silent corruption that repeating the write on later, settled cycles
    // does not undo. `access_started` is `!as_n` delayed one cycle, so
    // gating on it gives the address and data two full clk_sys periods
    // (23.3 ns) to settle before anything commits, and the write still
    // holds for the remaining several cycles of the bus cycle. It is also
    // the exact signal `dtack_n` already uses for these regions, so the
    // write commits on the same cycle the CPU is told the access completed.
    assign spriteram_wel = mem_active_wr && access_started && is_spriteram && !lds_n;
    assign spriteram_weh = mem_active_wr && access_started && is_spriteram && !uds_n;
    assign spriteram_wdata = cpu_data;

    assign palette_wel = mem_active_wr && access_started && is_palette && !lds_n;
    assign palette_weh = mem_active_wr && access_started && is_palette && !uds_n;
    assign palette_wdata = cpu_data;

    assign vram0_wel = mem_active_wr && access_started && is_vram0 && !lds_n;
    assign vram0_weh = mem_active_wr && access_started && is_vram0 && !uds_n;
    assign vram0_wdata = cpu_data;

    assign vram1_wel = mem_active_wr && access_started && is_vram1 && !lds_n;
    assign vram1_weh = mem_active_wr && access_started && is_vram1 && !uds_n;
    assign vram1_wdata = cpu_data;

    assign vregs_wel = mem_active_wr && access_started && is_vregs && !lds_n;
    assign vregs_weh = mem_active_wr && access_started && is_vregs && !uds_n;
    assign vregs_wdata = cpu_data;

    assign workram_wel = mem_active_wr && access_started && is_workram && !lds_n;
    assign workram_weh = mem_active_wr && access_started && is_workram && !uds_n;
    assign workram_wdata = cpu_data;

    // Sound latch write must pulse exactly once (the receiving side treats
    // it as a real event, not a level) -- gated on access_started (this
    // module's own "ready" signal, same one dtack_n release uses), which
    // is high for only the cycle range where the write is already known
    // to have landed, not every cycle mem_active_wr is merely asserted.
    assign latch_write = mem_active_wr && is_soundlatch && access_started && !latch_write_done;
    assign latch_data  = cpu_data[7:0];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            latch_write_done <= 1'b0;
        end else begin
            if (!mem_active_wr) latch_write_done <= 1'b0;
            else if (latch_write) latch_write_done <= 1'b1;
        end
    end

    // ---- WAIT/DTACK generation ----
    // BRAM/I/O/writes: fixed one-wait-cycle scheme (same shape as
    // sound_cpu_sngkace.sv's access_started), explicitly excluding ROM
    // reads so the two schemes never fight over dtack_n for the same
    // access.
    wire   access_now         = !as_n;
    wire   access_now_nonrom = access_now && !is_rom_access;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            access_started <= 1'b0;
        end else begin
            access_started <= access_now_nonrom;
        end
    end

    // ROM reads: real req/valid handshake -- see sound_cpu_sngkace.sv's
    // header for the full derivation of why a level-tracked rom_pending
    // flag (not a same-cycle edge-detector) is what makes this safe.
    //
    // rom_pending clears on `!is_rom_access` (the CPU has actually moved
    // off this bus cycle), NOT on `rom_valid` -- a real, found bug: clearing
    // on rom_valid's one-cycle pulse let rom_pending drop to 0 while
    // is_rom_access was STILL true (as_n stays low for the rest of this
    // bus cycle after DTACK releases, same "registered bus-control
    // outputs" reasoning this module's own header documents for AS/UDS/
    // LDS/RW), so rom_req fired a second, spurious request for data the
    // CPU had already latched -- harmless in isolation (same address, same
    // answer), but under real SDRAM contention (rtl/memory/psikyo_sdram_top.sv,
    // sim/psikyo_top_tb/tb_psikyo_top.sv's own KNOWN OPEN ISSUE) another
    // Port 2 client can win that spurious request's arbitration slot,
    // overwrite the shared dout register (rtl/memory/sdram/sdram.sv's
    // dout0/dout1/dout2 are literally the same signal, not independently
    // latched per client -- confirmed in isolation by
    // sim/sdram_tb/tb_sdram.sv's Case 6), and dtack_n -- driven straight
    // from rom_valid -- glitches low-high-low right as cpu_data is still
    // combinationally live from mem_active_rd, corrupting what TG68K.C
    // samples. Holding rom_pending through the whole bus cycle suppresses
    // the spurious re-request entirely.
    logic rom_pending;

    // rom_access_d delays the request by one clk_sys cycle for exactly the
    // same reason the BRAM write enables are gated on `access_started` (see
    // that comment): the CPU's ~14 ns address path has not settled on the
    // first cycle after a cpu_ce step, and `rom_req` is asserted for
    // precisely one cycle -- which, ungated, is that unsettled cycle. The
    // arbiter samples `c2_addr` combinationally when it accepts the
    // request, so a half-settled address would be latched and a read issued
    // to the wrong SDRAM location.
    logic rom_access_d;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_access_d <= 1'b0;
            rom_pending  <= 1'b0;
        end else begin
            rom_access_d <= is_rom_access;
            if (rom_access_d && !rom_pending) rom_pending <= 1'b1;
            else if (!is_rom_access)              rom_pending <= 1'b0;
        end
    end

    assign rom_req = rom_access_d && !rom_pending;

    // ---- ROM read capture ----
    // rom_valid is a ONE-CYCLE pulse and rom_data is combinational straight
    // off sdram.sv's shared dout register -- rtl/memory/sdram_narrow_bridge.sv
    // latches neither (its `valid` is `(bstate == B_WAIT) && g_valid` and its
    // `data` is a bit-select of g_data). That was survivable only while
    // TG68K.C stepped on every clk_sys edge: its bus state machine sampled
    // DTACK at every falling edge and re-captured DATA at every rising edge
    // while parked in S_state="10", so the one-cycle window always landed.
    //
    // The CPU now advances only on the 16 MHz cpu_ce tick (see cpu_ce above),
    // so it looks at DTACK roughly once every 5.4 clk_sys cycles. An
    // unlatched one-cycle DTACK would be missed on nearly every fetch and
    // the bus cycle would hang forever. Latch both halves: the data on the
    // valid pulse, and ready as a level held until the CPU drops AS and ends
    // the bus cycle (is_rom_access falls). This also closes the shared-dout
    // exposure the rom_pending comment above describes -- once captured, the
    // word can no longer be overwritten by another Port 2 client.
    // rom_ready must be immune to a SINGLE-cycle glitch on is_rom_access.
    // That signal is combinational off the CPU's address bus, whose path is
    // ~14 ns -- longer than one 11.64 ns clock -- so while the address
    // settles after each 16 MHz CPU step, is_rom can transiently read wrong.
    // Clearing on one cycle of !is_rom_access would then discard an
    // already-latched word and re-drive DTACK mid-access, handing the CPU
    // corrupted data. Require the access to be gone for two consecutive
    // cycles (is_rom_access AND its registered copy both low), which a
    // settling glitch cannot satisfy while a real bus-cycle end always does
    // -- AS stays high for a full CPU step (~5.4 clocks) between accesses.
    logic is_rom_access_d;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_ready       <= 1'b0;
            rom_data_l      <= 16'h0000;
            is_rom_access_d <= 1'b0;
        end else begin
            is_rom_access_d <= is_rom_access;
            if (!is_rom_access && !is_rom_access_d) begin
                rom_ready  <= 1'b0;
            end else if (is_rom_access && rom_valid && !rom_ready) begin
                rom_data_l <= rom_data;
                rom_ready  <= 1'b1;
            end
        end
    end

    assign dtack_n = is_rom_access        ? ~rom_ready
                     : access_now_nonrom ? ~access_started
                     : 1'b1;

    // ---- vblank IRQ: held level 4, cleared on the CPU's own interrupt-
    // acknowledge bus cycle (FC=3'b111 during an active bus cycle) ----
    logic irq_pending;

    // vblank is a LEVEL, held for the full 38-line vertical blank (~2.4 ms,
    // ~205,000 clk_sys cycles) -- not a pulse. The CPU acknowledges within
    // microseconds, i.e. while vblank is STILL HIGH, so the original
    // `if (vblank) set; else if (iack) clear;` gave set priority and threw
    // the acknowledge away. irq_pending then never cleared: ipl stayed at
    // level 4 permanently and the CPU re-entered the ISR immediately after
    // every RTE, so the main program could never advance past its first
    // vblank. On hardware that presents as a core that boots, runs, and
    // then renders nothing further.
    //
    // sim/maincpu_tb/tb_maincpu.sv could not catch this because it pulsed
    // vblank for exactly ONE clock, so its acknowledge always landed after
    // vblank had already fallen. That stimulus is now realistic.
    //
    // Correct behaviour matches MAME's irq4_line_hold: assert once at the
    // START of vblank, hold until the CPU acknowledges, and let the
    // acknowledge take priority.
    logic vblank_d;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            irq_pending <= 1'b0;
            vblank_d    <= 1'b0;
        end else begin
            vblank_d <= vblank;
            if (!as_n && fc == 3'b111)     irq_pending <= 1'b0;  // IACK wins
            else if (vblank && !vblank_d)  irq_pending <= 1'b1;  // vblank rising edge
        end
    end

    assign ipl = irq_pending ? 3'b011 : 3'b111;   // NOT-encoded: 3'b011 -> level 4, see header


endmodule
