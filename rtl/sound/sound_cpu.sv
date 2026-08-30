// Sound CPU subsystem for all Phase 1 boards (Z80 @ 4MHz, psikyo.cpp:357-371,
// re-verified against current MAME source). Replaces the separate
// sound_cpu_sngkace.sv / sound_cpu_gunbird.sv pair, which differed ONLY in
// the memory map, RAM size, I/O port decode and bank-register bit position --
// all now selected at runtime from board_gunbird.
//
// They were chosen by a compile-time `BOARD_GUNBIRD` parameter that nothing
// ever overrode, so every build got sngkace's map. One .rbf serves all three
// games and picks the board at runtime, so Gunbird and Battle K-Road could
// never have produced sound.
//
// Original sngkace header follows.
//
// Sound CPU subsystem for the sngkace board (Z80 @ 4MHz, psikyo.cpp:357-371,
// re-verified against current MAME source): T80se + address decode + bank
// register + sound latch/NMI handshake. YM2610 I/O (ports 0x00-0x03) is
// exposed as an external chip-select bus, deliberately NOT wired to jt10
// yet -- jt10 is vendored but not yet verified (rtl/sound/jt10/PROVENANCE.md),
// so this module is built and tested standalone first, same "prove the
// trusted piece before touching the risky one" approach used throughout
// this project (T80 boot spike before jt10, tilemap engine before sprite
// engine, etc).
//
// Memory map:
//   0x0000-0x77FF  fixed program ROM
//   0x7800-0x7FFF  RAM (2KB, internal to this module)
//   0x8000-0xFFFF  banked ROM window, bank*0x8000 + (addr-0x8000)
// Physical ROM is one 128KB (0x20000) image (ROM_REGION "audiocpu"); bank 0
// maps to the SAME physical bytes as the fixed region (0x00000-0x07FFF),
// banks 1-3 expose the rest of the image (0x08000-0x1FFFF) -- confirmed
// directly from psikyo.cpp's sound_bankswitch_w<0>/m_audiobank->set_entry(),
// not assumed. This lets rom_addr just be a straight concatenation
// {bank_or_00, addr[14:0]} with no subtraction needed.
//
// I/O map (8-bit):
//   0x00-0x03  YM2610 (external chip-select bus, see above)
//   0x04       bank select write (data & 0x03, no shift -- sngkace-specific;
//              gunbird/btlkroad use a different shift, a separate module)
//   0x08       sound latch read
//   0x0C       sound latch acknowledge write (clears NMI)
//
// WAIT_n generation: RAM/I/O access in this module stays synchronous
// (1-cycle read latency, matching every other BRAM interface in this
// project) via the original fixed one-wait-cycle scheme (`access_started`).
// Program ROM reads (fixed 0x0000-0x77FF and banked 0x8000+) instead go
// through a real req/valid handshake (`rom_req`/`rom_valid`), since ROM
// streaming is meant to eventually reach the SDRAM stack (docs/
// phase1_sdram_map.md), which has variable, multi-cycle latency -- a fixed
// 1-cycle wait cannot express that.
//
// This is a second attempt at that conversion -- the first (see
// docs/ROADMAP.md's "Progress" for the full writeup) was reverted after a
// real, reproducible bug: against a 5-cycle-latency ROM model, `LD
// A,(0x8000)` (a 3-byte opcode whose own memory-read M-cycle follows two
// operand-fetch M-cycles) corrupted the accumulator, with no visible
// memory access to 0x8000 in the trace at all -- suspected (not confirmed)
// to be a race in an edge-detector meant to catch "a new ROM access just
// started."
//
// This attempt is designed directly from T80.vhd/T80se.vhd's actual
// T-state logic (read, not re-derived from memory) rather than another
// blind attempt, and deliberately avoids any same-cycle edge-detector:
//
//   - T80.vhd's main state machine (`if TState=2 and Wait_n='0' then` --
//     no assignment) freezes TState at 2 for as long as WAIT_n reads 0,
//     resampled every cycle; it only advances once WAIT_n reads 1.
//   - T80se.vhd captures `DI_Reg <= DI` on the exact edge where
//     `TState=2 and Wait_n='1'` is FIRST true -- so external WAIT_n must
//     go high on the same cycle the requested byte is actually valid on
//     `di`, not before and not after.
//   - RD_n/MREQ_n are registered outputs that default to '1' every cycle
//     and are only pulled low by a matching TState condition -- so there
//     IS always a real gap (T80se's T3, where no condition matches for a
//     non-M1 read) between the end of one read M-cycle and the start of
//     the next, even for back-to-back M-cycles within one instruction
//     (confirmed by reading the RTL, not assumed).
//
// Given that gap is real, `is_rom_read` (a plain combinational level off
// the CPU's own registered mreq_n/rd_n/address, not a separate edge
// register) is a clean, glitch-free signal: it goes high once per M-cycle
// and stays high for exactly that M-cycle's whole read-active window, with
// no possibility of two M-cycles' windows touching. `rom_pending` is a
// level-tracked flag (set the cycle a NEW `is_rom_read` window opens,
// cleared the cycle `rom_valid` arrives) rather than a one-cycle edge
// comparison -- structurally unable to miss a transition the way an
// edge-detector checked on the same cycle it's fed can. `rom_req` fires
// as a single pulse (matches rtl/memory/sdram_phy.sv's/
// sdram_narrow_bridge.sv's "pulse while not busy" client contract, since
// that's what this port is meant to eventually connect to -- NOT this
// project's other convention of a held request until valid, used by
// tilemap_line_engine/sprite_render_engine's gfxrom ports, which is a
// deliberate difference worth noting, not an inconsistency by accident).
//
// Verified in sim/sound_cpu_sngkace_tb/ against a real variable-latency
// (5-cycle) req/valid ROM model, re-running the exact same LD A,(0x8000)
// scenario that failed before, plus real T80-internal T-state/M-cycle
// tracing (hierarchical reference into u_cpu.u0's MCycle/TState signals,
// exposed by T80se.vhd itself) to directly confirm the mechanism above
// against the actual simulated waveform, not just this derivation.

