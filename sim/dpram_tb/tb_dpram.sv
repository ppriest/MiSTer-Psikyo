`timescale 1ns/1ps
// Unit test for rtl/memory/dpram.sv: port A write/read (byte-lane writes,
// registered read-before-write semantics matching the RAM models
// sim/maincpu_tb/tb_maincpu.sv used), port B independent read of the same
// content, and a same-cycle A-write/B-read-of-that-address check (B must
// see the OLD value, same read-before-write rule as A).
module tb_dpram;

    logic clk = 0;
    always #5 clk = ~clk;

    logic [12:0] a_addr;
    logic         a_wel, a_weh;
    logic [15:0] a_wdata;
    logic [15:0] a_rdata;
    logic [12:0] b_addr;
    logic [15:0] b_rdata;

    dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) dut (
        .clk(clk),
        .a_addr(a_addr), .a_wel(a_wel), .a_weh(a_weh), .a_wdata(a_wdata), .a_rdata(a_rdata),
        .b_addr(b_addr), .b_rdata(b_rdata)
    );

    int errors = 0;

    task automatic write_word(input [12:0] addr, input [15:0] data);
        @(posedge clk);
        a_addr = addr; a_wdata = data; a_wel = 1; a_weh = 1;
        @(posedge clk);
        a_wel = 0; a_weh = 0;
    endtask

    initial begin
        a_addr = 0; a_wel = 0; a_weh = 0; a_wdata = 0; b_addr = 0;

        // Case 1: plain write then read back via port A.
        write_word(13'h0010, 16'hBEEF);
        @(posedge clk);
        a_addr = 13'h0010;
        @(posedge clk); // rdata registers on this edge
        #1;
        if (a_rdata !== 16'hBEEF) begin
            errors++;
            $display("FAIL Case1: a_rdata=%h expected=BEEF", a_rdata);
        end

        // Case 2: byte-lane write -- only touch the low byte, high byte
        // of the same word must survive untouched.
        write_word(13'h0020, 16'h1234);
        @(posedge clk);
        a_addr = 13'h0020; a_wdata = 16'h00AA; a_wel = 1; a_weh = 0;
        @(posedge clk);
        a_wel = 0;
        a_addr = 13'h0020;
        @(posedge clk);
        #1;
        if (a_rdata !== 16'h12AA) begin
            errors++;
            $display("FAIL Case2: a_rdata=%h expected=12AA (byte-lane write)", a_rdata);
        end

        // Case 3: port B sees the same content as port A, independently.
        write_word(13'h0030, 16'hCAFE);
        @(posedge clk);
        b_addr = 13'h0030;
        @(posedge clk);
        #1;
        if (b_rdata !== 16'hCAFE) begin
            errors++;
            $display("FAIL Case3: b_rdata=%h expected=CAFE", b_rdata);
        end

        // Case 4: same-cycle A-write / B-read-of-that-address -- B must
        // read the OLD value (read-before-write), matching A's own
        // same-cycle read/write rule.
        write_word(13'h0040, 16'h1111);
        @(posedge clk);
        b_addr = 13'h0040; // B armed to read this address next edge
        a_addr = 13'h0040; a_wdata = 16'h2222; a_wel = 1; a_weh = 1;
        @(posedge clk); // this edge: b_rdata registers OLD mem[0x40], A's write commits
        a_wel = 0; a_weh = 0;
        #1;
        if (b_rdata !== 16'h1111) begin
            errors++;
            $display("FAIL Case4: b_rdata=%h expected=1111 (old value, read-before-write)", b_rdata);
        end
        // Confirm the write did commit -- read it back now via A.
        a_addr = 13'h0040;
        @(posedge clk);
        #1;
        if (a_rdata !== 16'h2222) begin
            errors++;
            $display("FAIL Case4b: a_rdata=%h expected=2222 (write committed)", a_rdata);
        end

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule
