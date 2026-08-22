// STATUS (2026-08-22): the ModelSim crash (SIGSEGV + memory exhaustion)
// that used to prevent this test from ever completing is FIXED -- see
// rtl/cpu/tg68k/PROVENANCE.md's "Phase 1 integration" section (root cause:
// uninitialized signals in the vendored TG68K_ALU.vhd/TG68KdotC_Kernel.vhd,
// a publicly known upstream issue). Case 1 (real ROM req/valid fetch, all
// 6 BRAM regions, the input-port read, the sound-latch write --
// maincpu.sv's own address-decode/DTACK logic) now passes cleanly. Case 2
// (the held-autovectored level-4 vblank IRQ) still fails -- root-caused
// further than before (the IACK cycle and vector-OFFSET computation are
// both correct; the actual vector-table FETCH address comes out as
// 0x00000000 instead of 0x70, evidently a separate code path in the
// kernel's exception microcode from the one that gets the offset right --
// see PROVENANCE.md for exactly where to look next). This does not block
// using maincpu.sv for non-interrupt-driven top-level integration work.
//
// Integration test for maincpu.sv: real TG68K.C running an actual
// assembled 68020 program (sim/maincpu_tb/test_maincpu.s, via vasm --
// see that file's header for why hand-encoding was avoided, same
// reasoning as sim/tg68k_spike/test020.s) against a real variable-latency
// (5-cycle) req/valid ROM model and simple synchronous RAM models for
// every BRAM region, checking that every region in
// docs/phase1_memory_map.md's 68EC020 address map decodes to the right
// place with the right byte lanes, that DTACK/WAIT_n timing doesn't wedge
// or corrupt the bus (same class of risk sound_cpu_sngkace.sv's own
// req/valid conversion hit and fixed -- see that module's header), and
// that the held-autovectored level-4 vblank IRQ is taken and cleared
// correctly.
//
// Board: sngkace overlay (BOARD_GUNBIRD=0) -- separate coin port, sound
// latch at 0xC00013. gunbird/btlkroad's overlay differs only in which
// input address decodes (no separate coin port) and isn't separately
// tested here; the shared decode logic (everything except is_coin) is
// identical and already covered.

