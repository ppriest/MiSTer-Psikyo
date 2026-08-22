`timescale 1ns/1ps
// Full-chain functional test for rtl/psikyo_top.sv: the SAME CPU program
// tb_psikyo_core.sv used (sim/psikyo_core_tb/test_video.s), but loaded
// through the REAL HPS ioctl_download path into the REAL SDRAM backend
// (rtl/memory/psikyo_sdram_top.sv, sdram_chip_model.sv) rather than a
// directly-poked ROM array -- the strongest available proof that
// rtl/psikyo_core.sv and rtl/memory/psikyo_sdram_top.sv are correctly
// wired to each other end to end (the actual point of rtl/psikyo_top.sv).
//
// Downloads: the reset vectors (SP=0x00FFFFFC, PC=0x00000008, same
// convention test_video.s's own header documents) at MAINCPU_BASE+0..7,
// test_video.bin's 30 program bytes at MAINCPU_BASE+8 (matching its own
// `org $8`), and 8 zero bytes at TILES_BASE+0..7 so layer 0's origin-tile
// gfxrom fetch returns defined (not X) data -- sprites are never enabled
// by this program, so no sprite-side ROM content is needed (matches
// tb_psikyo_core.sv's own scope). Held in reset throughout the download,
// matching real MiSTer core sequencing (core held in reset while HPS
// loads ROM content).
//
// **KNOWN OPEN ISSUE, committed deliberately still failing as reproducible
// evidence (same posture docs/ROADMAP.md's DDRAM-throughput test used) --
// do not loosen this test's checks to force a pass; find the real bug
// instead.** This test PASSED cleanly before rtl/psikyo_top.sv gained the
// sound CPU (rtl/sound/sound_cpu_sngkace.sv), which now contends with
// maincpu for the same Port 2 SDRAM arbiter. With that contention live,
// maincpu's SDRAM read granule capture (rtl/memory/sdram/sdram.sv's
// `dout[15:0/31:16/...] <= SDRAM_DQ`) intermittently captures X, even
// though the arbiter's own astate/sel show one cleanly-serialized
// transaction throughout with no overlap at the arbiter level -- the
// corruption is happening below the arbiter, inside sdram.sv/the SDR
// timing model itself. Root cause not yet found; suspected a real SDR
// SDRAM timing constraint (e.g. tRP, row precharge-to-activate) that
// single-client testing (sim/sdram_arbiter5_tb/, sim/port2_sdram_tb/)
// never stressed, since sdram.sv issues no explicit PRECHARGE and relies
// entirely on auto-precharge with zero enforced gap between two clients'
// back-to-back transactions -- but this is a hypothesis, not confirmed.
// sim/psikyo_top_tb/tb_psikyo_top_sound_smoke.sv still passes (the sound
// CPU wiring itself elaborates and runs correctly with synthetic all-zero
// ROM content, which doesn't happen to trigger this contention pattern).
module tb_psikyo_top;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;
    logic ce_pix = 1'b1;

    localparam logic [24:0] MAINCPU_BASE = 25'h0000000;
    localparam logic [24:0] TILES_BASE    = 25'h0A40000;

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

    psikyo_top dut (
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

    logic [7:0] prog [0:29];
    initial $readmemh("test_video_bytes.hex", prog);

    int errors = 0;
    int match_count = 0;
    int match_hcnt, match_vcnt;

    // KNOWN OPEN ISSUE (see this file's header): once the sound CPU
    // (rtl/sound/sound_cpu_sngkace.sv) started contending for the same
    // Port 2 SDRAM arbiter maincpu uses, this test began failing --
    // maincpu's SDRAM read granule capture (rtl/memory/sdram/sdram.sv's
    // `dout[15:0/31:16/...] <= SDRAM_DQ`) intermittently captures X while
    // the OTHER client's request is simultaneously pending, even though
    // the arbiter's own astate/sel show a single, cleanly-serialized
    // transaction throughout (no overlap at the arbiter level). Root cause
    // not yet found -- suspected a real SDR SDRAM timing constraint
    // (e.g. tRP, row precharge-to-activate) that single-client testing
    // never stressed, given sdram.sv issues no explicit PRECHARGE and
    // relies entirely on auto-precharge with zero enforced gap between
    // back-to-back transactions, but this is not confirmed. This monitor
    // flags the failure the moment it reproduces, for whoever picks this
    // back up.
    // Bails out immediately once the known issue reproduces, rather than
    // letting the run continue toward the same memory-exhaustion crash
    // rtl/cpu/tg68k/PROVENANCE.md's own investigation hit under sustained
    // X propagation (real, observed here too if this monitor doesn't stop
    // the run early) -- every future run of this test fails fast and
    // clearly instead of hanging for minutes before crashing ModelSim.
    always @(posedge clk) begin
        if (dut.u_core.u_cpu.rom_valid && $isunknown(dut.u_core.u_cpu.rom_data)) begin
            $display("FAIL: KNOWN ISSUE reproduced at t=%0t -- maincpu ROM read returned X (cpu_rom_addr=%h), see this file's header",
                       $time, dut.u_core.u_cpu.rom_addr);
            $finish;
        end
    end

    // Same do/while fix sim/psikyo_sdram_top_tb/tb_psikyo_sdram_top.sv
    // found necessary -- see that testbench's header for the race this
    // avoids.
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
        ce_pix = 1'b1;
        ioctl_download = 0; ioctl_index = 0; ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0;
        p1p2_in = 32'hFFFFFFFF; dsw_in = 32'hFFFFFFFF; coin_in = 32'hFFFFFFFF;

        // Zero the WHOLE chip model up front, not just the bytes this test
        // explicitly downloads. sim/psikyo_core_tb/tb_psikyo_core.sv's own
        // ROM model zero-initializes its full array for the same reason:
        // TG68K.C's internal prefetch pipeline can genuinely fetch a word
        // or two past the last instruction actually executed (speculative
        // ahead-of-PC fetch, not necessarily committed), and reading X from
        // never-written SDRAM content there reproduces the exact
        // uninitialized-signal crash rtl/cpu/tg68k/PROVENANCE.md documents
        // -- found the hard way here (SIGSEGV at t=177015ns) before adding
        // this. Not a new bug in maincpu.sv/psikyo_sdram_top.sv: every
        // address this test's program actually touches is still explicitly
        // downloaded below: this only backstops addresses outside that
        // program's real footprint.
        for (int i = 0; i < 524288; i++) chip.mem[i] = 16'h0000;

        repeat (5) @(posedge clk);

        // Release the plain hardware reset BEFORE downloading -- real
        // MiSTer sequencing, and load-bearing here: rtl/psikyo_top.sv's
        // SDRAM backend (psikyo_sdram_top.sv) must be out of reset to
        // receive the download at all (a first version of this test held
        // `reset` through the whole download, which -- before
        // rtl/psikyo_top.sv split the core/SDRAM reset domains -- silently
        // discarded every downloaded byte; see that module's header for
        // the fix). psikyo_core.sv stays quiescent regardless, via
        // rtl/psikyo_top.sv's `core_reset = reset | ioctl_download`.
        reset = 0;

        ioctl_download = 1;
        dl_write_byte(MAINCPU_BASE + 25'd0, 8'h00);
        dl_write_byte(MAINCPU_BASE + 25'd1, 8'hFF);
        dl_write_byte(MAINCPU_BASE + 25'd2, 8'hFF);
        dl_write_byte(MAINCPU_BASE + 25'd3, 8'hFC);
        dl_write_byte(MAINCPU_BASE + 25'd4, 8'h00);
        dl_write_byte(MAINCPU_BASE + 25'd5, 8'h00);
        dl_write_byte(MAINCPU_BASE + 25'd6, 8'h00);
        dl_write_byte(MAINCPU_BASE + 25'd7, 8'h08);
        for (int i = 0; i < 30; i++) dl_write_byte(MAINCPU_BASE + 25'd8 + i[24:0], prog[i]);
        for (int i = 0; i < 8; i++) dl_write_byte(TILES_BASE + i[24:0], 8'h00);
        ioctl_download = 0;
        repeat (10) @(posedge clk);

        // core_reset now drops on its own since ioctl_download is 0 and
        // reset was already released before the download. Real SDRAM fetch
        // latency (~15-20 cycles/word via the narrow bridge vs. the
        // earlier direct-array stub's fixed 5) -- give the ~15-instruction
        // program comfortable margin, then 2 full frames before sampling,
        // same structure as sim/psikyo_core_tb/tb_psikyo_core.sv.
        repeat (2 * FRAME_CYCLES) @(posedge clk);

        $display("CHECK vram0[0]=%h (expect 0000) palette[0x800]=%h (expect 1234) vregs_ctrl_l0=%h (expect 0001)",
                   dut.u_core.u_vram0.mem[0], dut.u_core.u_palette.mem[12'h800], dut.u_core.u_vregs.u_ram_l0.mem[13'h209]);
        $display("CHECK l0_enable=%b l0_transpen_sel=%b", dut.u_core.l0_enable, dut.u_core.l0_transpen_sel);

        for (int i = 0; i < FRAME_CYCLES; i++) begin
            @(posedge clk);
            #1;
            if (!hblank && !vblank && hcnt < 9'd32 && vcnt < 9'd32) begin
                if (rgb === 15'h1234) begin
                    match_count++;
                    match_hcnt = hcnt;
                    match_vcnt = vcnt;
                end
            end
        end

        if (match_count > 0) begin
            $display("PASS: rgb=0x1234 observed %0d time(s) (e.g. hcnt=%0d vcnt=%0d) -- psikyo_core.sv <-> psikyo_sdram_top.sv wiring verified end to end through the real HPS download path",
                       match_count, match_hcnt, match_vcnt);
        end else begin
            errors++;
            $display("FAIL: expected rgb=0x1234 was never observed in the tile-origin window");
        end

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

    initial begin
        #40_000_000; // watchdog
        $display("FAIL: watchdog timeout, simulation did not finish");
        $finish;
    end

endmodule
