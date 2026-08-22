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

    assign cpu_reset_n = reset ? 1'b0 : 1'bz;
    assign cpu_halt_n  = reset ? 1'b0 : 1'bz;   // MUST move with RESET -- see header

    // Asserted only during an actual interrupt-acknowledge cycle -- see
    // header for why permanently asserting this broke every ordinary bus
    // cycle, not just interrupts.
    assign vpa = (fc == 3'b111) ? 1'b0 : 1'b1;

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
        .VMA()
    );

    // Declared here (right after the CPU instance), not next to where each
    // is conceptually driven further down -- this toolchain (vlog -sv)
    // does not resolve forward references to body-local declarations used
    // in an `assign` before their own declaration appears (same class of
    // issue already documented in rtl/memory/sdram/sdram.sv's
    // PROVENANCE.md and rtl/video/tilemap_line_engine.sv's PTR_W comment).
    logic access_started;
    logic latch_write_done;

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
        if (is_rom)              read_mux = rom_data;
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
    // consistent project-wide. Pulsed every cycle the write is active
    // (mem_active_wr stays high for the whole, possibly multi-cycle,
    // wait-extended window) -- matches sound_cpu_sngkace.sv's own proven
    // write scheme exactly: a synchronous single-port memory repeatedly
    // written with the same stable value every cycle is harmless, and
    // this avoids needing a separate "write exactly once" edge/level flag
    // that would just be one more thing to get subtly wrong.
    assign spriteram_wel = mem_active_wr && is_spriteram && !lds_n;
    assign spriteram_weh = mem_active_wr && is_spriteram && !uds_n;
    assign spriteram_wdata = cpu_data;

    assign palette_wel = mem_active_wr && is_palette && !lds_n;
    assign palette_weh = mem_active_wr && is_palette && !uds_n;
    assign palette_wdata = cpu_data;

    assign vram0_wel = mem_active_wr && is_vram0 && !lds_n;
    assign vram0_weh = mem_active_wr && is_vram0 && !uds_n;
    assign vram0_wdata = cpu_data;

    assign vram1_wel = mem_active_wr && is_vram1 && !lds_n;
    assign vram1_weh = mem_active_wr && is_vram1 && !uds_n;
    assign vram1_wdata = cpu_data;

    assign vregs_wel = mem_active_wr && is_vregs && !lds_n;
    assign vregs_weh = mem_active_wr && is_vregs && !uds_n;
    assign vregs_wdata = cpu_data;

    assign workram_wel = mem_active_wr && is_workram && !lds_n;
    assign workram_weh = mem_active_wr && is_workram && !uds_n;
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
    logic rom_pending;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_pending <= 1'b0;
        end else begin
            if (is_rom_access && !rom_pending) rom_pending <= 1'b1;
            else if (rom_valid)                   rom_pending <= 1'b0;
        end
    end

    assign rom_req = is_rom_access && !rom_pending;

    assign dtack_n = is_rom_access        ? ~rom_valid
                     : access_now_nonrom ? ~access_started
                     : 1'b1;

    // ---- vblank IRQ: held level 4, cleared on the CPU's own interrupt-
    // acknowledge bus cycle (FC=3'b111 during an active bus cycle) ----
    logic irq_pending;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            irq_pending <= 1'b0;
        end else begin
            if (vblank) irq_pending <= 1'b1;
            else if (!as_n && fc == 3'b111) irq_pending <= 1'b0;
        end
    end

    assign ipl = irq_pending ? 3'b011 : 3'b111;   // NOT-encoded: 3'b011 -> level 4, see header

endmodule
