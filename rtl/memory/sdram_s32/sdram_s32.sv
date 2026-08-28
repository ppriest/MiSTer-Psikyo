//============================================================================
//  Sega System 32 for MiSTer — SDRAM controller
//  16-bit SDR SDRAM @ clk_sys (85.909 MHz), CL2, strictly serialized
//  transactions. ROM-download writes keep a row open for same-row words and
//  explicitly precharge before row changes, reads, or refreshes.
//  Six request ports with bounded tile-deadline priority and round-robin
//  background fairness (DESIGN.md §4.2):
//    p0: V60 fetch/data (16-bit exact word or aligned 64-bit cache line)
//    p1: tile fetch      (64-bit burst = 4 words)
//    p2: sprite fetch    (128-bit burst = 8 words)
//    p3: Z80 ROM         (16-bit single, byte laned)
//    p4: MultiPCM        (16-bit single)
//    p5: V25 program ROM  (64-bit burst = 4 words)
//  Write port (ROM download only): highest priority while ioctl_download.
//
//  REQUEST CONTRACT (all ports, including wr): one transaction per req
//  RISING EDGE; the address (and write data/be) is sampled on that edge.
//  A request held high is serviced exactly ONCE — a requester expecting
//  re-service per ack from a held level will hang.  Requesters must be
//  single-outstanding: drop req after (or pulse it before) each ack, and
//  produce a fresh rising edge for the next transaction.  ack is stretched
//  to 2 clk_ram cycles so clk_sys-domain requesters sample it exactly once.
//============================================================================

module sdram_s32 (
    input             clk,          // clk_ram
    input             init,         // reset/init request
    output reg        ready,

    // SDRAM chip interface
    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output reg        SDRAM_nCS,
    output reg        SDRAM_nCAS,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nWE,
    output            SDRAM_CKE,

    // download/write port (word writes, ROM load)
    input             wr_req,
    input      [24:1] wr_addr,
    input      [15:0] wr_din,
    input       [1:0] wr_be,
    output reg        wr_ack,

    // p0: V60
    input             p0_req,
    input             p0_burst,
    input      [24:1] p0_addr,
    output reg [63:0] p0_dout,
    output reg        p0_ack,

    // p1: tiles — 4-word burst, aligned to 8 bytes
    input             p1_req,
    input      [24:3] p1_addr,
    output reg [63:0] p1_dout,
    output reg        p1_ack,

    // p2: sprites — 8-word burst, aligned to 16 bytes
    input             p2_req,
    input      [24:4] p2_addr,
    output reg [127:0] p2_dout,
    output reg        p2_ack,

    // p3: Z80
    input             p3_req,
    input      [24:1] p3_addr,
    output reg [15:0] p3_dout,
    output reg        p3_ack,

    // p4: MultiPCM
    input             p4_req,
    input      [24:1] p4_addr,
    output reg [15:0] p4_dout,
    output reg        p4_ack,

    // p5: V25 program ROM - 4-word burst, aligned to 8 bytes
    input             p5_req,
    input      [24:3] p5_addr,
    output reg [63:0] p5_dout,
    output reg        p5_ack
);

reg [15:0] dq_out;
reg        dq_oe;
reg  [1:0] dqm;

assign SDRAM_CKE  = 1'b1;
assign SDRAM_DQML = dqm[0];
assign SDRAM_DQMH = dqm[1];

localparam BURST_1   = 3'b000;
localparam CL        = 3'd2;

// commands {nCS,nRAS,nCAS,nWE}
localparam CMD_NOP   = 4'b0111;
localparam CMD_ACT   = 4'b0011;
localparam CMD_READ  = 4'b0101;
localparam CMD_WRITE = 4'b0100;
localparam CMD_PRE   = 4'b0010;
localparam CMD_REF   = 4'b0001;
localparam CMD_MRS   = 4'b0000;

reg  [3:0] cmd = CMD_NOP;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

