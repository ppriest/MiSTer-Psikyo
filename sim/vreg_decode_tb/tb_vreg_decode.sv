`timescale 1ns/1ps
// Unit test for rtl/video/vreg_decode.sv: CPU writes into the row-scroll
// tables and the six fixed control registers (docs/phase1_memory_map.md
// "Video registers"), verify both layers' row-scroll read ports see the
// right data at the right table offset, the control-word bit fields decode
// correctly, and plain scratch RAM elsewhere in the region round-trips
// through the CPU port untouched by any of the above.
module tb_vreg_decode;

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset;

    logic [12:0] cpu_addr;
    logic         cpu_wel, cpu_weh;
    logic [15:0] cpu_wdata;
    logic [15:0] cpu_rdata;

    logic [7:0]  layer0_rowscroll_addr, layer1_rowscroll_addr;
    logic [15:0] layer0_rowscroll_data, layer1_rowscroll_data;

    logic [1:0]  layer0_mode, layer1_mode;
    logic [15:0] layer0_base_x_scroll, layer0_base_y_scroll;
    logic [15:0] layer1_base_x_scroll, layer1_base_y_scroll;
    logic [1:0]  layer0_bank, layer1_bank;
    logic         layer0_enable, layer1_enable;
    logic         layer0_rowscroll_enable, layer1_rowscroll_enable;
    logic         layer0_rowscroll_pertile, layer1_rowscroll_pertile;

    vreg_decode dut (.*);

    int errors = 0;

    task automatic cpu_write(input [12:0] addr, input [15:0] data);
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

    initial begin
        reset = 1; cpu_addr = 0; cpu_wel = 0; cpu_weh = 0; cpu_wdata = 0;
        layer0_rowscroll_addr = 0; layer1_rowscroll_addr = 0;
        repeat (2) @(posedge clk);
        reset = 0;

        // Case 1: layer 0 row-scroll table, word 0x000-0x0FF.
        cpu_write(13'h0000, 16'hA001); // index 0
        cpu_write(13'h0007, 16'hA007); // index 7
        cpu_write(13'h00FF, 16'hA0FF); // index 255 (last entry)

        // Case 2: layer 1 row-scroll table, word 0x100-0x1FF.
        cpu_write(13'h0100, 16'hB100); // index 0
        cpu_write(13'h0107, 16'hB107); // index 7
        cpu_write(13'h01FF, 16'hB1FF); // index 255

        // Case 3: six control registers.
        cpu_write(13'h0201, 16'h0011); // layer0 Y scroll
        cpu_write(13'h0203, 16'h0022); // layer0 X scroll base
        cpu_write(13'h0205, 16'h0033); // layer1 Y scroll
        cpu_write(13'h0207, 16'h0044); // layer1 X scroll base
        // layer0 ctrl: enable=1, mode=2 (bits7-6=10), rowscroll_enable=1,
        // rowscroll_pertile=0 -> 0b00_00_0_1_10_000001 = bits: [0]=1 [7:6]=10 [8]=1
        cpu_write(13'h0209, 16'b0000_0001_1000_0001);
        // layer1 ctrl: enable=1, mode=3 (11), rowscroll_enable=1,
        // rowscroll_pertile=1
        cpu_write(13'h020B, 16'b0000_0011_1100_0001);

        // Case 4: plain scratch RAM elsewhere in the region, unrelated to
        // any of the fixed fields above -- must round-trip via the CPU
        // port untouched.
        cpu_write(13'h1000, 16'hDEAD);

        @(posedge clk); #1;

        // Verify row-scroll reads.
        layer0_rowscroll_addr = 8'd0;   @(posedge clk); #1; check16(layer0_rowscroll_data, 16'hA001, "l0 rowscroll[0]");
        layer0_rowscroll_addr = 8'd7;   @(posedge clk); #1; check16(layer0_rowscroll_data, 16'hA007, "l0 rowscroll[7]");
        layer0_rowscroll_addr = 8'd255; @(posedge clk); #1; check16(layer0_rowscroll_data, 16'hA0FF, "l0 rowscroll[255]");
        layer1_rowscroll_addr = 8'd0;   @(posedge clk); #1; check16(layer1_rowscroll_data, 16'hB100, "l1 rowscroll[0]");
        layer1_rowscroll_addr = 8'd7;   @(posedge clk); #1; check16(layer1_rowscroll_data, 16'hB107, "l1 rowscroll[7]");
        layer1_rowscroll_addr = 8'd255; @(posedge clk); #1; check16(layer1_rowscroll_data, 16'hB1FF, "l1 rowscroll[255]");

        // Verify decoded control outputs.
        check16(layer0_base_y_scroll, 16'h0011, "l0 y_scroll");
        check16(layer0_base_x_scroll, 16'h0022, "l0 x_scroll");
        check16(layer1_base_y_scroll, 16'h0033, "l1 y_scroll");
        check16(layer1_base_x_scroll, 16'h0044, "l1 x_scroll");
        if (layer0_enable !== 1'b1)            begin errors++; $display("FAIL l0 enable"); end
        if (layer0_mode !== 2'b10)               begin errors++; $display("FAIL l0 mode=%b expected=10", layer0_mode); end
        if (layer0_rowscroll_enable !== 1'b1)   begin errors++; $display("FAIL l0 rowscroll_enable"); end
        if (layer0_rowscroll_pertile !== 1'b0)  begin errors++; $display("FAIL l0 rowscroll_pertile"); end
        if (layer1_enable !== 1'b1)              begin errors++; $display("FAIL l1 enable"); end
        if (layer1_mode !== 2'b11)               begin errors++; $display("FAIL l1 mode=%b expected=11", layer1_mode); end
        if (layer1_rowscroll_enable !== 1'b1)   begin errors++; $display("FAIL l1 rowscroll_enable"); end
        if (layer1_rowscroll_pertile !== 1'b1)  begin errors++; $display("FAIL l1 rowscroll_pertile"); end

        // Verify plain scratch RAM round-trip via CPU port.
        @(posedge clk);
        cpu_addr = 13'h1000;
        @(posedge clk); #1;
        check16(cpu_rdata, 16'hDEAD, "scratch RAM readback");

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule
