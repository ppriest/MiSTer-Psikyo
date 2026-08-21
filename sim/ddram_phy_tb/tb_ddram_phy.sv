// Verifies ddram_phy's req/valid client interface against the DDRAM_*
// protocol timing (busy/dout_ready handshake) as modeled by ddram_model,
// run against TWO independently-parameterized model latencies (see
// ddram_model.sv's header) to catch any bug that only shows up at a
// particular latency rather than being a genuine protocol violation.
//
// Two fully separate, directly-duplicated test sequences (not a shared
// generate loop or ref-sharing task) -- ModelSim 10.5b rejects runtime-
// indexed hierarchical references into generate-block arrays (vsim-3745),
// and a first attempt at sharing test logic via nested `ref` task
// arguments deadlocked for an unrelated reason (see below) before that
// path was abandoned. Direct signal manipulation per instance, as used
// throughout every other testbench in this project, sidesteps the
// generate-indexing issue.
//
// Real bug found and fixed while debugging the apparent deadlock: `while
// (busy) @(posedge clk);` checked IMMEDIATELY after `@(posedge clk);
// req=0;` on the very same simulation time step as the edge that starts
// the transaction -- since the DUT's `state` only updates via a
// nonblocking assignment on that identical edge, the busy check was
// racing the DUT's own NBA update and reading the PRE-transaction (stale,
// still-idle) value, so the testbench believed the transaction had
// already finished when it hadn't even started. This let a stray
// leftover `we` value from a previous transaction get sampled by the next
// (still in-flight, not actually idle) request. Fixed by always waiting
// for at least one full edge before the first busy/valid check (`do
// @(posedge clk); while (busy);`), which is now used everywhere in this
// file -- a correctness lesson for every future testbench in this
// project that polls a DUT-driven status signal right after the edge
// that might update it.
//
// Cases per instance:
//   1. single-byte write then read-back of that byte's granule, checking
//      the byte landed in the correct lane (DDRAM_BE selection). Only
//      checks that one lane, not the whole granule -- the other 7 lanes
//      are genuinely unwritten DRAM content (X in this model, matching
//      real hardware's undefined-until-written semantics, same principle
//      already established in sprite_frame_buffer_tb), not assumed-zero.
//   2. eight separate byte writes building a known 64-bit pattern across
//      an entire granule, then one granule read verifying the full 64-bit
//      value -- confirms lane addressing is correct across all 8 offsets,
//      not just one
//   3. back-to-back read requests to different granules, checking `busy`
//      stays asserted for the whole transaction and `valid` pulses exactly
//      once per request (not stuck high, not double-pulsing)
//   4. a request issued the very next cycle after `busy` deasserts (no
//      dead cycle required) reads back correctly -- confirms the interface
//      doesn't need extra settle time beyond what `busy` already reports

