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
// WAIT_n generation: this project's ROM/RAM is synchronous (1-cycle read
// latency, matching every other BRAM interface in this project), but T80
// expects WAIT_n sampled at T2 to gate the cycle -- inserts exactly one
// wait cycle per access (asserted the cycle an access is first detected,
// released the cycle after) via `access_started`. This exact scheme is
// unverified against T80's real internal T-state timing by reasoning
// alone (Z80 bus timing is easy to get subtly wrong) -- confirmed correct
// by simulation instead (sim/sound_cpu_sngkace_tb/), matching this
// project's standing "verify via simulation, not just derive" practice.

module sound_cpu_sngkace (
    input logic clk,
    input logic reset,

    // external program ROM (128KB physical, 17-bit addr), 1-cycle sync read
    output logic [16:0] rom_addr,
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
    assign nmi_n = latch_pending ? 1'b0 : 1'b1;

    // ---- read data mux (combinational, matches T80's DI expectation) ----
    logic mem_active_rd;
    assign mem_active_rd = (mreq_n == 1'b0) && (rd_n == 1'b0);

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

    // ---- WAIT_n generation: one wait cycle per MREQ/IORQ access ----
    logic access_started;

    wire access_now = (mreq_n == 1'b0 || iorq_n == 1'b0) && (rd_n == 1'b0 || wr_n == 1'b0);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            access_started <= 1'b0;
        end else begin
            access_started <= access_now;
        end
    end

    assign wait_n = access_now ? access_started : 1'b1;

endmodule
