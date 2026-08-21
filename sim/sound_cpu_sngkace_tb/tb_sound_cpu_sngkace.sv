// Checks sound_cpu_sngkace's address decode / banking / WAIT_n generation
// and the sound-latch/NMI handshake, against a synchronous 128KB ROM model
// (1-cycle read latency, matching every other BRAM interface convention in
// this project). Two separate scenarios (separate reset, separate ROM
// content) rather than one combined program: an NMI firing mid-test would
// otherwise interrupt the first scenario's straight-line execution in a way
// that's hard to reason about, so latch/NMI gets its own dedicated,
// deliberately minimal program.
//
// Scenario 1 (straight-line, NMI never fires): exercises fixed-ROM fetch,
// a RAM write, a bank-register write + banked-ROM read (bank 2 -> physical
// 0x10000, confirming the {bank,addr[14:0]} concatenation), and an I/O
// write to the YM stub port so the result is observable from outside the
// DUT (probing dut.ram[] directly for the RAM check, since that's a
// perfectly good testbench-side view of internal state and avoids
// inventing a debug-only port).
//   0000: 3E 55        LD A,0x55
//   0002: 32 00 78     LD (0x7800),A      -- RAM write
//   0005: 3E 02        LD A,0x02
//   0007: D3 04        OUT (0x04),A       -- bank = 2
//   0009: 3A 00 80     LD A,(0x8000)      -- banked ROM read, physical 0x10000
//   000C: D3 00        OUT (0x00),A       -- echo to YM stub port (observable)
//   000E: 76           HALT
//
// Scenario 2 (NMI handshake): HALT immediately, then the testbench pulses
// latch_write externally. Z80 NMI vector is 0x0066 (RETN = ED 45 returns
// from NMI, distinct from a plain RET).
//   0000: 76           HALT
//   0066: DB 08        IN A,(0x08)        -- read the latch
//   0068: D3 00        OUT (0x00),A       -- echo it (observable)
//   006A: D3 0C        OUT (0x0C),A       -- ack (clears NMI)
//   006C: ED 45        RETN

module tb_sound_cpu_sngkace;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;
    logic [16:0] rom_addr;
    logic [7:0]  rom_data;
    logic [7:0]  latch_data;
    logic         latch_write;
    logic         ym_cs;
    logic [1:0]  ym_addr;
    logic         ym_rd, ym_wr;
    logic [7:0]  ym_dout;
    logic [7:0]  ym_din;

    assign ym_din = 8'hAA;   // arbitrary fixed stub response, unused by these tests' reads

    sound_cpu_sngkace dut (.*);

    logic [7:0] rom [0:131071];
    always_ff @(posedge clk) rom_data <= rom[rom_addr];

    // capture every YM stub write as a small FIFO-ish trail (only a few
    // writes ever happen in these tests, so a plain array + count is fine)
    logic [7:0] ym_writes [0:15];
    int          ym_write_count;
    always_ff @(posedge clk) begin
        if (ym_wr) begin
            ym_writes[ym_write_count] <= ym_dout;
            ym_write_count             <= ym_write_count + 1;
        end
    end

    int errors;

    task automatic reset_dut;
        ym_write_count = 0;
        latch_write = 0;
        latch_data  = 8'h00;
        reset = 1;
        @(posedge clk); @(posedge clk);
        reset = 0;
    endtask

    task automatic run_cycles(int n);
        repeat (n) @(posedge clk);
    endtask

    initial begin
        errors = 0;
        for (int i = 0; i < 131072; i++) rom[i] = 8'h00;

        // ---- Scenario 1 ----
        rom[16'h0000] = 8'h3E; rom[16'h0001] = 8'h55;
        rom[16'h0002] = 8'h32; rom[16'h0003] = 8'h00; rom[16'h0004] = 8'h78;
        rom[16'h0005] = 8'h3E; rom[16'h0006] = 8'h02;
        rom[16'h0007] = 8'hD3; rom[16'h0008] = 8'h04;
        rom[16'h0009] = 8'h3A; rom[16'h000A] = 8'h00; rom[16'h000B] = 8'h80;
        rom[16'h000C] = 8'hD3; rom[16'h000D] = 8'h00;
        rom[16'h000E] = 8'h76;
        // physical 0x10000 (bank 2, offset 0) -- what the banked read should return
        rom[17'h10000] = 8'hC3;

        reset_dut();
        run_cycles(300);

        if (dut.ram[0] !== 8'h55) begin
            errors++;
            $display("FAIL(s1) RAM[0]: got=%h expected=55", dut.ram[0]);
        end
        if (dut.bank !== 2'd2) begin
            errors++;
            $display("FAIL(s1) bank register: got=%0d expected=2", dut.bank);
        end
        if (ym_write_count < 1 || ym_writes[0] !== 8'hC3) begin
            errors++;
            $display("FAIL(s1) YM stub write: count=%0d first=%h expected first=C3", ym_write_count, ym_writes[0]);
        end
        if (dut.halt_n !== 1'b0) begin
            errors++;
            $display("FAIL(s1) core did not reach HALT");
        end
        $display("Scenario 1 done (fixed ROM fetch, RAM write, bank switch, banked ROM read)");

        // ---- Scenario 2 ----
        for (int i = 0; i < 131072; i++) rom[i] = 8'h00;
        rom[16'h0000] = 8'h76;   // HALT immediately
        rom[16'h0066] = 8'hDB; rom[16'h0067] = 8'h08;   // IN A,(0x08)
        rom[16'h0068] = 8'hD3; rom[16'h0069] = 8'h00;   // OUT (0x00),A
        rom[16'h006A] = 8'hD3; rom[16'h006B] = 8'h0C;   // OUT (0x0C),A
        rom[16'h006C] = 8'hED; rom[16'h006D] = 8'h45;   // RETN

        reset_dut();
        run_cycles(100);   // let it reach HALT and settle

        if (dut.halt_n !== 1'b0) begin
            errors++;
            $display("FAIL(s2) core did not reach HALT before latch_write");
        end
        if (dut.latch_pending !== 1'b0) begin
            errors++;
            $display("FAIL(s2) latch_pending asserted before any latch_write");
        end

        latch_data  = 8'h77;
        latch_write = 1'b1;
        @(posedge clk);
        latch_write = 1'b0;

        // latch_pending should assert immediately (combinational off the write)
        run_cycles(1);
        if (dut.latch_pending !== 1'b1) begin
            errors++;
            $display("FAIL(s2) latch_pending did not assert after latch_write");
        end

        run_cycles(200);   // let the NMI handler run to completion

        if (ym_write_count < 1 || ym_writes[0] !== 8'h77) begin
            errors++;
            $display("FAIL(s2) NMI handler did not echo the latch value: count=%0d first=%h expected 77",
                      ym_write_count, ym_writes[0]);
        end
        if (dut.latch_pending !== 1'b0) begin
            errors++;
            $display("FAIL(s2) latch_pending not cleared after handler's ack write");
        end
        $display("Scenario 2 done (sound latch write -> NMI -> handler reads/echoes/acks)");

        if (errors == 0)
            $display("PASS: sound_cpu_sngkace matches reference for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