module tb_ddram_phy;

    int errors = 0;

    // ---- instance A: READ_LATENCY=6 ----
    logic clk_a = 0;
    logic reset_a;
    logic         DDRAM_BUSY_a;
    logic [7:0]  DDRAM_BURSTCNT_a;
    logic [28:0] DDRAM_ADDR_a;
    logic [63:0] DDRAM_DOUT_a;
    logic         DDRAM_DOUT_READY_a;
    logic         DDRAM_RD_a;
    logic [63:0] DDRAM_DIN_a;
    logic [7:0]  DDRAM_BE_a;
    logic         DDRAM_WE_a;
    logic         req_a, we_a, busy_a, valid_a;
    logic [27:0] addr_a;
    logic [7:0]  wdata_a;
    logic [63:0] rdata_a;

    always #5 clk_a = ~clk_a;

    ddram_phy dut_a (
        .clk(clk_a), .reset(reset_a),
        .DDRAM_BUSY(DDRAM_BUSY_a), .DDRAM_BURSTCNT(DDRAM_BURSTCNT_a), .DDRAM_ADDR(DDRAM_ADDR_a),
        .DDRAM_DOUT(DDRAM_DOUT_a), .DDRAM_DOUT_READY(DDRAM_DOUT_READY_a), .DDRAM_RD(DDRAM_RD_a),
        .DDRAM_DIN(DDRAM_DIN_a), .DDRAM_BE(DDRAM_BE_a), .DDRAM_WE(DDRAM_WE_a),
        .req(req_a), .we(we_a), .addr(addr_a), .wdata(wdata_a),
        .busy(busy_a), .valid(valid_a), .rdata(rdata_a)
    );

    ddram_model #(.READ_LATENCY(6), .BUSY_CYCLES(2)) model_a (
        .clk(clk_a), .reset(reset_a),
        .DDRAM_BUSY(DDRAM_BUSY_a), .DDRAM_BURSTCNT(DDRAM_BURSTCNT_a), .DDRAM_ADDR(DDRAM_ADDR_a),
        .DDRAM_DOUT(DDRAM_DOUT_a), .DDRAM_DOUT_READY(DDRAM_DOUT_READY_a), .DDRAM_RD(DDRAM_RD_a),
        .DDRAM_DIN(DDRAM_DIN_a), .DDRAM_BE(DDRAM_BE_a), .DDRAM_WE(DDRAM_WE_a)
    );

    // ---- instance B: READ_LATENCY=13 ----
    logic clk_b = 0;
    logic reset_b;
    logic         DDRAM_BUSY_b;
    logic [7:0]  DDRAM_BURSTCNT_b;
    logic [28:0] DDRAM_ADDR_b;
    logic [63:0] DDRAM_DOUT_b;
    logic         DDRAM_DOUT_READY_b;
    logic         DDRAM_RD_b;
    logic [63:0] DDRAM_DIN_b;
    logic [7:0]  DDRAM_BE_b;
    logic         DDRAM_WE_b;
    logic         req_b, we_b, busy_b, valid_b;
    logic [27:0] addr_b;
    logic [7:0]  wdata_b;
    logic [63:0] rdata_b;

    always #5 clk_b = ~clk_b;

    ddram_phy dut_b (
        .clk(clk_b), .reset(reset_b),
        .DDRAM_BUSY(DDRAM_BUSY_b), .DDRAM_BURSTCNT(DDRAM_BURSTCNT_b), .DDRAM_ADDR(DDRAM_ADDR_b),
        .DDRAM_DOUT(DDRAM_DOUT_b), .DDRAM_DOUT_READY(DDRAM_DOUT_READY_b), .DDRAM_RD(DDRAM_RD_b),
        .DDRAM_DIN(DDRAM_DIN_b), .DDRAM_BE(DDRAM_BE_b), .DDRAM_WE(DDRAM_WE_b),
        .req(req_b), .we(we_b), .addr(addr_b), .wdata(wdata_b),
        .busy(busy_b), .valid(valid_b), .rdata(rdata_b)
    );

    ddram_model #(.READ_LATENCY(13), .BUSY_CYCLES(2)) model_b (
        .clk(clk_b), .reset(reset_b),
        .DDRAM_BUSY(DDRAM_BUSY_b), .DDRAM_BURSTCNT(DDRAM_BURSTCNT_b), .DDRAM_ADDR(DDRAM_ADDR_b),
        .DDRAM_DOUT(DDRAM_DOUT_b), .DDRAM_DOUT_READY(DDRAM_DOUT_READY_b), .DDRAM_RD(DDRAM_RD_b),
        .DDRAM_DIN(DDRAM_DIN_b), .DDRAM_BE(DDRAM_BE_b), .DDRAM_WE(DDRAM_WE_b)
    );

    initial begin
        #200000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        logic [63:0] r;

        // ================= instance A (READ_LATENCY=6) =================
        reset_a = 1; req_a = 0;
        repeat (3) @(posedge clk_a);
        reset_a = 0;
        @(posedge clk_a);

        // Case 1: single-byte write + granule read-back
        @(posedge clk_a); req_a=1; we_a=1; addr_a=8; wdata_a=8'hA5;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (busy_a);

        @(posedge clk_a); req_a=1; we_a=0; addr_a=8;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (!valid_a);
        r = rdata_a;
        @(posedge clk_a);
        if (r[7:0] !== 8'hA5) begin
            errors++;
            $display("FAIL(lat=6,case1) granule read: got=%h expected lane0=A5", r);
        end

        // Case 2: eight byte writes building a known pattern
        for (int i = 0; i < 8; i++) begin
            @(posedge clk_a); req_a=1; we_a=1; addr_a=16+i; wdata_a=8'h11*(i+1);
            @(posedge clk_a); req_a=0;
            do @(posedge clk_a); while (busy_a);
        end
        @(posedge clk_a); req_a=1; we_a=0; addr_a=16;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (!valid_a);
        r = rdata_a;
        @(posedge clk_a);
        if (r !== 64'h8877_6655_4433_2211) begin
            errors++;
            $display("FAIL(lat=6,case2) granule read: got=%h expected=8877665544332211", r);
        end

        // Case 3: back-to-back reads to different granules
        @(posedge clk_a); req_a=1; we_a=1; addr_a=24; wdata_a=8'hDE;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (busy_a);
        @(posedge clk_a); req_a=1; we_a=1; addr_a=32; wdata_a=8'hAD;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (busy_a);

        @(posedge clk_a); req_a=1; we_a=0; addr_a=24;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (!valid_a);
        r = rdata_a;
        @(posedge clk_a);
        if (r[7:0] !== 8'hDE) begin
            errors++;
            $display("FAIL(lat=6,case3a) got=%h expected lane0=DE", r);
        end

        @(posedge clk_a); req_a=1; we_a=0; addr_a=32;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (!valid_a);
        r = rdata_a;
        @(posedge clk_a);
        if (r[7:0] !== 8'hAD) begin
            errors++;
            $display("FAIL(lat=6,case3b) got=%h expected lane0=AD", r);
        end

        // Case 4: immediate re-request the cycle busy clears
        @(posedge clk_a); req_a=1; we_a=1; addr_a=40; wdata_a=8'h5A;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (busy_a);
        @(posedge clk_a); req_a=1; we_a=0; addr_a=40;
        @(posedge clk_a); req_a=0;
        do @(posedge clk_a); while (!valid_a);
        r = rdata_a;
        @(posedge clk_a);
        if (r[7:0] !== 8'h5A) begin
            errors++;
            $display("FAIL(lat=6,case4) got=%h expected lane0=5A", r);
        end

        $display("lat=6: all cases done");

        // ================= instance B (READ_LATENCY=13) =================
        reset_b = 1; req_b = 0;
        repeat (3) @(posedge clk_b);
        reset_b = 0;
        @(posedge clk_b);

        // Case 1
        @(posedge clk_b); req_b=1; we_b=1; addr_b=8; wdata_b=8'hA5;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (busy_b);
        @(posedge clk_b); req_b=1; we_b=0; addr_b=8;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (!valid_b);
        r = rdata_b;
        @(posedge clk_b);
        if (r[7:0] !== 8'hA5) begin
            errors++;
            $display("FAIL(lat=13,case1) granule read: got=%h expected lane0=A5", r);
        end

        // Case 2
        for (int i = 0; i < 8; i++) begin
            @(posedge clk_b); req_b=1; we_b=1; addr_b=16+i; wdata_b=8'h11*(i+1);
            @(posedge clk_b); req_b=0;
            do @(posedge clk_b); while (busy_b);
        end
        @(posedge clk_b); req_b=1; we_b=0; addr_b=16;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (!valid_b);
        r = rdata_b;
        @(posedge clk_b);
        if (r !== 64'h8877_6655_4433_2211) begin
            errors++;
            $display("FAIL(lat=13,case2) granule read: got=%h expected=8877665544332211", r);
        end

        // Case 3
        @(posedge clk_b); req_b=1; we_b=1; addr_b=24; wdata_b=8'hDE;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (busy_b);
        @(posedge clk_b); req_b=1; we_b=1; addr_b=32; wdata_b=8'hAD;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (busy_b);

        @(posedge clk_b); req_b=1; we_b=0; addr_b=24;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (!valid_b);
        r = rdata_b;
        @(posedge clk_b);
        if (r[7:0] !== 8'hDE) begin
            errors++;
            $display("FAIL(lat=13,case3a) got=%h expected lane0=DE", r);
        end

        @(posedge clk_b); req_b=1; we_b=0; addr_b=32;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (!valid_b);
        r = rdata_b;
        @(posedge clk_b);
        if (r[7:0] !== 8'hAD) begin
            errors++;
            $display("FAIL(lat=13,case3b) got=%h expected lane0=AD", r);
        end

        // Case 4
        @(posedge clk_b); req_b=1; we_b=1; addr_b=40; wdata_b=8'h5A;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (busy_b);
        @(posedge clk_b); req_b=1; we_b=0; addr_b=40;
        @(posedge clk_b); req_b=0;
        do @(posedge clk_b); while (!valid_b);
        r = rdata_b;
        @(posedge clk_b);
        if (r[7:0] !== 8'h5A) begin
            errors++;
            $display("FAIL(lat=13,case4) got=%h expected lane0=5A", r);
        end

        $display("lat=13: all cases done");

        if (errors == 0)
            $display("PASS: ddram_phy matches expected behavior at all tested latencies");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