// init sequencer
reg [15:0] init_cnt = 16'hffff;

// refresh: 8192 rows / 64 ms @85.909MHz -> every ~671 cycles
reg [9:0]  ref_cnt;
reg        ref_pend;

typedef enum logic [3:0] {
    ST_IDLE, ST_DISPATCH, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW,
    ST_WR, ST_WRRC, ST_PRE_XFER, ST_PRE_REF, ST_REF, ST_REFW
} state_t;
state_t state = ST_IDLE;

reg [2:0]  grant;
reg [2:0]  rr_next;
reg [3:0]  rd_total;        // words to read (1/4/8)
reg [3:0]  rd_issued;
reg [3:0]  rd_captured;
reg [24:1] xfer_addr;
reg        is_write;
reg        reuse_open_write_row;
reg [15:0] din_r;
reg [1:0]  be_r;
reg [2:0]  wrrc_cnt;
reg [2:0]  refw_cnt;
reg [1:0]  pre_cnt;
reg        row_open;
reg  [1:0] open_bank;
reg [12:0] open_row;
reg [1:0]  ack_stretch;     // 1 cycle here (single clock domain) -- see PROVENANCE.md

// Request mailboxes.  Capture every transaction's metadata with its request;
// arbitration may delay a lower-priority port long after the producer pulses
// req or moves on to its next address.  This mirrors the latched per-slot
// request interfaces used by mature MiSTer SDRAM frameworks.
reg p0_pend, p1_pend, p2_pend, p3_pend, p4_pend, p5_pend, wr_pend;
reg p0_burst_p;
reg [24:1] p0_addr_p, p3_addr_p, p4_addr_p, wr_addr_p;
reg [24:3] p1_addr_p;
reg [24:3] p5_addr_p;
reg [24:4] p2_addr_p;
reg [15:0] wr_din_p;
reg  [1:0] wr_be_p;

// Tile rendering has a hard scanline deadline: if p1 waits behind a complete
// six-port rotation, the renderer can miss the next line and the parity line
// buffer displays stale texture data. Give a newly pending p1 burst one
// deadline-priority credit. After that burst, one background reader must run
// before p1 can use the credit again. Preserve the background round-robin
// pointer across a priority p1 grant so repeated tile traffic cannot keep
// restarting background selection at the same port.
reg       read_valid;
reg [2:0] read_grant;
reg       p1_was_last;
reg       p1_priority_grant;
wire      background_pend = p0_pend | p2_pend | p3_pend | p4_pend | p5_pend;
wire      p1_fairness_block = p1_was_last & background_pend;
always @* begin
    read_valid = 1'b1;
    read_grant = rr_next;
    p1_priority_grant = 1'b0;
    if (p1_pend && !p1_was_last) begin
        read_grant = 3'd1;
        p1_priority_grant = 1'b1;
    end
    else begin
        case (rr_next)
            3'd0: if (p0_pend) read_grant=0; else if (p1_pend && !p1_fairness_block) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else read_valid=0;
            3'd1: if (p1_pend && !p1_fairness_block) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else read_valid=0;
            3'd2: if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend && !p1_fairness_block) read_grant=1; else read_valid=0;
            3'd3: if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend && !p1_fairness_block) read_grant=1; else if (p2_pend) read_grant=2; else read_valid=0;
            3'd4: if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend && !p1_fairness_block) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else read_valid=0;
            default: if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend && !p1_fairness_block) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else read_valid=0;
        endcase
    end
end

