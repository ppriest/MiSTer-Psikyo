`timescale 1ns/1ps
// Protocol test for rtl/cpu/s1945_mcu.sv against MAME psikyo.cpp's
// s1945_mcu_* simulation (the module's spec -- docs/phase2_sh404.md).
// Exercises: reset state, table load + 0x11C/0x013 table read, the 0x113
// mode handshake (both branches), 0x010/0x110, read-consume semantics on
// both control[4] settings, table_absent (tengai), and the status toggle.
module tb_s1945_mcu;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;

    logic wr_data, wr_bctrl, wr_control, wr_direction, wr_command;
    logic [7:0] wdata_h, wdata_l;
    logic [7:0] data_byte, control_byte, bctrl;
    logic mcu_status;
    logic rd_consume, rd_status_toggle;
    logic table_absent, table_we;
    logic [7:0] table_waddr, table_wdata;

    s1945_mcu dut (.*);

    int errors = 0;

    task automatic check8(input [7:0] got, input [7:0] exp, input string name);
        if (got !== exp) begin
            errors++;
            $display("FAIL %s: got=%02h expected=%02h", name, got, exp);
        end
    endtask

    // one-cycle byte-register write pulses (UDS/LDS lanes as maincpu drives them)
    task automatic wr(input string reg_name, input [7:0] val);
        @(posedge clk);
        wdata_h = val; wdata_l = val;
        case (reg_name)
            "data":      wr_data      = 1;
            "bctrl":     wr_bctrl     = 1;
            "control":   wr_control   = 1;
            "direction": wr_direction = 1;
            "command":   wr_command   = 1;
        endcase
        @(posedge clk);
        {wr_data, wr_bctrl, wr_control, wr_direction, wr_command} = '0;
        repeat (3) @(posedge clk);   // real bus accesses are many cycles apart
    endtask

    task automatic consume();
        @(posedge clk);
        rd_consume = 1;
        @(posedge clk);
        rd_consume = 0;
        repeat (2) @(posedge clk);
    endtask

    initial begin
        reset = 1;
        {wr_data, wr_bctrl, wr_control, wr_direction, wr_command} = '0;
        wdata_h = 0; wdata_l = 0;
        rd_consume = 0; rd_status_toggle = 0;
        table_absent = 0; table_we = 0; table_waddr = 0; table_wdata = 0;
        repeat (4) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // ---- reset state ----
        check8(control_byte, 8'h0D, "control_byte at reset (latching 0x5 | 0x08)");
        check8(data_byte, 8'hFF, "data_byte at reset (control[4]=1, latching[2]=1 -> not ready)");
        check8(bctrl, 8'h00, "bctrl at reset");

        // ---- load the s1945 table's first four bytes: 00 00 64 AE ----
        @(posedge clk);
        table_we = 1;
        table_waddr = 8'd2; table_wdata = 8'h64; @(posedge clk);
        table_waddr = 8'd3; table_wdata = 8'hAE; @(posedge clk);
        table_we = 0;
        @(posedge clk);

        // ---- table read: 0x11C (set index, dir!=0) then 0x013 (dir==0) ----
        wr("direction", 8'h01);
        wr("data", 8'd3);            // index 3
        wr("command", 8'h1C);        // {1,0x1C} = 0x11C
        check8(control_byte, 8'h0D, "latching=5 after 0x11C");
        wr("direction", 8'h00);
        wr("command", 8'h13);        // {0,0x13} = 0x013: latch1 <= table[3]
        check8(control_byte, 8'h09, "latching=1 after 0x013");
        check8(data_byte, 8'hAE, "table[3] via latch1 (control[4]=1, latching[2]=0)");
        consume();                    // read consumed -> latching[2] set
        check8(data_byte, 8'hFF, "latch1 not ready after consume");
        check8(control_byte, 8'h0D, "latching=5 after consume");

        // ---- 0x113 mode==1: latch2 = 0x55, readable with control[4]=0 ----
        wr("direction", 8'h01);
        wr("data", 8'h01);           // mode 1
        wr("command", 8'h13);        // {1,0x13} = 0x113
        // latching was 3'b101: bit0 cleared, bit1 kept (0), bit2 cleared -> 0
        check8(control_byte, 8'h08, "latching=0 after 0x113 mode=1");
        wr("control", 8'h00);        // control[4]=0 -> latch2 side
        check8(data_byte, 8'h55, "latch2=0x55 (mode 1 handshake)");
        consume();                    // sets latching[0]
        check8(data_byte, 8'hFF, "latch2 not ready after consume");
        check8(control_byte, 8'h09, "latching=1 after latch2 consume");
        // latch1 also took the inlatch value; check via control[4]=1
        // (latching[2] is 0 after 0x113 cleared it)
        wr("control", 8'hFF);
        check8(data_byte, 8'h01, "latch1=inlatch after 0x113");

        // ---- 0x113 mode!=1: latching = 2, latch2 untouched ----
        wr("data", 8'h07);
        wr("command", 8'h13);        // direction still 1
        check8(control_byte, 8'h0A, "latching=2 after 0x113 mode!=1");
        wr("control", 8'h00);
        check8(data_byte, 8'h55, "latch2 untouched by mode!=1 branch");

        // ---- 0x010 / 0x110: latching |= 4 ----
        wr("command", 8'h10);        // {1,0x10} = 0x110
        check8(control_byte, 8'h0E, "latching|=4 after 0x110");

        // ---- bctrl write + readback ----
        wr("bctrl", 8'hA5);
        check8(bctrl, 8'hA5, "bctrl readback");

        // ---- tengai: table_absent leaves latch1 unchanged on 0x013 ----
        wr("control", 8'hFF);        // back to latch1 side
        wr("direction", 8'h01);
        wr("data", 8'd3);
        wr("command", 8'h1C);        // index 3 again (table[3]=0xAE)
        wr("direction", 8'h00);
        table_absent = 1;
        wr("command", 8'h13);
        check8(control_byte, 8'h09, "latching=1 after 0x013 (table absent)");
        check8(data_byte, 8'h07, "latch1 UNCHANGED by 0x013 when table absent");
        table_absent = 0;

        // ---- status toggle ----
        if (mcu_status !== 1'b0) begin errors++; $display("FAIL mcu_status reset"); end
        @(posedge clk); rd_status_toggle = 1; @(posedge clk); rd_status_toggle = 0; @(posedge clk);
        if (mcu_status !== 1'b1) begin errors++; $display("FAIL mcu_status toggle 1"); end
        @(posedge clk); rd_status_toggle = 1; @(posedge clk); rd_status_toggle = 0; @(posedge clk);
        if (mcu_status !== 1'b0) begin errors++; $display("FAIL mcu_status toggle 2"); end

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: watchdog timeout");
        $finish;
    end

endmodule
