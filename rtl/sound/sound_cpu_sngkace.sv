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

module sound_cpu_sngkace (
    input logic clk,
    input logic reset,

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
        .RESET_n(~reset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(wait_n),
        .INT_n(ym_irq_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(a), .DI(di), .DO(d_out)
    );

    // ---- address decode ----
    logic is_fixed_rom, is_ram, is_banked;
    assign is_fixed_rom = (a <= 16'h77FF);
    assign is_ram         = (a >= 16'h7800) && (a <= 16'h7FFF);
    assign is_banked      = (a >= 16'h8000);

    // ---- bank register ----
    logic [1:0] bank;

    assign rom_addr = {(is_banked ? bank : 2'b00), a[14:0]};

    // ---- internal RAM (2KB) ----
    logic [7:0] ram [0:2047];
    logic [7:0] ram_rd_data;
    logic [10:0] ram_addr;
    assign ram_addr = a[10:0];   // a[10:0] spans 0x7800-0x7FFF's 11-bit offset directly (a-0x7800 == a[10:0] since 0x7800 is 11-bit aligned)
    always_ff @(posedge clk) ram_rd_data <= ram[ram_addr];

    // ---- I/O decode ----
    logic io_ym, io_bank, io_latch_rd, io_latch_ack;
    assign io_ym        = (a[7:0] <= 8'h03);
    assign io_bank      = (a[7:0] == 8'h04);
    assign io_latch_rd  = (a[7:0] == 8'h08);
    assign io_latch_ack = (a[7:0] == 8'h0C);

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

    // ---- read data mux (combinational, matches T80's DI expectation) ----
    logic mem_active_rd;
    assign mem_active_rd = (mreq_n == 1'b0) && (rd_n == 1'b0);

    // is_rom_read: any active MREQ read that isn't RAM -- covers both the
    // fixed and banked ROM regions identically, matching rom_addr's own
    // uniform {bank_or_00, a[14:0]} treatment of both.
    logic is_rom_read;
    assign is_rom_read = mem_active_rd && !is_ram;

    always_comb begin
        if (mem_active_rd) begin
            if (is_ram)          di = ram_rd_data;
            else                    di = rom_data;   // fixed or banked ROM
        end else if (io_active_rd) begin
            if (io_ym)               di = ym_din;
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

            if (io_active_wr && io_bank) bank <= d_out[1:0];
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

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_pending <= 1'b0;
        end else begin
            if (is_rom_read && !rom_pending) rom_pending <= 1'b1;
            else if (rom_valid)                 rom_pending <= 1'b0;
        end
    end

    assign rom_req = is_rom_read && !rom_pending;

    assign wait_n = is_rom_read        ? rom_valid
                   : access_now_nonrom ? access_started
                   : 1'b1;

endmodule
