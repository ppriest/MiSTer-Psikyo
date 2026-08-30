`timescale 1ns/1ps
// Real functional test for the sound CPU's SDRAM path through
// rtl/psikyo_top.sv -- downloads a genuine Z80 program through the actual
// HPS ioctl_download path into the actual SDRAM backend
// (rtl/memory/psikyo_sdram_top.sv), the same proof style
// sim/psikyo_top_tb/tb_psikyo_top.sv already established for maincpu.
//
// The point: docs/ROADMAP.md flagged that sdram_narrow_bridge.sv's
// WORD_BYTES=1 byte-wide fetch was only ASSERTED endianness-safe for the
// Z80 (byte-wide reads have no packing order, unlike maincpu's 16-bit
// fetch, which genuinely needed a byte swap -- see
// rtl/memory/psikyo_sdram_top.sv's u_cpu_bridge comment), never checked
// against a real downloaded program. This is that check.
//
// Reuses sim/sound_cpu_sngkace_tb/tb_sound_cpu_sngkace.sv's own Scenario 1
// program byte-for-byte (see that file's header for the full derivation):
//   0000: 3E 55        LD A,0x55
//   0002: 32 00 78     LD (0x7800),A      -- RAM write
//   0005: 3E 02        LD A,0x02
//   0007: D3 04        OUT (0x04),A       -- bank = 2
//   0009: 3A 00 80     LD A,(0x8000)      -- banked ROM read, physical 0x10000
//   000C: D3 00        OUT (0x00),A       -- echo to YM stub port (observable)
//   000E: 76           HALT
// The one change: physical byte 0x10000 (bank 2's local 0x0000, i.e.
// AUDIOCPU_BASE+0x10000 in the flat SDRAM map) holds a distinctive value
// (0xAB) instead of whatever the isolated testbench used, specifically so
// a byte-order bug -- if one existed -- would show up as a wrong echoed
// value on the observable ym_* bus, exactly like maincpu's own PC-ran-off
// symptom made ITS byte-order bug visible.
module tb_psikyo_top_sound;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;
    logic ce_pix = 1'b1;

    localparam logic [24:0] AUDIOCPU_BASE = 25'h0200000;

    logic         ioctl_download;
    logic [15:0] ioctl_index;
    logic         ioctl_wr;
    logic [24:0] ioctl_addr;
    logic [7:0]  ioctl_dout;
    logic         ioctl_wait;

    logic [31:0] p1p2_in, dsw_in, coin_in;

    logic         ym_cs, ym_rd, ym_wr;
    logic [1:0]  ym_addr;
    logic [7:0]  ym_dout;
    logic [7:0]  ym_din;

    logic [8:0]  hcnt, vcnt;
    logic         hblank, vblank, hsync, vsync;
    logic [14:0] rgb;

    wire [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic         SDRAM_DQML, SDRAM_DQMH;
    logic [1:0]  SDRAM_BA;
    logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

    psikyo_top #(.BOARD_GUNBIRD(1'b0)) dut (
        // SH404 ports tied off (docs/phase2_sh404.md); this TB predates them
        .board_sh404(1'b0), .snd_latch_c00011(1'b0), .mcu_table_absent(1'b0),
        .mcu_table_we(1'b0), .mcu_table_waddr(8'd0), .mcu_table_wdata(8'd0),
        .clk(clk), .ce_pix(ce_pix), .reset(reset), .init(1'b0),
        .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),
        .p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in),
        .ym_cs(ym_cs), .ym_addr(ym_addr), .ym_rd(ym_rd), .ym_wr(ym_wr),
        .ym_dout(ym_dout), .ym_din(ym_din),
        .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
        .hsync(hsync), .vsync(vsync), .rgb(rgb)
    );

    assign ym_din = 8'h00;

    sdram_chip_model chip (
        .clk(clk),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
    );

    int errors = 0;
    logic         echo_seen = 0;
    logic [7:0]  echo_val;

    always @(posedge clk) begin
        if (ym_wr && ym_addr == 2'b00 && !echo_seen) begin
            echo_seen = 1;
            echo_val   = ym_dout;
        end
    end

    task automatic dl_write_byte(input [24:0] addr, input [7:0] data);
        @(posedge clk);
        ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1'b1;
        @(posedge clk);
        ioctl_wr = 1'b0;
        do @(posedge clk); while (ioctl_wait);
    endtask

    localparam int FRAME_CYCLES = 456 * 262;

    initial begin
        reset = 1;
        ioctl_download = 0; ioctl_index = 0; ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0;
        p1p2_in = 32'hFFFFFFFF; dsw_in = 32'hFFFFFFFF; coin_in = 32'hFFFFFFFF;

        // Zero the whole chip model up front -- same reason
        // sim/psikyo_top_tb/tb_psikyo_top.sv's own header documents.
        for (int i = 0; i < 524288; i++) chip.mem[i] = 16'h0000;

        repeat (5) @(posedge clk);
        reset = 0; // release before downloading -- see tb_psikyo_top.sv's header

        ioctl_download = 1;
        dl_write_byte(AUDIOCPU_BASE + 25'h0000, 8'h3E);
        dl_write_byte(AUDIOCPU_BASE + 25'h0001, 8'h55);
        dl_write_byte(AUDIOCPU_BASE + 25'h0002, 8'h32);
        dl_write_byte(AUDIOCPU_BASE + 25'h0003, 8'h00);
        dl_write_byte(AUDIOCPU_BASE + 25'h0004, 8'h78);
        dl_write_byte(AUDIOCPU_BASE + 25'h0005, 8'h3E);
        dl_write_byte(AUDIOCPU_BASE + 25'h0006, 8'h02);
        dl_write_byte(AUDIOCPU_BASE + 25'h0007, 8'hD3);
        dl_write_byte(AUDIOCPU_BASE + 25'h0008, 8'h04);
        dl_write_byte(AUDIOCPU_BASE + 25'h0009, 8'h3A);
        dl_write_byte(AUDIOCPU_BASE + 25'h000A, 8'h00);
        dl_write_byte(AUDIOCPU_BASE + 25'h000B, 8'h80);
        dl_write_byte(AUDIOCPU_BASE + 25'h000C, 8'hD3);
        dl_write_byte(AUDIOCPU_BASE + 25'h000D, 8'h00);
        dl_write_byte(AUDIOCPU_BASE + 25'h000E, 8'h76);
        // bank 2, local 0x0000 -> physical AUDIOCPU_BASE+0x10000
        dl_write_byte(AUDIOCPU_BASE + 25'h10000, 8'hAB);
        ioctl_download = 0;

        // Real SDRAM fetch latency -- give the ~7-instruction program
        // comfortable margin (matches tb_psikyo_top.sv's own reasoning).
        repeat (20000) @(posedge clk);

        if (!echo_seen) begin
            errors++;
            $display("FAIL: OUT (0x00),A (ym_wr, ym_addr=0) never observed -- program did not run to completion");
        end else if (echo_val !== 8'hAB) begin
            errors++;
            $display("FAIL: echoed byte=%h expected=AB -- banked ROM byte-order bug (audiocpu, physical 0x10000)", echo_val);
        end else begin
            $display("PASS: echoed byte=%h -- audiocpu SDRAM path (fixed-region fetch, bank register, banked-region fetch) verified correct through the real HPS download path, no byte-order swap needed for the Z80's byte-wide fetch", echo_val);
        end

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

    initial begin
        #4_000_000; // watchdog
        $display("FAIL: watchdog timeout, simulation did not finish");
        $finish;
    end

endmodule