module sound_cpu (
    input logic clk,
    input logic reset,

    // 4 MHz clock enable for the Z80 core (psikyo.cpp:357-371: 4 MHz on
    // every Phase 1 board). Was hardwired CLKEN=1, running the Z80 at the
    // full 85.909 MHz clk_sys -- ~21x real speed. Every software-timed
    // behavior (the self-paced boot jingle's delay loops above all) ran
    // 21x fast: measured on hardware 2026-08-29 as the "garbled but
    // recognizable" boot sound. The ROM req/valid handshake below is
    // stretched to survive the gating (a 1-clk rom_valid pulse between
    // enable ticks would otherwise be sampled by nobody and hang the CPU).
    input logic cen_4m,

    // Runtime board select, from the .mra's mod byte -- 0 = sngkace
    // (Samurai Aces / Sengoku Ace), 1 = gunbird / btlkroad. Must be a
    // RUNTIME input, not a compile-time parameter: one .rbf serves all
    // three games.
    input logic board_gunbird,
    // SH403/SH404 (s1945/tengai): same program map and bank register as
    // gunbird (board_gunbird is also set on these boards), but the I/O map
    // moves: sound chip window 0x08-0x0D, latch read 0x10, latch ack 0x18
    // (psikyo.cpp s1945_sound_io_map). The real chip is a YMF278B; jt10
    // stands in for now (docs/phase2_sh404.md "Sound IO map"), so only
    // 0x08-0x0B reach it and the wave ports 0x0C-0x0D read back 0x00
    // ("ready" -- 0xFF would read as busy-forever to a polling loop).
    input logic board_sh404,

    // external program ROM (128KB physical, 17-bit addr), req/valid --
    // rom_req pulses once per access (while !rom_pending, see below);
    // rom_data must be valid during the same cycle rom_valid pulses
    output logic         rom_req,
    output logic [16:0] rom_addr,
    input  logic         rom_valid,
    input  logic [7:0]  rom_data,

    // sound latch, from the main CPU side
    input  logic [7:0]  latch_data,
    input  logic         latch_write,   // pulse: main CPU wrote a new command byte

    // Mirrors MAME's psikyo_state::z80_nmi_r() (psikyo.cpp): 1 while a sound
    // command is pending (written by the main CPU, not yet acked by this
    // Z80's own ISR -- see latch_pending below), 0 once acked. Real
    // hardware exposes this to the 68020 as a readable input bit (folded
    // into the sngkace board's separate COIN port, byte 0xC00008-0xC0000B
    // bit 23, or gunbird's own P1P2 port bit 7 -- docs/phase1_memory_map.md
    // "Input ports" for the region, MAME source for the exact bit position)
    // so the main CPU can poll "has the Z80 finished my last sound command"
    // before sending a new one.
    output logic         nmi_pending,

`ifdef DEBUG_ISSP
    // Proof the Z80's NMI handler actually RAN TO COMPLETION, not merely
    // that NMI was asserted -- io_latch_ack is the 0x0C write that clears
    // latch_pending at the end of the ISR. nmi_pending alone can't
    // distinguish "never interrupted" from "interrupted, stuck in the ISR
    // before reaching the ack write".
    output logic         dbg_latch_ack_event,
`endif

    // YM2610 I/O handoff
    output logic         ym_cs,
    output logic [1:0]  ym_addr,
    output logic         ym_rd,
    output logic         ym_wr,
    output logic [7:0]  ym_dout,       // Z80 -> YM2610
    input  logic [7:0]  ym_din,        // YM2610 -> Z80
    // YM2610 IRQ, active low. MAME wires ymsnd.irq_handler() to the Z80's
    // INT line; the FM timers drive music tempo through it.
    input  logic         ym_irq_n
);

    logic m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    logic [15:0] a;
    logic [7:0]  di, d_out;
    logic         nmi_n;
    logic         wait_n;

    T80se #(
        .Mode(0), .T2Write(0), .IOWait(1)
    ) u_cpu (
        .RESET_n(~reset), .CLK_n(clk), .CLKEN(cen_4m), .WAIT_n(wait_n),
        .INT_n(ym_irq_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(a), .DI(di), .DO(d_out)
    );

    // ---- address decode ----
    logic is_fixed_rom, is_ram, is_banked;
    assign is_fixed_rom = board_gunbird ? (a <= 16'h7FFF) : (a <= 16'h77FF);
    assign is_ram         = board_gunbird ? ((a >= 16'h8000) && (a <= 16'h81FF))
                                          : ((a >= 16'h7800) && (a <= 16'h7FFF));
    assign is_banked      = board_gunbird ? (a >= 16'h8200) : (a >= 16'h8000);

    // ---- bank register ----
    logic [1:0] bank;

    assign rom_addr = {(is_banked ? bank : 2'b00), a[14:0]};

    // ---- internal RAM (2KB) ----
    logic [7:0] ram [0:2047];
    logic [7:0] ram_rd_data;
    logic [10:0] ram_addr;
    // 2KB covers both: sngkace needs all of it (0x7800-0x7FFF), gunbird only
    // the low 512 bytes (0x8000-0x81FF). Both bases are aligned to their own
    // offset width, so the low address bits index directly with no subtraction.
    assign ram_addr = board_gunbird ? {2'b00, a[8:0]} : a[10:0];
    always_ff @(posedge clk) ram_rd_data <= ram[ram_addr];

    // ---- I/O decode ----
    logic io_ym, io_bank, io_latch_rd, io_latch_ack, io_wave;
    assign io_ym        = board_sh404   ? ((a[7:0] >= 8'h08) && (a[7:0] <= 8'h0B))
                        : board_gunbird ? ((a[7:0] >= 8'h04) && (a[7:0] <= 8'h07))
                                        : (a[7:0] <= 8'h03);
    // SH404's OPL4 wave ports; unimplemented, reads return "ready".
    // Writes there (and to 0x02/0x03, nop'd in MAME) fall through
    // undecoded and are ignored.
    assign io_wave      = board_sh404 && ((a[7:0] == 8'h0C) || (a[7:0] == 8'h0D));
    assign io_bank      = (board_gunbird | board_sh404) ? (a[7:0] == 8'h00) : (a[7:0] == 8'h04);
    assign io_latch_rd  = board_sh404 ? (a[7:0] == 8'h10) : (a[7:0] == 8'h08);
    assign io_latch_ack = board_sh404 ? (a[7:0] == 8'h18) : (a[7:0] == 8'h0C);

    logic io_active_rd, io_active_wr;
    assign io_active_rd = (iorq_n == 1'b0) && (rd_n == 1'b0);
    assign io_active_wr = (iorq_n == 1'b0) && (wr_n == 1'b0);

    assign ym_cs   = io_ym;
    assign ym_addr = a[1:0];
    assign ym_rd    = io_ym && io_active_rd;
    assign ym_wr    = io_ym && io_active_wr;
    assign ym_dout = d_out;

    // ---- sound latch ----
    logic [7:0] latch_reg;
    logic         latch_pending;
    assign nmi_n        = latch_pending ? 1'b0 : 1'b1;
    assign nmi_pending = latch_pending;
`ifdef DEBUG_ISSP
    assign dbg_latch_ack_event = io_active_wr && io_latch_ack;
`endif

    // ---- read data mux (combinational, matches T80's DI expectation) ----
    logic mem_active_rd;
    assign mem_active_rd = (mreq_n == 1'b0) && (rd_n == 1'b0);

    // is_rom_read: any active MREQ read that isn't RAM -- covers both the
    // fixed and banked ROM regions identically, matching rom_addr's own
    // uniform {bank_or_00, a[14:0]} treatment of both.
    logic is_rom_read;
    assign is_rom_read = mem_active_rd && !is_ram;

    // declared here (used by the di mux below); logic lives with the WAIT_n
    // section at the bottom of the module
    logic        rom_done;
    logic [7:0] rom_data_hold;

    always_comb begin
        if (mem_active_rd) begin
            if (is_ram)          di = ram_rd_data;
            else                    di = rom_data_hold;   // fixed or banked ROM (held, see rom_done)
        end else if (io_active_rd) begin
            if (io_ym)               di = ym_din;
            else if (io_wave)       di = 8'h00;       // OPL4 wave port stub: "ready"
            else if (io_latch_rd)  di = latch_reg;
            else                     di = 8'hFF;       // unmapped I/O read
        end else begin
            di = 8'hFF;
        end
    end

    // ---- writes (RAM, bank register, latch ack) ----
    logic mem_active_wr;
    assign mem_active_wr = (mreq_n == 1'b0) && (wr_n == 1'b0);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bank          <= 2'd0;
            latch_pending <= 1'b0;
            latch_reg     <= 8'd0;
        end else begin
            if (mem_active_wr && is_ram) ram[ram_addr] <= d_out;

            // sngkace takes data&0x03; gunbird/btlkroad take (data>>4)&0x03.
            if (io_active_wr && io_bank) bank <= board_gunbird ? d_out[5:4] : d_out[1:0];
            if (io_active_wr && io_latch_ack) latch_pending <= 1'b0;

            // main-CPU side: a new command byte latches and raises NMI,
            // regardless of what the sound CPU is doing this same cycle
            if (latch_write) begin
                latch_reg     <= latch_data;
                latch_pending <= 1'b1;
            end
        end
    end

    // ---- WAIT_n generation ----
    // RAM/I/O/writes: unchanged fixed one-wait-cycle scheme, explicitly
    // excluding rom reads (`!is_rom_read`) so the two schemes never
    // overlap or fight over wait_n for the same access.
    logic access_started;

    wire access_now        = (mreq_n == 1'b0 || iorq_n == 1'b0) && (rd_n == 1'b0 || wr_n == 1'b0);
    wire access_now_nonrom = access_now && !is_rom_read;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            access_started <= 1'b0;
        end else begin
            access_started <= access_now_nonrom;
        end
    end

    // ROM reads: real req/valid handshake. rom_pending is a level (set the
    // cycle a fresh is_rom_read window opens, cleared the cycle rom_valid
    // arrives) -- see this module's header for why this, not a same-cycle
    // edge-detector, is what makes back-to-back ROM-read M-cycles within
    // one instruction (e.g. LD A,(nn)'s two operand fetches followed by
    // its own memory read) safe.
    logic rom_pending;

    // !rom_done in both the request condition and the pending set: once the
    // response for this M-cycle has arrived (rom_done), no further request
    // may be issued until the M-cycle ends. Without it, rom_pending clears
    // on rom_valid while is_rom_read is still high for the rest of the
    // CLKEN-stretched T-state (~21 clk), so `is_rom_read && !rom_pending`
    // came true AGAIN and fired a SPURIOUS second request for the same
    // address every single fetch. Consequences, reproduced with the real
    // SDRAM transport (tb_sound_irq_sdram.sv): rom_pending re-set by the
    // spurious pulse with no transaction bound to it -> permanent WAIT
    // stall within the first few fetches; and on the deployed build the
    // spurious response could land across the M-cycle boundary and poison
    // the NEXT fetch with stale data. Invisible with CLKEN=1 (is_rom_read
    // dropped the cycle after rom_valid -- no window) and with the
    // fixed-5-cycle behavioral ROM model (response always landed inside
    // the same M-cycle) -- the latency-fidelity lesson a third time.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_pending <= 1'b0;
        end else begin
            if (is_rom_read && !rom_pending && !rom_done) rom_pending <= 1'b1;
            else if (rom_valid)                              rom_pending <= 1'b0;
        end
    end

    assign rom_req = is_rom_read && !rom_pending && !rom_done;

    // rom_done / rom_data_hold: stretch the 1-clk rom_valid pulse into a
    // level the CLKEN-gated CPU cannot miss. With CLKEN=cen_4m the T80
    // samples WAIT_n only on enable ticks (~every 21 clk); rom_valid's
    // single-cycle pulse would land between ticks and never be seen --
    // the exact same class of handshake-vs-consumer-cadence bug as the
    // tilemap gfxrom_req fix (docs/TILEMAP_BUG.md) and the documented
    // "one-cycle assertion is missed on nearly every access" lesson
    // (docs/LESSONS_LEARNED.md). Held until the M-cycle ends
    // (is_rom_read deasserts), then cleared; the data is latched alongside
    // so di stays stable for the whole stretched window. The Z80 never
    // abandons an M-cycle mid-flight, so a held response can never be
    // consumed by a different access than the one that requested it.
    // (rom_done/rom_data_hold declared up by is_rom_read, used by di mux.)
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_done       <= 1'b0;
            rom_data_hold <= 8'd0;
        end else begin
            if (rom_valid) begin
                rom_done       <= 1'b1;
                rom_data_hold <= rom_data;
            end else if (!is_rom_read) begin
                rom_done <= 1'b0;
            end
        end
    end

    assign wait_n = is_rom_read        ? rom_done
                   : access_now_nonrom ? access_started
                   : 1'b1;

endmodule
