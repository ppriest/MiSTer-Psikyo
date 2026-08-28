`timescale 1ns/1ps

//============================================================================
// Behavioural SDR SDRAM chip model (CL2, burst length 1) for closed-loop
// controller tests.  Unlike the abstract request/ack models it obeys the real
// command protocol, honours DQML/DQMH byte masks on writes, stores RAW words
// (no inversion knowledge of any client), and faults on protocol violations.
//
// Address reconstruction mirrors rtl/mem/sdram.sv exactly:
//   bank = a[24:23], row = a[22:10], col = a[10:1]
// so a[10] appears as both row[0] and col[9].  The model asserts that the two
// copies agree, which catches a controller row/column split regression.
// Storage is a WINDOW of WORDS words starting at word address BASE_WORD; any
// access outside it is a test-setup error and is reported.
//============================================================================

module s32_sdr_chip_model #(
    parameter [23:0] BASE_WORD = 24'h500000,
    parameter integer WORDS    = 32768
) (
    input             clk,
    inout      [15:0] SDRAM_DQ,
    input      [12:0] SDRAM_A,
    input       [1:0] SDRAM_BA,
    input             SDRAM_DQML,
    input             SDRAM_DQMH,
    input             SDRAM_nCS,
    input             SDRAM_nCAS,
    input             SDRAM_nRAS,
    input             SDRAM_nWE
);

localparam [3:0] C_NOP   = 4'b0111;
localparam [3:0] C_ACT   = 4'b0011;
localparam [3:0] C_READ  = 4'b0101;
localparam [3:0] C_WRITE = 4'b0100;
localparam [3:0] C_PRE   = 4'b0010;
localparam [3:0] C_REF   = 4'b0001;
localparam [3:0] C_MRS   = 4'b0000;

wire [3:0] cmd = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};

reg [15:0] mem [0:WORDS-1];
reg        row_open [0:3];
reg [12:0] act_row  [0:3];

integer    oob_errors = 0;
integer    proto_errors = 0;
integer    writes_seen = 0;
integer    reads_seen = 0;

reg [15:0] dq_p1, dq_p2;
reg        oe_p1, oe_p2;
assign SDRAM_DQ = oe_p2 ? dq_p2 : 16'hzzzz;

integer i;
initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'h0000;
    for (i = 0; i < 4; i = i + 1) begin row_open[i] = 1'b0; act_row[i] = 13'd0; end
    dq_p1 = 16'h0000; dq_p2 = 16'h0000; oe_p1 = 1'b0; oe_p2 = 1'b0;
end

function automatic integer word_index(input [1:0] bank, input [12:0] row,
                                      input [9:0] col);
    reg [23:0] a;
    begin
        // a[24:1]: {bank, a[22:11], a[10:1]}; row[0] must equal col[9].
        a = {bank, row[12:1], col};
        word_index = a - BASE_WORD;
    end
endfunction

task automatic check_access(input [1:0] bank, input [12:0] row, input [9:0] col,
                            input [255:0] what);
    begin
        if (row[0] !== col[9]) begin
            $display("SDRCHIP PROTOCOL: %0s row[0]=%b != col[9]=%b (bank %0d row %h col %h)",
                     what, row[0], col[9], bank, row, col);
            proto_errors = proto_errors + 1;
        end
    end
endtask

always @(posedge clk) begin
    // ---- read data pipeline: CL2 ----
    oe_p1 <= 1'b0;
    dq_p1 <= 16'hxxxx;
    dq_p2 <= dq_p1;
    oe_p2 <= oe_p1;

    case (cmd)
        C_ACT: begin
            row_open[SDRAM_BA] <= 1'b1;
            act_row[SDRAM_BA]  <= SDRAM_A;
        end

        C_PRE: begin
            if (SDRAM_A[10]) begin
                row_open[0] <= 1'b0; row_open[1] <= 1'b0;
                row_open[2] <= 1'b0; row_open[3] <= 1'b0;
            end
            else row_open[SDRAM_BA] <= 1'b0;
        end

        C_READ: begin
            reads_seen = reads_seen + 1;
            if (!row_open[SDRAM_BA]) begin
                $display("SDRCHIP PROTOCOL: READ with no open row on bank %0d", SDRAM_BA);
                proto_errors = proto_errors + 1;
            end
            check_access(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0], "READ");
            if (word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]) < 0 ||
                word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]) >= WORDS) begin
                $display("SDRCHIP OOB READ bank %0d row %h col %h -> idx %0d",
                         SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0],
                         word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]));
                oob_errors = oob_errors + 1;
                dq_p1 <= 16'hdead;
            end
            else
                dq_p1 <= mem[word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])];
            oe_p1 <= 1'b1;
            if (SDRAM_A[10]) row_open[SDRAM_BA] <= 1'b0;   // auto-precharge
        end

        C_WRITE: begin
            writes_seen = writes_seen + 1;
            if (!row_open[SDRAM_BA]) begin
                $display("SDRCHIP PROTOCOL: WRITE with no open row on bank %0d", SDRAM_BA);
                proto_errors = proto_errors + 1;
            end
            check_access(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0], "WRITE");
            if (word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]) < 0 ||
                word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]) >= WORDS) begin
                $display("SDRCHIP OOB WRITE bank %0d row %h col %h",
                         SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0]);
                oob_errors = oob_errors + 1;
            end
            else begin
                if (!SDRAM_DQML)
                    mem[word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])][7:0]
                        <= SDRAM_DQ[7:0];
                if (!SDRAM_DQMH)
                    mem[word_index(SDRAM_BA, act_row[SDRAM_BA], SDRAM_A[9:0])][15:8]
                        <= SDRAM_DQ[15:8];
            end
            if (SDRAM_A[10]) row_open[SDRAM_BA] <= 1'b0;
        end

        C_REF: begin
            row_open[0] <= 1'b0; row_open[1] <= 1'b0;
            row_open[2] <= 1'b0; row_open[3] <= 1'b0;
        end

        default: ;
    endcase
end

endmodule
