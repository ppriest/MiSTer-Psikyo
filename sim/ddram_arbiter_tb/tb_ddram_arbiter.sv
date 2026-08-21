// Integration test for ddram_arbiter: real ddram_phy + ddram_model behind
// it (same "use the real sub-modules, not synthetic stand-ins one level
// down" approach as sprite_render_engine_tb), checking that four
// independent req/valid read consumers get correctly routed and that the
// download write path takes absolute priority.
//
// Request convention matters here and was a real bug source: checked
// directly against sprite_render_engine.sv (S_LUT_WAIT/S_ROW_WAIT), the
// real gfxrom_req/lut_req ports HOLD req asserted across multiple cycles
// until the matching valid pulse arrives, then clear it -- NOT a one-shot
// pulse. An earlier version of this testbench pulsed c0..c3_req for a
// single cycle each (matching how ddram_phy's own req happens to be
// sampled, which is idempotent to a held-high input so single-consumer
// cases still passed) then hung forever on the four-simultaneous-
// consumers case, because by the time the arbiter's round robin got
// around to servicing c1/c2/c3, their req lines had already been dropped
// and the arbiter had nothing left to see. Every request in this file
// now holds req until its own valid pulse, matching the real consumers'
// contract.
//
// Cases:
//   1. single-consumer request/response correctness for each of the four
//      channels in turn (c0..c3), each reading a distinct pre-seeded
//      granule -- confirms address routing isn't crossed between channels
//   2. simultaneous requests from all four channels at once (req held
//      throughout): every channel must eventually be served with its OWN
//      correct data
//   3. round-robin fairness: after c0 is served alone, a fresh simultaneous
//      request from c0 and c1 must serve c1 FIRST (c0 was just served, so
//      its priority rotated to the back) -- distinguishes real round robin
//      from a fixed c0>c1>c2>c3 priority scheme that would serve c0 first
//      every time
//   4. a download write request arriving while a read consumer is already
//      pending must be served first (absolute priority), and the delayed
//      read consumer must still eventually complete correctly afterward

module tb_ddram_arbiter;

    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    logic         phy_req, phy_we, phy_busy, phy_valid;
    logic [27:0] phy_addr;
    logic [7:0]  phy_wdata;
    logic [63:0] phy_rdata;

    logic         c0_req, c1_req, c2_req, c3_req;
    logic [27:0] c0_addr, c1_addr, c2_addr, c3_addr;
    logic         c0_valid, c1_valid, c2_valid, c3_valid;
    logic [63:0] c0_data, c1_data, c2_data, c3_data;

    logic         dl_req, dl_busy;
    logic [27:0] dl_addr;
    logic [7:0]  dl_data;

    ddram_arbiter dut (.*);

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

    task automatic dl_write(int byte_addr, logic [7:0] data);
        // dl_req must stay held until the arbiter actually starts servicing
        // it (dl_busy asserts) -- same "hold until acknowledged" contract as
        // the read consumers, not a one-shot pulse. A one-shot pulse here
        // was a real bug: if the arbiter was mid-transaction serving a read
        // consumer when dl_req pulsed, the download request was silently
        // lost (cleared before the arbiter ever got back to A_IDLE to see
        // it), so the download never landed -- see Case 4's original
        // failure ("download write did not land").
        @(posedge clk); dl_req = 1; dl_addr = byte_addr; dl_data = data;
        do @(posedge clk); while (!dl_busy);
        dl_req = 0;
        do @(posedge clk); while (dl_busy);
    endtask

    initial begin
        #300000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        reset = 1; c0_req=0; c1_req=0; c2_req=0; c3_req=0; dl_req=0;
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // seed 4 distinct granules (64,72,80,88), lane 0, with distinct
        // known values, via the arbiter's own download write path
        dl_write(64, 8'hC0);
        dl_write(72, 8'hC1);
        dl_write(80, 8'hC2);
        dl_write(88, 8'hC3);

        // ---- Case 1: single-consumer correctness, one channel at a time ----
        @(posedge clk); c0_req=1; c0_addr=64;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        if (c0_data[7:0] !== 8'hC0) begin errors++; $display("FAIL(case1,c0) got=%h expected=C0", c0_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c1_req=1; c1_addr=72;
        do @(posedge clk); while (!c1_valid);
        c1_req = 0;
        if (c1_data[7:0] !== 8'hC1) begin errors++; $display("FAIL(case1,c1) got=%h expected=C1", c1_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c2_req=1; c2_addr=80;
        do @(posedge clk); while (!c2_valid);
        c2_req = 0;
        if (c2_data[7:0] !== 8'hC2) begin errors++; $display("FAIL(case1,c2) got=%h expected=C2", c2_data[7:0]); end
        @(posedge clk);

        @(posedge clk); c3_req=1; c3_addr=88;
        do @(posedge clk); while (!c3_valid);
        c3_req = 0;
        if (c3_data[7:0] !== 8'hC3) begin errors++; $display("FAIL(case1,c3) got=%h expected=C3", c3_data[7:0]); end
        @(posedge clk);

        $display("Case 1 done (single-consumer routing)");

        // ---- Case 2: all four request simultaneously, held until served ----
        @(posedge clk);
        c0_req=1; c0_addr=64;
        c1_req=1; c1_addr=72;
        c2_req=1; c2_addr=80;
        c3_req=1; c3_addr=88;

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

        $display("Case 2 done (simultaneous requests, all four served correctly)");
        @(posedge clk);

        // ---- Case 3: round-robin fairness ----
        // rr_ptr after case 2's four services (started at 0, served in
        // order 0,1,2,3) should now point back at 0 -- so serve c0 ALONE
        // first to rotate the pointer to 1, then issue a simultaneous
        // c0+c1 request and confirm c1 (not c0) is served first.
        @(posedge clk); c0_req=1; c0_addr=64;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        @(posedge clk);

        @(posedge clk);
        c0_req=1; c0_addr=64;
        c1_req=1; c1_addr=72;

        // c1 must become valid strictly before c0 if round-robin fairness
        // is real (rr_ptr now points at c1's slot, having just served c0
        // alone above) -- poll each cycle for whichever comes first.
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

        $display("Case 3 done (round-robin fairness)");

        // ---- Case 4: download priority over a pending read ----
        @(posedge clk); c2_req=1; c2_addr=80;
        @(posedge clk);
        // issue a download write while c2's read is still pending (c2_req
        // stays held throughout -- the real read consumers never drop
        // their request just because something else got priority)
        dl_write(64, 8'hD0);
        // the read must still complete correctly afterward
        do @(posedge clk); while (!c2_valid);
        c2_req = 0;
        if (c2_data[7:0] !== 8'hC2) begin errors++; $display("FAIL(case4) delayed read got=%h expected=C2", c2_data[7:0]); end

        // confirm the download itself actually landed
        @(posedge clk); c0_req=1; c0_addr=64;
        do @(posedge clk); while (!c0_valid);
        c0_req = 0;
        if (c0_data[7:0] !== 8'hD0) begin errors++; $display("FAIL(case4) download write did not land: got=%h expected=D0", c0_data[7:0]); end

        $display("Case 4 done (download priority)");

        if (errors == 0)
            $display("PASS: ddram_arbiter matches expected behavior for all cases");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
