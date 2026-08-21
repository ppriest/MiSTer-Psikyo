// Integration test for ddram_download: real ddram_download + ddram_arbiter
// + ddram_phy + ddram_model chained together (same "use the real
// sub-modules" approach as tb_ddram_arbiter), driven by a test-side
// ioctl_wr generator that respects ioctl_wait realistically (matching how
// the real HPS/Linux side is expected to behave, per hps_io.sv -- this
// module itself doesn't enforce ioctl_wait timing, the ARM side does).
//
// Cases:
//   1. single-byte download lands at the correct address (read back
//      through the arbiter's c0 channel)
//   2. multiple sequential bytes, paced by respecting ioctl_wait each
//      time (not fixed-delay), all land at their own correct addresses
//      with none dropped or corrupted
//   3. a download under ioctl_index != 0 is ignored entirely -- no dl_req
//      ever reaches the arbiter, and the byte does NOT land in DDRAM

module tb_ddram_download;

    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    logic         ioctl_download, ioctl_wr, ioctl_wait;
    logic [15:0] ioctl_index;
    logic [26:0] ioctl_addr;
    logic [7:0]  ioctl_dout;

    logic         dl_req, dl_busy;
    logic [27:0] dl_addr;
    logic [7:0]  dl_data;

    ddram_download dl (.*);

    // arbiter's read side: only c0 exercised by this testbench (c1-c3 tied off)
    logic         c0_req, c1_req, c2_req, c3_req;
    logic [27:0] c0_addr, c1_addr, c2_addr, c3_addr;
    logic         c0_valid, c1_valid, c2_valid, c3_valid;
    logic [63:0] c0_data, c1_data, c2_data, c3_data;
    assign c1_req = 1'b0;
    assign c2_req = 1'b0;
    assign c3_req = 1'b0;

    logic         phy_req, phy_we, phy_busy, phy_valid;
    logic [27:0] phy_addr;
    logic [7:0]  phy_wdata;
    logic [63:0] phy_rdata;

    ddram_arbiter arb (.*);

    logic         m_busy, m_dout_ready, m_rd, m_we;
    logic [7:0]  m_burstcnt, m_be;
    logic [28:0] m_addr;
    logic [63:0] m_dout, m_din;

    ddram_phy phy (
        .clk(clk), .reset(reset),
        .DDRAM_BUSY(m_busy), .DDRAM_BURSTCNT(m_burstcnt), .DDRAM_ADDR(m_addr),
        .DDRAM_DOUT(m_dout), .DDRAM_DOUT_READY(m_dout_ready), .DDRAM_RD(m_rd),
        .DDRAM_DIN(m_din), .DDRAM_BE(m_be), .DDRAM_WE(m_we),
        .req(phy_req), .we(phy_we), .addr(phy_addr), .wdata(phy_wdata),
        .busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
    );

    ddram_model #(.READ_LATENCY(6), .BUSY_CYCLES(2)) model (
        .clk(clk), .reset(reset),
        .DDRAM_BUSY(m_busy), .DDRAM_BURSTCNT(m_burstcnt), .DDRAM_ADDR(m_addr),
        .DDRAM_DOUT(m_dout), .DDRAM_DOUT_READY(m_dout_ready), .DDRAM_RD(m_rd),
        .DDRAM_DIN(m_din), .DDRAM_BE(m_be), .DDRAM_WE(m_we)
    );

    int errors = 0;

    // simulates hps_io sending one byte: pulse ioctl_wr for one cycle,
    // then wait for ioctl_wait to drop before returning -- a realistic
    // sender that actually respects the backpressure signal
    task automatic send_byte(int addr, logic [7:0] data);
        @(posedge clk);
        ioctl_wr = 1; ioctl_addr = addr; ioctl_dout = data;
        @(posedge clk);
        ioctl_wr = 0;
        do @(posedge clk); while (ioctl_wait);
    endtask

    task automatic read_byte(int addr, output logic [7:0] result);
        // c0_data returns the whole 8-byte granule -- select the lane the
        // caller actually asked for (addr mod 8), not always lane 0 (an
        // earlier version of this task did that, and produced false
        // failures for any address sharing a granule with a
        // previously-read one -- a testbench bug, not a ddram_download bug).
        @(posedge clk); c0_req = 1; c0_addr = addr;
        do @(posedge clk); while (!c0_valid);
        result = c0_data[(addr[2:0])*8 +: 8];
        c0_req = 0;
        @(posedge clk);
    endtask

    initial begin
        #300000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        reset = 1;
        ioctl_download = 0; ioctl_wr = 0; ioctl_index = 0; c0_req = 0;
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // ---- Case 1: single-byte download ----
        ioctl_download = 1;
        send_byte(64, 8'hE1);
        ioctl_download = 0;

        begin
            logic [7:0] r;
            read_byte(64, r);
            if (r !== 8'hE1) begin errors++; $display("FAIL(case1) got=%h expected=E1", r); end
        end
        $display("Case 1 done (single-byte download)");

        // ---- Case 2: multiple sequential bytes, realistically paced ----
        ioctl_download = 1;
        send_byte(72, 8'hA0);
        send_byte(73, 8'hA1);
        send_byte(74, 8'hA2);
        send_byte(75, 8'hA3);
        ioctl_download = 0;

        begin
            logic [7:0] r;
            read_byte(72, r); if (r !== 8'hA0) begin errors++; $display("FAIL(case2,0) got=%h expected=A0", r); end
            read_byte(73, r); if (r !== 8'hA1) begin errors++; $display("FAIL(case2,1) got=%h expected=A1", r); end
            read_byte(74, r); if (r !== 8'hA2) begin errors++; $display("FAIL(case2,2) got=%h expected=A2", r); end
            read_byte(75, r); if (r !== 8'hA3) begin errors++; $display("FAIL(case2,3) got=%h expected=A3", r); end
        end
        $display("Case 2 done (multiple sequential bytes)");

        // ---- Case 3: non-zero ioctl_index is ignored ----
        // pre-seed address 80 with a known sentinel via a real (index=0)
        // download first, so we can tell if the index!=0 attempt below
        // actually overwrote it (it must not).
        ioctl_download = 1;
        ioctl_index = 0;
        send_byte(80, 8'hF0);
        ioctl_index = 1;
        send_byte(80, 8'hFF);   // must be ignored -- wrong index
        ioctl_index = 0;
        ioctl_download = 0;

        begin
            logic [7:0] r;
            read_byte(80, r);
            if (r !== 8'hF0) begin errors++; $display("FAIL(case3) index!=0 write leaked through: got=%h expected=F0 (unchanged)", r); end
        end
        $display("Case 3 done (non-zero ioctl_index ignored)");

        if (errors == 0)
            $display("PASS: ddram_download matches expected behavior for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
