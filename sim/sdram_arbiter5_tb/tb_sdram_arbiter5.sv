// Integration test for sdram_arbiter5: real sdram_phy + sdram (the burst-4
// controller) + sdram_chip_model behind it -- same "use the real
// sub-modules, not synthetic stand-ins one level down" approach as
// tb_ddram_arbiter.sv and tb_video_pipeline_sdram.sv -- checking that the
// four read consumers get correctly routed, round-robin fairness holds, and
// the download write path takes absolute priority, all against real SDR
// SDRAM command/timing behavior, not an idealized stub.
//
// Structurally almost identical to tb_ddram_arbiter.sv (same four cases,
// same reasoning for why req must be HELD until the matching valid, not
// pulsed -- see that file's header) -- the real differences here are SDRAM
// specific: addresses must be 8-byte-aligned (sdram_phy's read-side
// contract), and a 500-cycle post-reset wait is needed before real requests
// arrive, matching sdram.sv's own power-up mode-register-load sequence
// (same convention as tb_sdram.sv/tb_video_pipeline_sdram.sv).

module tb_sdram_arbiter5;

    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    logic         phy_req, phy_we, phy_busy, phy_valid;
    logic [24:0] phy_addr;
    logic [7:0]  phy_wdata;
    logic [63:0] phy_rdata;

    logic         c0_req, c1_req, c2_req, c3_req;
    logic [24:0] c0_addr, c1_addr, c2_addr, c3_addr;
    logic         c0_valid, c1_valid, c2_valid, c3_valid;
    logic [63:0] c0_data, c1_data, c2_data, c3_data;

    logic         dl_req, dl_busy;
    logic [24:0] dl_addr;
    logic [7:0]  dl_data;

    sdram_arbiter5 dut (.*);

    logic [24:1] p_addr, unused_addr1, unused_addr2;
    logic         p_wrl, p_wrh, unused_wrl1, unused_wrh1, unused_wrl2, unused_wrh2;
    logic [15:0] p_din, unused_din1, unused_din2;
    logic [63:0] p_dout, unused_dout1, unused_dout2;
    logic         p_req, p_ack, unused_req1, unused_ack1, unused_req2, unused_ack2;
    assign unused_addr1 = 24'd0; assign unused_wrl1 = 1'b0; assign unused_wrh1 = 1'b0;
    assign unused_din1  = 16'd0; assign unused_req1 = 1'b0;
    assign unused_addr2 = 24'd0; assign unused_wrl2 = 1'b0; assign unused_wrh2 = 1'b0;
    assign unused_din2  = 16'd0; assign unused_req2 = 1'b0;

    sdram_phy phy (
        .clk(clk), .reset(reset),
        .port_addr(p_addr), .port_wrl(p_wrl), .port_wrh(p_wrh),
        .port_din(p_din), .port_dout(p_dout), .port_req(p_req), .port_ack(p_ack),
        .req(phy_req), .we(phy_we), .addr(phy_addr), .wdata(phy_wdata),
        .busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
    );

    wire [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic         SDRAM_DQML, SDRAM_DQMH;
    logic  [1:0] SDRAM_BA;
    logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    logic         SDRAM_CLK, SDRAM_CKE;

    sdram mem_ctrl (
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .init(1'b0), .clk(clk),
        .addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
        .addr1(unused_addr1), .wrl1(unused_wrl1), .wrh1(unused_wrh1), .din1(unused_din1), .dout1(unused_dout1), .req1(unused_req1), .ack1(unused_ack1),
        .addr2(unused_addr2), .wrl2(unused_wrl2), .wrh2(unused_wrh2), .din2(unused_din2), .dout2(unused_dout2), .req2(unused_req2), .ack2(unused_ack2)
    );

    sdram_chip_model chip (
        .clk(clk),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
    );

    int errors = 0;

    task automatic dl_write(int byte_addr, logic [7:0] data);
        @(posedge clk); dl_req = 1; dl_addr = byte_addr; dl_data = data;
        do @(posedge clk); while (!dl_busy);
        dl_req = 0;
        do @(posedge clk); while (dl_busy);
    endtask

    initial begin
        #3000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        reset = 1; c0_req=0; c1_req=0; c2_req=0; c3_req=0; dl_req=0;
        repeat (15) @(posedge clk);
        reset = 0;

        // let sdram.sv's own power-up mode-register-load sequence finish
        // before real requests start arriving (same 500-cycle headroom as
        // tb_sdram.sv / tb_video_pipeline_sdram.sv)
        repeat (500) @(posedge clk);

        // seed 4 distinct 8-byte-aligned granules (0,8,16,24), byte offset 0
        // of each, with distinct known values, via the arbiter's own
        // download write path
        dl_write(0,  8'hC0);
        dl_write(8,  8'hC1);
        dl_write(16, 8'hC2);
        dl_write(24, 8'hC3);

        // ---- Case 1: single-consumer correctness, one channel at a time ----
        @(posedge clk); c0_req=1; c0_addr=25'd0;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        if (c0_data[7:0] !== 8'hC0) begin errors++; $display("FAIL(case1,c0) got=%h expected=C0", c0_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c1_req=1; c1_addr=25'd8;
        do @(posedge clk); while (!c1_valid);
        c1_req = 0;
        if (c1_data[7:0] !== 8'hC1) begin errors++; $display("FAIL(case1,c1) got=%h expected=C1", c1_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c2_req=1; c2_addr=25'd16;
        do @(posedge clk); while (!c2_valid);
        c2_req = 0;
        if (c2_data[7:0] !== 8'hC2) begin errors++; $display("FAIL(case1,c2) got=%h expected=C2", c2_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c3_req=1; c3_addr=25'd24;
        do @(posedge clk); while (!c3_valid);
        c3_req = 0;
        if (c3_data[7:0] !== 8'hC3) begin errors++; $display("FAIL(case1,c3) got=%h expected=C3", c3_data[7:0]); end
        @(posedge clk);

        $display("Case 1 done (single-consumer routing, real SDRAM transport)");

        // ---- Case 2: all four request simultaneously, held until served ----
        @(posedge clk);
        c0_req=1; c0_addr=25'd0;
        c1_req=1; c1_addr=25'd8;
        c2_req=1; c2_addr=25'd16;
        c3_req=1; c3_addr=25'd24;

        fork
            begin : wait_c0
                do @(posedge clk); while (!c0_valid);
                c0_req = 0;
                if (c0_data[7:0] !== 8'hC0) begin errors++; $display("FAIL(case2,c0) got=%h expected=C0", c0_data[7:0]); end
            end
            begin : wait_c1
                do @(posedge clk); while (!c1_valid);
                c1_req = 0;
                if (c1_data[7:0] !== 8'hC1) begin errors++; $display("FAIL(case2,c1) got=%h expected=C1", c1_data[7:0]); end
            end
            begin : wait_c2
                do @(posedge clk); while (!c2_valid);
                c2_req = 0;
                if (c2_data[7:0] !== 8'hC2) begin errors++; $display("FAIL(case2,c2) got=%h expected=C2", c2_data[7:0]); end
            end
            begin : wait_c3
                do @(posedge clk); while (!c3_valid);
                c3_req = 0;
                if (c3_data[7:0] !== 8'hC3) begin errors++; $display("FAIL(case2,c3) got=%h expected=C3", c3_data[7:0]); end
            end
        join

        $display("Case 2 done (simultaneous requests, all four served correctly, real SDRAM)");
        @(posedge clk);

        // ---- Case 3: round-robin fairness ----
        @(posedge clk); c0_req=1; c0_addr=25'd0;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        @(posedge clk);

        @(posedge clk);
        c0_req=1; c0_addr=25'd0;
        c1_req=1; c1_addr=25'd8;

        begin
            automatic bit c0_first = 0;
            automatic bit c1_first = 0;
            while (!c0_first && !c1_first) begin
                @(posedge clk);
                if (c0_valid) c0_first = 1;
                if (c1_valid) c1_first = 1;
            end
            if (c0_first) begin
                errors++;
                c0_req = 0;
                $display("FAIL(case3) c0 served before c1 -- round-robin pointer did not rotate");
                do @(posedge clk); while (!c1_valid);
                c1_req = 0;
            end else begin
                $display("Case 3: c1 served first, as expected from round-robin rotation");
                c1_req = 0;
                do @(posedge clk); while (!c0_valid);
                c0_req = 0;
            end
        end
        @(posedge clk);

        $display("Case 3 done (round-robin fairness, real SDRAM)");

        // ---- Case 4: download priority over a pending read ----
        @(posedge clk); c2_req=1; c2_addr=25'd16;
        @(posedge clk);
        dl_write(0, 8'hD0);
        do @(posedge clk); while (!c2_valid);
        c2_req = 0;
        if (c2_data[7:0] !== 8'hC2) begin errors++; $display("FAIL(case4) delayed read got=%h expected=C2", c2_data[7:0]); end

        @(posedge clk); c0_req=1; c0_addr=25'd0;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        if (c0_data[7:0] !== 8'hD0) begin errors++; $display("FAIL(case4) download write did not land: got=%h expected=D0", c0_data[7:0]); end

        $display("Case 4 done (download priority, real SDRAM)");

        if (errors == 0)
            $display("PASS: sdram_arbiter5 matches expected behavior for all cases against real SDRAM transport");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