// Latch each port on the RISING EDGE of its request.  The previous
// level-sampled guard (req && !pend && !ack) had a one-clk_ram drop window: a
// requester that pulses its next request in direct response to an ack (the V60
// icache fill chain does) can present a 2-cycle pulse whose first cycle is
// blocked by the still-clearing pend and whose second is blocked by the
// stretched ack — the transaction vanished and the port hung forever.  Which
// transactions hit the window depended on each ack's clk_ram parity, i.e. on
// arbitration history — so adding V25 p5 traffic could sink the V60 while
// lighter boards never faulted.  Edge-detection latches exactly once per
// request pulse (or per level-request start: the loader holds wr_req until
// wr_ack) regardless of ack overlap.
reg p0_req_d, p1_req_d, p2_req_d, p3_req_d, p4_req_d, p5_req_d, wr_req_d;
reg p0_ack_d2, p1_ack_d2, p2_ack_d2, p3_ack_d2, p4_ack_d2, p5_ack_d2, wr_ack_d2;
always @(posedge clk) begin
    // Completion clears pend on the ack RISING EDGE only, and FIRST, so a
    // same-edge new request edge below overrides it (the later nonblocking
    // assignment wins).  Two hazards are closed together: (1) a chained
    // request whose rising edge lands on the very edge the previous ack
    // clears pend — the V60 icache fill pattern — latches instead of
    // vanishing; (2) the 2-cycle ack stretch must not wipe a request that
    // latched during the stretch window on the stretch's second cycle.
    p0_ack_d2 <= p0_ack; p1_ack_d2 <= p1_ack; p2_ack_d2 <= p2_ack;
    p3_ack_d2 <= p3_ack; p4_ack_d2 <= p4_ack; p5_ack_d2 <= p5_ack;
    wr_ack_d2 <= wr_ack;
    if (p0_ack && !p0_ack_d2) p0_pend <= 1'b0;
    if (p1_ack && !p1_ack_d2) p1_pend <= 1'b0;
    if (p2_ack && !p2_ack_d2) p2_pend <= 1'b0;
    if (p3_ack && !p3_ack_d2) p3_pend <= 1'b0;
    if (p4_ack && !p4_ack_d2) p4_pend <= 1'b0;
    if (p5_ack && !p5_ack_d2) p5_pend <= 1'b0;
    if (wr_ack && !wr_ack_d2) wr_pend <= 1'b0;
    p0_req_d <= p0_req; p1_req_d <= p1_req; p2_req_d <= p2_req;
    p3_req_d <= p3_req; p4_req_d <= p4_req; p5_req_d <= p5_req;
    wr_req_d <= wr_req;
    // Every s32 requester keeps at most one transaction outstanding (pulse, or
    // level held until ack), so an unqualified rising-edge latch is exact.
    if (p0_req && !p0_req_d) begin
        p0_pend <= 1'b1; p0_addr_p <= p0_addr;
        p0_burst_p <= p0_burst;
    end
    if (p1_req && !p1_req_d) begin
        p1_pend <= 1'b1; p1_addr_p <= p1_addr;
    end
    if (p2_req && !p2_req_d) begin
        p2_pend <= 1'b1; p2_addr_p <= p2_addr;
    end
    if (p3_req && !p3_req_d) begin
        p3_pend <= 1'b1; p3_addr_p <= p3_addr;
    end
    if (p4_req && !p4_req_d) begin
        p4_pend <= 1'b1; p4_addr_p <= p4_addr;
    end
    if (p5_req && !p5_req_d) begin
        p5_pend <= 1'b1; p5_addr_p <= p5_addr;
    end
    if (wr_req && !wr_req_d) begin
        wr_pend <= 1'b1; wr_addr_p <= wr_addr;
        wr_din_p <= wr_din; wr_be_p <= wr_be;
    end
    if (init) begin
        {p0_pend,p1_pend,p2_pend,p3_pend,p4_pend,p5_pend,wr_pend} <= '0;
        {p0_req_d,p1_req_d,p2_req_d,p3_req_d,p4_req_d,p5_req_d,wr_req_d} <= '0;
        {p0_ack_d2,p1_ack_d2,p2_ack_d2,p3_ack_d2,p4_ack_d2,p5_ack_d2,wr_ack_d2} <= '0;
        p0_addr_p <= '0; p1_addr_p <= '0; p2_addr_p <= '0;
        p0_burst_p <= 1'b0;
        p3_addr_p <= '0; p4_addr_p <= '0; p5_addr_p <= '0; wr_addr_p <= '0;
        wr_din_p <= '0; wr_be_p <= '0;
    end
