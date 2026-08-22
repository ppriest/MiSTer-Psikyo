// Sound CPU subsystem for the gunbird/btlkroad board (LZ8420M, treated as
// Z80-compatible, psikyo.cpp:405-419 as of the current driver) -- T80se +
// address decode + bank register + sound latch/NMI handshake. Battle K-Road
// uses the *exact same* gunbird_map/machine config (confirmed via the
// GAME() driver table, not assumed) -- only its input port bit layout
// differs, which is a MRA/input-mapping concern, not a sound-CPU one, so
// one module covers both games.
//
// This is gunbird's own variant of sound_cpu_sngkace.sv: same overall
// shape (T80se, req/1-cycle-sync ROM/RAM, WAIT_n scheme), different memory
// map, RAM size, I/O port layout, and bank-select shift -- see the memory
// map differences below, all confirmed directly from psikyo.cpp rather
// than assumed to match sngkace.
//
// Memory map (psikyo.cpp gunbird_sound_map):
//   0x0000-0x7FFF  fixed program ROM (32KB -- larger than sngkace's, which
//                  leaves less room split off for RAM, see below)
//   0x8000-0x81FF  RAM (512B, internal to this module -- smaller than
//                  sngkace's 2KB)
//   0x8200-0xFFFF  banked ROM window (0x7E00 = 32,256 bytes -- NOT a power
//                  of two, do not round this up)
//
// Physical ROM is one 128KB (0x20000) image (ROM_REGION "audiocpu").
// m_audiobank->configure_entries(0, 4, base+0x200, 0x8000) -- i.e. each
// bank entry is 0x8000 bytes, starting 0x200 into the physical image, so
// bank N covers physical [0x200+N*0x8000, 0x200+N*0x8000+0x8000). This
// looks like it needs a "+0x200, then -0x8200" adjustment per access, but
// it collapses to the exact same clean concatenation sngkace uses:
// for any addr in [0x8200,0xFFFF], addr[14:0] == addr-0x8000 (since
// addr>=0x8000), and physical = 0x200 + N*0x8000 + (addr-0x8200)
//                              = N*0x8000 + (addr-0x8000)
//                              = N*0x8000 + addr[14:0]
// i.e. rom_addr = {bank, addr[14:0]} -- confirmed algebraically against
// the real configure_entries() call, not assumed to match sngkace's shape
// by coincidence.
//
// I/O map (8-bit) -- note the different layout vs sngkace:
//   0x00       bank select write (`sound_bankswitch_w<4>`, i.e.
//              (data>>4)&0x03 -- different shift than sngkace's `data&0x03`)
//   0x04-0x07  YM2610 (external chip-select bus, same as sngkace -- NOT
//              wired to jt10 yet, jt10 still unverified)
//   0x08       sound latch read
//   0x0C       sound latch acknowledge write (clears NMI)
//
// WAIT_n generation: identical split scheme to sound_cpu_sngkace.sv --
// RAM/I/O/writes keep the fixed one-wait-cycle scheme (this project's
// synchronous 1-cycle BRAM convention), while program ROM reads (fixed
// and banked alike) go through a real req/valid handshake
// (`rom_req`/`rom_valid`), since ROM streaming is meant to eventually
// reach the SDRAM stack (docs/phase1_sdram_map.md), which has variable,
// multi-cycle latency. This is a generic Z80-bus-timing scheme, not board
// specific, so it carries over from sngkace's own (verified, see that
// module's header for the full derivation and the real T80.vhd/T80se.vhd
// mechanism it's built from) conversion rather than being re-derived here
// -- re-verified for THIS module's own memory map/timing in
// sim/sound_cpu_gunbird_tb/, not assumed to match sngkace by association.

module sound_cpu_gunbird (
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

    // YM2610 I/O handoff -- NOT wired to jt10 yet
    output logic         ym_cs,
    output logic [1:0]  ym_addr,
    output logic         ym_rd,
    output logic         ym_wr,
    output logic [7:0]  ym_dout,       // Z80 -> YM2610
    input  logic [7:0]  ym_din         // YM2610 -> Z80
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
        .INT_n(1'b1), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(a), .DI(di), .DO(d_out)
    );

    // ---- address decode ----
    logic is_fixed_rom, is_ram, is_banked;
    assign is_fixed_rom = (a <= 16'h7FFF);
    assign is_ram         = (a >= 16'h8000) && (a <= 16'h81FF);
    assign is_banked      = (a >= 16'h8200);

    // ---- bank register ----
    logic [1:0] bank;

    assign rom_addr = {(is_banked ? bank : 2'b00), a[14:0]};

    // ---- internal RAM (512B) ----
    logic [7:0] ram [0:511];
    logic [7:0] ram_rd_data;
    logic [8:0] ram_addr;
    assign ram_addr = a[8:0];   // a[8:0] spans 0x8000-0x81FF's 9-bit offset directly (0x8000 is 9-bit aligned)
    always_ff @(posedge clk) ram_rd_data <= ram[ram_addr];

    // ---- I/O decode ----
    logic io_bank, io_ym, io_latch_rd, io_latch_ack;
    assign io_bank      = (a[7:0] == 8'h00);
    assign io_ym        = (a[7:0] >= 8'h04) && (a[7:0] <= 8'h07);
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
    assign nmi_n = latch_pending ? 1'b0 : 1'b1;

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

            if (io_active_wr && io_bank) bank <= d_out[5:4];   // (data>>4)&0x03
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
    // arrives) -- see sound_cpu_sngkace.sv's header for why this, not a
    // same-cycle edge-detector, is what makes back-to-back ROM-read
    // M-cycles within one instruction safe.
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
