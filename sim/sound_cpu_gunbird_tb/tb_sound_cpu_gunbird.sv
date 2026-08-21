// Checks sound_cpu_gunbird's address decode / banking / WAIT_n generation
// and the sound-latch/NMI handshake, against a synchronous 128KB ROM model
// (1-cycle read latency, matching every other BRAM interface convention in
// this project). Mirrors sound_cpu_sngkace_tb's structure (two separate
// scenarios, same reasoning for keeping them separate -- see that
// testbench's header), adjusted for gunbird's different memory map, RAM
// size, I/O port layout, and bank-select shift.
//
// Scenario 1 (straight-line, NMI never fires): exercises fixed-ROM fetch,
// a RAM write (0x8000, gunbird's RAM base -- different from sngkace's
// 0x7800), a bank-register write via port 0x00 with the (data>>4)&0x03
// shift (data=0x20 -> bank=2, same target bank as sngkace's test for an
// easy A/B), and a banked-ROM read at 0x8200 (the first banked address --
// confirms the {bank,addr[14:0]} formula holds right at the 0x8200
// boundary, not just somewhere in the middle of the window), echoed via
// the YM stub port (now at 0x04, not 0x00 -- ports moved vs sngkace).
//   0000: 3E 55        LD A,0x55
//   0002: 32 00 80     LD (0x8000),A      -- RAM write
//   0005: 3E 20        LD A,0x20
//   0007: D3 00        OUT (0x00),A       -- bank = (0x20>>4)&3 = 2
//   0009: 3A 00 82     LD A,(0x8200)      -- banked ROM read, first banked byte
//   000C: D3 04        OUT (0x04),A       -- echo to YM stub port (observable)
//   000E: 76           HALT
//
// Scenario 2 (NMI handshake): identical shape to sngkace's, only the echo
// port moves (0x04, since 0x00 is now the bank register, not YM).
//   0000: 76           HALT
//   0066: DB 08        IN A,(0x08)        -- read the latch
//   0068: D3 04        OUT (0x04),A       -- echo it (observable)
//   006A: D3 0C        OUT (0x0C),A       -- ack (clears NMI)
//   006C: ED 45        RETN

module tb_sound_cpu_gunbird;

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

    sound_cpu_gunbird dut (.*);

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
        rom[16'h0002] = 8'h32; rom[16'h0003] = 8'h00; rom[16'h0004] = 8'h80;
        rom[16'h0005] = 8'h3E; rom[16'h0006] = 8'h20;
        rom[16'h0007] = 8'hD3; rom[16'h0008] = 8'h00;
        rom[16'h0009] = 8'h3A; rom[16'h000A] = 8'h00; rom[16'h000B] = 8'h82;
        rom[16'h000C] = 8'hD3; rom[16'h000D] = 8'h04;
        rom[16'h000E] = 8'h76;
        // physical 0x10200 (bank 2, offset 0x200 -- {bank,addr[14:0]} for
        // addr=0x8200) -- what the banked read should return
        rom[17'h10200] = 8'hC7;

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
        if (ym_write_count < 1 || ym_writes[0] !== 8'hC7) begin
            errors++;
            $display("FAIL(s1) YM stub write: count=%0d first=%h expected first=C7", ym_write_count, ym_writes[0]);
        end
        if (dut.halt_n !== 1'b0) begin
            errors++;
            $display("FAIL(s1) core did not reach HALT");
        end
        $display("Scenario 1 done (fixed ROM fetch, RAM write, bank switch w/ >>4 shift, banked ROM read at 0x8200 boundary)");

        // ---- Scenario 2 ----
        for (int i = 0; i < 131072; i++) rom[i] = 8'h00;
        rom[16'h0000] = 8'h76;   // HALT immediately
        rom[16'h0066] = 8'hDB; rom[16'h0067] = 8'h08;   // IN A,(0x08)
        rom[16'h0068] = 8'hD3; rom[16'h0069] = 8'h04;   // OUT (0x04),A
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
            $display("PASS: sound_cpu_gunbird matches reference for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