end

`ifdef SIMULATION
// Contract watchdog (sim only): a request held high long after its pend
// cleared means the requester expects per-ack re-service from a level — the
// pre-edge-latch semantics.  It would receive exactly one transaction and
// hang silently in hardware; make that loud here.  Legitimate level holds
// drop within a few clk_ram of the stretched ack (clk_sys requesters take 2).
generate
    genvar gi;
    for (gi = 0; gi < 7; gi = gi + 1) begin : g_reqwatch
        reg [7:0] held;
        wire req_i  = gi==0 ? p0_req  : gi==1 ? p1_req  : gi==2 ? p2_req  :
                      gi==3 ? p3_req  : gi==4 ? p4_req  : gi==5 ? p5_req  : wr_req;
        wire pend_i = gi==0 ? p0_pend : gi==1 ? p1_pend : gi==2 ? p2_pend :
                      gi==3 ? p3_pend : gi==4 ? p4_pend : gi==5 ? p5_pend : wr_pend;
        always @(posedge clk) begin
            if (init || !req_i || pend_i) held <= 8'd0;
            else if (held != 8'hff) begin
                held <= held + 8'd1;
                if (held == 8'd200)
                    $display("SDRAM CONTRACT WARNING: port %0d req held %0d cycles after service — held levels are serviced once, not per ack", gi, held);
            end
        end
    end
endgenerate
`endif

// Centre the SDRAM board interface with SDRAM_CLK forwarded at 180 degrees.
// Commands and write data launched here have half a cycle of setup at the
// chip. CL2 read data returns to this direct pin-to-register sample under the
// SDC input-delay and multicycle constraints, so Quartus can place dq_in in
// the input IOE. The fourth pipe tap transfers the already-registered word
// into the response buffer one cycle later without a pin-to-core critical path.
reg [15:0] dq_in;
reg [3:0]  cl_pipe;
reg [15:0] cap_buf [0:7];

always @(posedge clk) dq_in <= SDRAM_DQ;

