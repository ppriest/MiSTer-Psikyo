`timescale 1ns/1ps
// Unit test for rtl/video/spriteram_dbuf.sv: CPU write/readback on the
// current write-role bank, render-port (dl_addr/at_addr) reads of the
// OTHER (render-role) bank, cross-bank isolation (a write-bank write must
// not appear on the render ports until the NEXT frame_start), and the
// control-word shadow/latch timing, across two full swap cycles so both
// toggle directions are exercised.
module tb_spriteram_dbuf;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;
    logic frame_start;

    logic [11:0] cpu_addr;
    logic         cpu_wel, cpu_weh;
    logic [15:0] cpu_wdata;
    logic [15:0] cpu_rdata;

    logic [11:0] dl_addr;
    logic [15:0] dl_data;
    logic [11:0] at_addr;
    logic [15:0] at_data;

    logic sprites_disable, trans_pen0, trans_pen15;
    logic copy_busy;

    spriteram_dbuf dut (.*);

    int errors = 0;

    task automatic cpu_write(input [11:0] addr, input [15:0] data);
        @(posedge clk);
        cpu_addr = addr; cpu_wdata = data; cpu_wel = 1; cpu_weh = 1;
        @(posedge clk);
        cpu_wel = 0; cpu_weh = 0;
    endtask

    task automatic check16(input [15:0] got, input [15:0] exp, input string name);
        if (got !== exp) begin
            errors++;
            $display("FAIL %s: got=%h expected=%h", name, got, exp);
        end
    endtask

    task automatic pulse_frame_start;
        @(posedge clk);
        frame_start = 1;
        @(posedge clk);
        frame_start = 0;
    endtask

    initial begin
        reset = 1; frame_start = 0;
        cpu_addr = 0; cpu_wel = 0; cpu_weh = 0; cpu_wdata = 0;
        dl_addr = 0; at_addr = 0;
        repeat (2) @(posedge clk);
        reset = 0;

        // -- Phase 1: bank0 write-role, bank1 render-role (post-reset default). --
        cpu_write(12'h010, 16'hAAAA);
        cpu_write(12'hC00, 16'hBBBB);
        cpu_write(12'hFFF, 16'h0005); // disable=1, trans_pen0=1, trans_pen15=0

        @(posedge clk);
        cpu_addr = 12'h010;
        @(posedge clk); #1;
        check16(cpu_rdata, 16'hAAAA, "phase1 CPU readback 0x010");

        pulse_frame_start(); // bank0 -> render, bank1 -> write; ctrl_active <= bank0's shadow
        @(posedge clk);                       // let copying latch (NBA) before sampling
        while (copy_busy) @(posedge clk);     // snapshot COPY takes DEPTH cycles
        @(posedge clk);

        // -- Phase 2: bank1 write-role, bank0 render-role. --
        #1;
        if (sprites_disable !== 1'b1) begin errors++; $display("FAIL phase2 sprites_disable"); end
        if (trans_pen0 !== 1'b1)       begin errors++; $display("FAIL phase2 trans_pen0"); end
        if (trans_pen15 !== 1'b0)      begin errors++; $display("FAIL phase2 trans_pen15"); end

        at_addr = 12'h010; @(posedge clk); #1;
        check16(at_data, 16'hAAAA, "phase2 at_data (bank0, now render)");
        dl_addr = 12'hC00; @(posedge clk); #1;
        check16(dl_data, 16'hBBBB, "phase2 dl_data (bank0, now render)");

        cpu_write(12'h010, 16'hCCCC); // into bank1 (write-role) -- must NOT disturb bank0's render-side value
        cpu_write(12'hFFF, 16'h000C); // disable=0, trans_pen0=1, trans_pen15=1

        @(posedge clk);
        cpu_addr = 12'h010;
        @(posedge clk); #1;
        check16(cpu_rdata, 16'hCCCC, "phase2 CPU readback 0x010 (bank1)");

        // The global enable is LIVE (per the MAME renderer author): the
        // mid-frame control write above must drop sprites_disable NOW,
        // before any frame_start -- while the transparent-pen selects stay
        // frame-LATCHED (still phase-1's 0x0005 values). This pair is the
        // discriminating check: a regression to a latched enable, or to
        // live pens, each fails exactly one of these.
        if (sprites_disable !== 1'b0) begin errors++; $display("FAIL phase2 sprites_disable must be LIVE (mid-frame write ignored)"); end
        if (trans_pen0 !== 1'b1)       begin errors++; $display("FAIL phase2 trans_pen0 must stay LATCHED mid-frame"); end
        if (trans_pen15 !== 1'b0)      begin errors++; $display("FAIL phase2 trans_pen15 must stay LATCHED mid-frame"); end

        // Render ports must still see bank0's OLD value -- the phase-2
        // write into bank1 must not leak across the buffer boundary
        // before the next frame_start.
        at_addr = 12'h010; @(posedge clk); #1;
        check16(at_data, 16'hAAAA, "phase2 at_data unaffected by bank1 write");

        pulse_frame_start(); // bank1 -> render, bank0 -> write; ctrl_active <= bank1's shadow
        @(posedge clk);
        while (copy_busy) @(posedge clk);
        @(posedge clk);

        // -- Phase 3: bank0 write-role, bank1 render-role again. --
        #1;
        if (sprites_disable !== 1'b0) begin errors++; $display("FAIL phase3 sprites_disable"); end
        if (trans_pen0 !== 1'b1)       begin errors++; $display("FAIL phase3 trans_pen0"); end
        if (trans_pen15 !== 1'b1)      begin errors++; $display("FAIL phase3 trans_pen15"); end

        at_addr = 12'h010; @(posedge clk); #1;
        check16(at_data, 16'hCCCC, "phase3 at_data (bank1, now render)");

        cpu_write(12'h020, 16'hDEAD); // into bank0 (write-role again)
        @(posedge clk);
        cpu_addr = 12'h020;
        @(posedge clk); #1;
        check16(cpu_rdata, 16'hDEAD, "phase3 CPU readback 0x020 (bank0)");

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule
