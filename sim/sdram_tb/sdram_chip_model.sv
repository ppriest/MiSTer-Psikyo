// Behavioral stand-in for a real MT48LC16M16 SDR SDRAM chip, used only in
// simulation. Unlike a black-box latency stub, this decodes the actual
// {SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE} command encoding (ACTIVE/READ/WRITE/
// PRECHARGE/AUTO_REFRESH/LOAD_MODE, matching rtl/memory/sdram/sdram.sv's own
// CMD_* localparams) and the real mode-register CAS-latency/burst-length
// fields (decoded from a real LOAD_MODE command, not hardcoded to match
// whatever the controller happens to send) -- so a wiring bug in the
// controller's burst-4 extension (see rtl/memory/sdram/PROVENANCE.md) shows
// up as a real protocol violation (reading before CAS latency has elapsed,
// wrong burst length, DQ bus contention) rather than being silently
// tolerated by an overly-permissive model.
//
// Backing store is word-indexed by {bank, row[7:0], col[8:0]} -- row is
// folded to its low 8 bits (not the full 13), matching ddram_model.sv's
// precedent of sizing the array for what testbenches actually exercise
// rather than the full physical chip capacity.
//
// Single-outstanding-transaction assumption, inherited from the controller
// this model is paired with: sdram.sv never issues a new READ/WRITE while a
// previous read's burst is still draining, so this model doesn't need to
// handle overlapping in-flight reads.

module sdram_chip_model (
    input  logic         clk,

    inout  wire  [15:0] SDRAM_DQ,
    input  logic [12:0] SDRAM_A,
    input  logic  [1:0] SDRAM_BA,
    input  logic         SDRAM_nCS,
    input  logic         SDRAM_nWE,
    input  logic         SDRAM_nRAS,
    input  logic         SDRAM_nCAS
);

    localparam logic [2:0] CMD_NOP          = 3'b111;
    localparam logic [2:0] CMD_ACTIVE       = 3'b011;
    localparam logic [2:0] CMD_READ         = 3'b101;
    localparam logic [2:0] CMD_WRITE        = 3'b100;
    localparam logic [2:0] CMD_PRECHARGE    = 3'b010;
    localparam logic [2:0] CMD_AUTO_REFRESH = 3'b001;
    localparam logic [2:0] CMD_LOAD_MODE    = 3'b000;

    wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};

    // addr_of concatenates {bank[1:0], row[7:0], col[8:0]} = 19 bits, so the
    // full range is 4 banks * 256 (folded rows) * 512 cols = 2^19 = 524288,
    // not 2^17 -- an earlier, undersized [0:131071] silently went out of
    // bounds for any bank >= 1 (reads returned X, writes were discarded),
    // caught by tb_video_pipeline_sdram.sv when every real read came back X
    // despite the address math itself being correct end to end.
    logic [15:0] mem [0:524287];

    function automatic int unsigned addr_of(input logic [1:0] bank, input logic [7:0] row, input logic [8:0] col);
        addr_of = {bank, row, col};
    endfunction

    logic [12:0] open_row [0:1];
    logic [12:0] mode_reg;
    wire  [2:0] cas_latency_field  = mode_reg[6:4];
    wire  [2:0] burst_length_field = mode_reg[2:0];
    wire  [4:0] burst_words        = 5'd1 << burst_length_field;   // 0=1,1=2,2=4,3=8

    typedef enum logic [1:0] {R_IDLE, R_WAIT_CAS, R_DRIVE} rstate_t;
    rstate_t rstate = R_IDLE;
    int          rcount;
    logic [8:0] rcol;
    logic [1:0] rbank;
    int          rburst_left;

    logic         driving;
    logic [15:0] drive_word;

    assign SDRAM_DQ = driving ? drive_word : 16'bz;

    // Array-index expressions containing a nested function call, used
    // directly as the LHS/RHS of a nonblocking assignment, crash this
    // toolchain's front end (vlog 10.5b, "unexpected internal error" at
    // vgenexpr.c) -- worked around by computing the flat index into a plain
    // variable first, then indexing `mem` with that. No behavioral
    // difference, just avoids the compiler bug.
    always_ff @(posedge clk) begin
        int unsigned widx;

        driving <= 1'b0;

        unique case (cmd)
            CMD_ACTIVE:    open_row[SDRAM_BA] <= SDRAM_A;
            CMD_LOAD_MODE: mode_reg <= SDRAM_A;
            CMD_WRITE: begin
                // DQM byte-lane mask rides on SDRAM_A[12:11] (DQMH:DQML)
                // during the same command cycle -- matches sdram.sv's own
                // `SDRAM_A <= {dqm, 2'b10, a[9:1]}` at STATE_CONT, and the
                // real MT48LC16M16 convention (mask=1 means don't write
                // that byte). Previously ignored entirely (always wrote the
                // full 16 bits regardless of mask) -- caught by tb_sdram.sv
                // Case 2, which found a masked write clobbering the
                // untouched byte lane instead of preserving it.
                widx = addr_of(SDRAM_BA, open_row[SDRAM_BA][7:0], SDRAM_A[8:0]);
                if (!SDRAM_A[11]) mem[widx][7:0]  <= SDRAM_DQ[7:0];
                if (!SDRAM_A[12]) mem[widx][15:8] <= SDRAM_DQ[15:8];
            end
            CMD_READ: begin
                rstate      <= R_WAIT_CAS;
                // -2, not -1: entering R_WAIT_CAS itself consumes the first
                // of the CAS_LATENCY cycles (this same always_ff block can't
                // act on the new rstate until the following edge), so only
                // CAS_LATENCY-2 further countdown cycles are needed before
                // the "trigger drive" check can fire on time. Verified
                // against a real command-to-data cycle trace (see
                // PROVENANCE.md) -- this was originally -1 and produced data
                // one cycle late (3 cycles instead of CAS_LATENCY=2).
                rcount      <= int'(cas_latency_field) - 2;
                rcol        <= SDRAM_A[8:0];
                rbank       <= SDRAM_BA;
                rburst_left <= int'(burst_words);
            end
            default: ; // NOP / PRECHARGE / AUTO_REFRESH: nothing to model
        endcase

        unique case (rstate)
            R_IDLE: ; // handled by CMD_READ above
            R_WAIT_CAS: begin
                if (rcount <= 0) begin
                    rstate      <= R_DRIVE;
                    driving     <= 1'b1;
                    widx        = addr_of(rbank, open_row[rbank][7:0], rcol);
                    drive_word  <= mem[widx];
                    rburst_left <= rburst_left - 1;
                    rcol        <= rcol + 9'd1;
                end else begin
                    rcount <= rcount - 1;
                end
            end
            R_DRIVE: begin
                if (rburst_left > 0) begin
                    driving     <= 1'b1;
                    widx        = addr_of(rbank, open_row[rbank][7:0], rcol);
                    drive_word  <= mem[widx];
                    rburst_left <= rburst_left - 1;
                    rcol        <= rcol + 9'd1;
                end else begin
                    rstate <= R_IDLE;
                end
            end
        endcase
    end

    // testbench-only backdoor for pre-seeding/checking memory contents
    // directly, addressed the same way rtl/memory/sdram/sdram.sv's own
    // 24-bit word address decomposes: bank = addr[24:23]-ish is not how the
    // real controller splits it (see sdram.sv's {ba,a} <= addr0 and the
    // STATE_START/STATE_CONT row/col split) -- callers should use
    // word_addr_to_chip() below rather than assuming a direct mapping.
    function automatic void poke_word(input logic [1:0] bank, input logic [7:0] row, input logic [8:0] col, input logic [15:0] data);
        mem[addr_of(bank, row, col)] = data;
    endfunction

    function automatic logic [15:0] peek_word(input logic [1:0] bank, input logic [7:0] row, input logic [8:0] col);
        return mem[addr_of(bank, row, col)];
    endfunction

    // Mirrors sdram.sv's own (burst-4-adapted) address decomposition
    // exactly: {ba,a} <= addr0 (addr0[24:23]=bank, a=addr0[22:1]),
    // col=a[9:1] (=addr0[9:1], LOW bits -- what a hardware burst
    // auto-increments), row=a[22:10] (=addr0[22:10], HIGH bits) -- swapped
    // from upstream's row/col split, see rtl/memory/sdram/PROVENANCE.md for
    // why. Takes word_addr as a plain 24-bit value (bit i here == addr0's
    // bit i+1, same bit pattern, just 0-indexed for a cleaner leaf-function
    // signature).
    function automatic void poke_word_addr(input logic [23:0] word_addr, input logic [15:0] data);
        poke_word(word_addr[23:22], word_addr[16:9], word_addr[8:0], data);
    endfunction

    function automatic logic [15:0] peek_word_addr(input logic [23:0] word_addr);
        return peek_word(word_addr[23:22], word_addr[16:9], word_addr[8:0]);
    endfunction

endmodule