task automatic deliver(input [15:0] final_word);
    case (grant)
        // The final buffer write and delivery share an edge.  Use the staged
        // word directly for the last lane instead of returning stale cap_buf.
        3'd0: begin
            p0_dout <= (rd_total == 4'd4)
                       ? {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}
                       : {48'd0, final_word};
            p0_ack <= 1'b1;
        end
        3'd1: begin p1_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}; p1_ack <= 1'b1; end
        3'd2: begin p2_dout <= {final_word, cap_buf[6], cap_buf[5], cap_buf[4],
                                cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p2_ack <= 1'b1; end
        3'd3: begin p3_dout <= final_word; p3_ack <= 1'b1; end
        3'd4: begin p4_dout <= final_word; p4_ack <= 1'b1; end
        3'd5: begin p5_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}; p5_ack <= 1'b1; end
        default: ;
    endcase
endtask

always @(posedge clk) begin
    cmd    <= CMD_NOP;
    dq_oe  <= 1'b0;

    // acks: 1 cycle. Upstream holds 2 because its requesters run in a clk_sys
    // domain at clk_ram/2; we run single-domain, where a 2-cycle ack would make
    // valid twice as wide as every consumer expects.
    if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
    else begin
        p0_ack <= 1'b0; p1_ack <= 1'b0; p2_ack <= 1'b0;
        p3_ack <= 1'b0; p4_ack <= 1'b0; p5_ack <= 1'b0; wr_ack <= 1'b0;
    end

    if (init) begin
        init_cnt <= 16'hffff;
        ready    <= 1'b0;
        state    <= ST_IDLE;
        ref_pend <= 1'b0;
        ref_cnt  <= 10'd0;
        row_open <= 1'b0;
        open_bank <= 2'b00;
        open_row <= 13'd0;
        reuse_open_write_row <= 1'b0;
        pre_cnt <= 2'd0;
        dqm      <= 2'b11;
        cl_pipe  <= 4'b0000;
        ack_stretch <= 0;
        rr_next <= 3'd0;
        p1_was_last <= 1'b0;
    end
    else if (!ready) begin
        init_cnt <= init_cnt - 1'd1;
        dqm      <= 2'b11;
        // init: wait >100us, PRE-all, 8x REF, MRS (JEDEC)
        case (init_cnt)
            16'h0400: begin cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1; end
            16'h03c0, 16'h0380, 16'h0340, 16'h0300,
            16'h02c0, 16'h0280, 16'h0240, 16'h0200: cmd <= CMD_REF;
            16'h00a0: begin
                cmd      <= CMD_MRS;
                SDRAM_BA <= 2'b00;
                SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
            end
            16'h0001: ready <= 1'b1;
            default: ;
        endcase
    end
    else begin
        dqm <= 2'b00;
        // refresh scheduling: 8192 rows / 64ms @ 85.909MHz -> every 671 cyc
        ref_cnt <= ref_cnt + 1'd1;
        if (ref_cnt == 10'd620) begin ref_cnt <= 0; ref_pend <= 1'b1; end

        // Read capture after CL2 and the centred IOE register above.
        cl_pipe <= {cl_pipe[2:0], 1'b0};
        if (cl_pipe[3]) begin
            cap_buf[rd_captured[2:0]] <= dq_in;
            rd_captured <= rd_captured + 1'd1;
            if (rd_captured + 1'd1 == rd_total) begin
                deliver(dq_in);
                ack_stretch <= 2'd0;   // single-domain: ack is 1 cycle
            end
        end

        case (state)
        ST_IDLE: begin
            if (ref_pend && cl_pipe == 0) begin
                cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;
                row_open <= 1'b0;
                refw_cnt <= 3'd1;             // tRP >= 2 cycles before REF
                state <= ST_PRE_REF;
            end
            else if (wr_pend | read_valid) begin
                logic [24:1] a;
                if      (wr_pend) begin grant <= 3'd7; a = wr_addr_p;           rd_total <= 4'd1; is_write <= 1'b1; end
                else begin
                    grant <= read_grant;
                    is_write <= 1'b0;
                    p1_was_last <= (read_grant == 3'd1);
                    if (!p1_priority_grant)
                        rr_next <= (read_grant == 3'd5) ? 3'd0 : read_grant + 1'd1;
                    case (read_grant)
                        3'd0: begin
                            // Cache-line fills are exactly four aligned words;
                            // protection and other exact reads stay single-word.
                            a = p0_burst_p ? {p0_addr_p[24:3], 2'b00} : p0_addr_p;
                            rd_total <= p0_burst_p ? 4'd4 : 4'd1;
                        end
                        3'd1: begin a = {p1_addr_p, 2'b00};  rd_total <= 4'd4; end
                        3'd2: begin a = {p2_addr_p, 3'b000}; rd_total <= 4'd8; end
                        3'd3: begin a = p3_addr_p;           rd_total <= 4'd1; end
                        3'd4: begin a = p4_addr_p;           rd_total <= 4'd1; end
                        default: begin a = {p5_addr_p, 2'b00}; rd_total <= 4'd4; end
                    endcase
                end
                xfer_addr <= a;
                // The selected address and transfer type are already stable at
                // this arbitration boundary.  Register the row-reuse decision
                // here so ST_DISPATCH does not place the bank/row comparator in
                // the SDRAM command-output timing cone.
                reuse_open_write_row <= wr_pend && row_open &&
                                        a[24:23] == open_bank &&
                                        a[22:10] == open_row;
                din_r     <= wr_din_p;
                be_r      <= wr_be_p;
                rd_issued   <= 0;
                rd_captured <= 0;
                // Register arbitration before command generation.  The
                // dedicated dispatch cycle breaks the dense real-V25 path
                // from p5_pend through the six-port priority mux and row
                // decision into cmd[].  Requesters already wait for ack, so
                // the extra clk_ram cycle changes latency but not semantics.
                state <= ST_DISPATCH;
            end
        end

        ST_DISPATCH: begin
            // A same-row download write can reuse the active row. Every other
            // transfer first closes the row explicitly so reads retain their
            // original ACT/auto-precharge behavior.
            if (reuse_open_write_row) begin
                state <= ST_WR;
            end
            else if (row_open) begin
                cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;
                row_open <= 1'b0;
                pre_cnt <= 2'd1;          // tRP >= 2 cycles before ACT
                state <= ST_PRE_XFER;
            end
            else begin
                state <= ST_ACT;
            end
        end

        ST_PRE_XFER: begin
            if (pre_cnt == 0) state <= ST_ACT;
            else pre_cnt <= pre_cnt - 1'd1;
        end

        ST_ACT: begin
            cmd      <= CMD_ACT;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= xfer_addr[22:10];
            open_bank <= xfer_addr[24:23];
            open_row  <= xfer_addr[22:10];
            row_open  <= 1'b1;
            state    <= ST_RCD1;
        end

        // tRCD >= 21ns = 3 cycles ACT->READ/WRITE
        ST_RCD1: state <= ST_RCD2;
        ST_RCD2: begin
            if (is_write) state <= ST_WR;
            else          state <= ST_RD;
        end

        ST_WR: begin
            cmd      <= CMD_WRITE;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= {2'b00, 1'b0, xfer_addr[10:1]};  // keep row open
            dq_out   <= din_r;
            dq_oe    <= 1'b1;
            dqm      <= ~be_r;
            // No auto-precharge is used for download writes. The conservative
            // two-cycle write-recovery gap is enough before another WRITE on
            // the same row and still leaves explicit precharge for row changes.
            wrrc_cnt <= 3'd2;
            state    <= ST_WRRC;
        end
        ST_WRRC: begin
            if (wrrc_cnt == 3'd2) begin wr_ack <= 1'b1; ack_stretch <= 2'd0; end
            if (wrrc_cnt == 0) state <= ST_IDLE;
            else wrrc_cnt <= wrrc_cnt - 1'd1;
        end

        ST_RD: begin
            // issue one READ per cycle until rd_total issued
            cmd      <= CMD_READ;
            SDRAM_BA <= xfer_addr[24:23];
            SDRAM_A  <= {2'b00, (rd_issued + 1'd1 == rd_total) ? 1'b1 : 1'b0,
                         xfer_addr[10:1]};
            cl_pipe[0] <= 1'b1;
            xfer_addr[10:1] <= xfer_addr[10:1] + 1'd1;
            rd_issued <= rd_issued + 1'd1;
            if (rd_issued + 1'd1 == rd_total) begin
                row_open <= 1'b0; // final CAS requests auto-precharge
                state <= ST_RDW;
            end
        end
        ST_RDW: begin
            // wait for capture pipeline to finish (delivery in capture logic);
            // also cover tRC for the single-read case with the drain cycles
            if (cl_pipe == 0) state <= ST_IDLE;
        end

        ST_PRE_REF: begin
            if (refw_cnt == 0) begin
                cmd      <= CMD_REF;
                row_open <= 1'b0;
                ref_pend <= 1'b0;
                refw_cnt <= 3'd6;   // tRC(ref) >= 63ns = 7 cycles
                state    <= ST_REFW;
            end
            else refw_cnt <= refw_cnt - 1'd1;
        end
        ST_REF: state <= ST_REFW;   // (unused; kept for enum stability)
        ST_REFW: begin
            if (refw_cnt == 0) state <= ST_IDLE;
            else refw_cnt <= refw_cnt - 1'd1;
        end
        default: state <= ST_IDLE;
        endcase
    end
end

endmodule