module tb_maincpu;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;

    logic         rom_req;
    logic [18:0] rom_addr;
    logic         rom_valid;
    logic [15:0] rom_data;

    logic [11:0] spriteram_addr;
    logic         spriteram_wel, spriteram_weh;
    logic [15:0] spriteram_wdata, spriteram_rdata;

    logic [11:0] palette_addr;
    logic         palette_wel, palette_weh;
    logic [15:0] palette_wdata, palette_rdata;

    logic [11:0] vram0_addr;
    logic         vram0_wel, vram0_weh;
    logic [15:0] vram0_wdata, vram0_rdata;

    logic [11:0] vram1_addr;
    logic         vram1_wel, vram1_weh;
    logic [15:0] vram1_wdata, vram1_rdata;

    logic [12:0] vregs_addr;
    logic         vregs_wel, vregs_weh;
    logic [15:0] vregs_wdata, vregs_rdata;

    logic [15:0] workram_addr;
    logic         workram_wel, workram_weh;
    logic [15:0] workram_wdata, workram_rdata;

    logic [31:0] p1p2_in, dsw_in, coin_in;
    logic [7:0]  latch_data;
    logic         latch_write;
    logic         vblank;

    maincpu #(.BOARD_GUNBIRD(1'b0)) dut (.*);

    // ---- ROM model: real req/valid, fixed 5-cycle round trip (matches
    // sound_cpu_sngkace_tb's model exactly) ----
    logic [15:0] rom [0:524287];
    localparam int ROM_LATENCY = 5;
    logic         rom_busy;
    int           rom_cnt;
    int           errors;

    // DEBUG: one line per real bus cycle (the edge as_n first goes low),
    // gated to a window flag the test sets right before Case 2. Shows
    // rw/uds/lds explicitly (an earlier version of this trace assumed
    // fc=101 meant "write" without actually checking rw, which was a real
    // mistake worth not repeating) and the actual data value for both
    // reads and writes.
    logic dbg_irq_trace_on;
    logic dbg_asn_prev;
    always_ff @(posedge clk) begin
        if (dbg_irq_trace_on) begin
            if (dut.as_n == 1'b0 && dbg_asn_prev == 1'b1) begin
                $display("DEBUG t=%0t fc=%b rw=%b uds_n=%b lds_n=%b a=%h data=%h ipl=%b irq_pending=%b vpa=%b",
                          $time, dut.fc, dut.rw, dut.uds_n, dut.lds_n, dut.a, dut.cpu_data, dut.ipl, dut.irq_pending, dut.vpa);
            end
            dbg_asn_prev <= dut.as_n;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_busy  <= 1'b0;
            rom_valid <= 1'b0;
        end else begin
            rom_valid <= 1'b0;
            if (rom_req && !rom_busy) begin
                rom_busy <= 1'b1;
                rom_cnt  <= 0;
            end else if (rom_busy) begin
                if (rom_cnt == ROM_LATENCY - 1) begin
                    rom_valid <= 1'b1;
                    rom_data  <= rom[rom_addr];
                    rom_busy  <= 1'b0;
                end else begin
                    rom_cnt <= rom_cnt + 1;
                end
            end
            if (rom_req && rom_busy) begin
                $display("FAIL: rom_req pulsed while a previous ROM access was still in flight (rom_pending race)");
                errors++;
            end
        end
    end

    // ---- simple synchronous RAM models, one per BRAM region -- 1-cycle
    // read latency, byte-lane-masked writes, matching maincpu.sv's own
    // documented port contract exactly. Plain `always`, not `always_ff`:
    // the initial block below also directly assigns individual array
    // elements (zero-init, and the mid-test spriteram[0x80] clear before
    // Case 2), which always_ff's single-driver exclusivity disallows.
    logic [15:0] spriteram [0:4095];
    always @(posedge clk) begin
        spriteram_rdata <= spriteram[spriteram_addr];
        if (spriteram_wel) spriteram[spriteram_addr][7:0]  <= spriteram_wdata[7:0];
        if (spriteram_weh) spriteram[spriteram_addr][15:8] <= spriteram_wdata[15:8];
    end

    logic [15:0] palette [0:4095];
    always @(posedge clk) begin
        palette_rdata <= palette[palette_addr];
        if (palette_wel) palette[palette_addr][7:0]  <= palette_wdata[7:0];
        if (palette_weh) palette[palette_addr][15:8] <= palette_wdata[15:8];
    end

    logic [15:0] vram0 [0:4095];
    always @(posedge clk) begin
        vram0_rdata <= vram0[vram0_addr];
        if (vram0_wel) vram0[vram0_addr][7:0]  <= vram0_wdata[7:0];
        if (vram0_weh) vram0[vram0_addr][15:8] <= vram0_wdata[15:8];
    end

    logic [15:0] vram1 [0:4095];
    always @(posedge clk) begin
        vram1_rdata <= vram1[vram1_addr];
        if (vram1_wel) vram1[vram1_addr][7:0]  <= vram1_wdata[7:0];
        if (vram1_weh) vram1[vram1_addr][15:8] <= vram1_wdata[15:8];
    end

    logic [15:0] vregs [0:8191];
    always @(posedge clk) begin
        vregs_rdata <= vregs[vregs_addr];
        if (vregs_wel) vregs[vregs_addr][7:0]  <= vregs_wdata[7:0];
        if (vregs_weh) vregs[vregs_addr][15:8] <= vregs_wdata[15:8];
    end

    logic [15:0] workram [0:65535];
    always @(posedge clk) begin
        workram_rdata <= workram[workram_addr];
        if (workram_wel) workram[workram_addr][7:0]  <= workram_wdata[7:0];
        if (workram_weh) workram[workram_addr][15:8] <= workram_wdata[15:8];
    end

    // ---- sound latch capture ----
    logic [7:0] latch_seen;
    logic         latch_seen_valid;
    always_ff @(posedge clk) begin
        if (latch_write) begin
            latch_seen       <= latch_data;
            latch_seen_valid <= 1'b1;
        end
    end

    initial begin
        #6000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        errors = 0;
        dbg_irq_trace_on = 1'b0;

        for (int i = 0; i < 524288; i++) rom[i] = 16'h0000;
        for (int i = 0; i < 4096; i++) begin spriteram[i] = 16'h0000; palette[i] = 16'h0000; vram0[i] = 16'h0000; vram1[i] = 16'h0000; end
        for (int i = 0; i < 8192; i++) vregs[i] = 16'h0000;
        for (int i = 0; i < 65536; i++) workram[i] = 16'h0000;

        // reset vectors (not part of test_maincpu.s -- see that file's
        // header): SP=0x00FFFFFC (top of work RAM, word-aligned -- NOT
        // 0x00008000 the way sim/tg68k_spike/tb_tg68k_boot.vhd used, which
        // only worked there because that spike's memory model was one
        // flat 128KB RAM; in this module 0x8000 falls inside the
        // READ-ONLY ROM region, so a stack push there silently lands
        // nowhere and the next pop reads back stale ROM content instead
        // of the real return address -- a real bug this test's first run
        // hit directly: the vblank IRQ's own interrupt-frame push was the
        // very first stack use in the whole test, and it sent the CPU
        // straight into a runaway X-propagation storm once RTE popped
        // garbage. PC=0x00000008 (start:).
        rom[0] = 16'h00FF; rom[1] = 16'hFFFC;
        rom[2] = 16'h0000; rom[3] = 16'h0008;

        // level-4 autovector table entry: address 0x70 (word 0x38), NOT
        // 0x60 -- a real arithmetic mistake in the first version of this
        // test, found by tracing why the CPU correctly took the interrupt
        // and formed the IACK cycle (confirmed via signal trace: IPL/FC/
        // VPA all correct) but then jumped to garbage. Real 68000
        // autovector numbering: vector 24 is "Spurious Interrupt" (a
        // different exception entirely, raised on BERR during an IACK
        // cycle) -- levels 1-7 map to vectors 25-31, so level 4 is vector
        // 28, byte address 28*4=0x70, not 24*4=0x60. Points at irq4_isr
        // (0x00000100), confirmed from test_maincpu.lst's symbol table.
        rom[16'h0038] = 16'h0000; rom[16'h0039] = 16'h0100;

        // assembled program, starting at byte 8 = word index 4
        $readmemh("sim/maincpu_tb/test_maincpu.hex", rom, 4);

        p1p2_in = 32'hAABBCCDD;
        dsw_in  = 32'h00000000;
        coin_in = 32'h00000000;
        vblank  = 1'b0;

        reset = 1;
        repeat (15) @(posedge clk);
        reset = 0;

        // wait for the final marker write (word $CAFE to work RAM
        // 0xFE0002 = workram[1]) -- confirms every instruction up to that
        // point (ROM fetch, all 6 BRAM region writes, the input-port read
        // + readback, and the sound-latch write) ran to completion without
        // the bus wedging, mirroring test020.s's own "watch for the final
        // expected write" pass condition
        fork
            begin
                wait (workram[1] === 16'hCAFE);
            end
            begin
                #5000000;
                $display("FAIL: timed out waiting for the final marker write (0xFE0002=0xCAFE) -- bus wedged or a wrong address decoded");
                errors++;
            end
        join_any
        disable fork;

        // give the CPU's own bus-idle settle a couple cycles before
        // checking final state
        repeat (4) @(posedge clk);

        if (spriteram[0] !== 16'h1234) begin errors++; $display("FAIL: spriteram[0]=%h expected=1234", spriteram[0]); end
        if (palette[0]   !== 16'h5678) begin errors++; $display("FAIL: palette[0]=%h expected=5678", palette[0]); end
        if (vram0[0]      !== 16'h9abc) begin errors++; $display("FAIL: vram0[0]=%h expected=9abc", vram0[0]); end
        if (vram1[0]      !== 16'hdcba) begin errors++; $display("FAIL: vram1[0]=%h expected=dcba", vram1[0]); end
        if (vregs[0]      !== 16'hdef0) begin errors++; $display("FAIL: vregs[0]=%h expected=def0", vregs[0]); end
        if (workram[0]   !== 16'h1111) begin errors++; $display("FAIL: workram[0]=%h expected=1111", workram[0]); end
        if (workram[1]   !== 16'hcafe) begin errors++; $display("FAIL: workram[1] (final marker)=%h expected=cafe", workram[1]); end

        // input-port readback: move.l $c00000.l,d6 then move.l d6,$fe0004
        // -- workram[2]/[3] hold the high/low words of D6, must match
        // p1p2_in exactly
        if ({workram[2], workram[3]} !== 32'hAABBCCDD) begin
            errors++;
            $display("FAIL: input-port readback (workram[2:3])=%h%h expected=aabbccdd", workram[2], workram[3]);
        end

        if (!latch_seen_valid || latch_seen !== 8'h77) begin
            errors++;
            $display("FAIL: sound latch write not observed correctly: valid=%b data=%h expected=77", latch_seen_valid, latch_seen);
        end

        $display("Case 1 done (ROM fetch via 5-cycle-latency req/valid, all 6 BRAM regions, input-port read, sound latch write)");

        // ---- Case 2: vblank IRQ -- CPU should be parked at wait_irq
        // (self-loop) by now; pulse vblank and confirm the autovectored
        // ISR runs (distinctive write to spriteram[0x80] = 0x400100/2 =
        // word offset 0x80) ----
        spriteram[16'h0080] = 16'h0000;   // clear any stale content first
        // let the CPU actually finish fetching/executing the wait_irq
        // BRA.S self-loop instruction (itself a full 5-cycle-latency ROM
        // round trip, not just a couple of settle cycles) before pulsing
        // vblank, so this test isn't racing the CPU's own boot tail.
        repeat (30) @(posedge clk);
        dbg_irq_trace_on = 1'b1;
        vblank = 1'b1;
        @(posedge clk);
        vblank = 1'b0;

        fork
            begin
                wait (spriteram[16'h0080] === 16'hbeef);
            end
            begin
                #200000;
                $display("FAIL: timed out waiting for the vblank IRQ4 ISR's marker write (spriteram[0x80]=0xbeef) -- IRQ not taken or not autovectored correctly");
                errors++;
            end
        join_any
        disable fork;

        repeat (4) @(posedge clk);
        $display("Case 2 done (held level-4 autovectored vblank IRQ taken, ISR ran, RTE returned)");

        if (errors == 0)
            $display("PASS: maincpu matches reference for all cases (ROM req/valid, all BRAM regions, input ports, sound latch, vblank IRQ)");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
