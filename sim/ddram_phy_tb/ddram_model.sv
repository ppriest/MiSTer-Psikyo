// Behavioral stand-in for the real DDRAM_* physical interface, used only in
// simulation. Deliberately configurable read latency and post-accept busy
// duration so ddram_phy_tb can run against two independently-parameterized
// instances (see sprite_render_engine_tb's "independently-latencied ROM
// models" precedent) to rule out timing-dependent bugs rather than proving
// correctness against only one arbitrary latency value.

module ddram_model #(
    parameter int READ_LATENCY = 6,   // cycles from RD accept to the DOUT_READY pulse
    parameter int BUSY_CYCLES  = 2    // cycles DDRAM_BUSY stays high after accepting a request
) (
    input  logic         clk,
    input  logic         reset,

    output logic         DDRAM_BUSY,
    input  logic [7:0]  DDRAM_BURSTCNT,
    input  logic [28:0] DDRAM_ADDR,
    output logic [63:0] DDRAM_DOUT,
    output logic         DDRAM_DOUT_READY,
    input  logic         DDRAM_RD,
    input  logic [63:0] DDRAM_DIN,
    input  logic [7:0]  DDRAM_BE,
    input  logic         DDRAM_WE
);

    // 1024 granules (8KB) of backing store, indexed by the low address bits
    // actually exercised in testing -- plenty for this testbench's range.
    logic [7:0] mem [0:8191];

    logic [9:0] granule_idx;
    assign granule_idx = DDRAM_ADDR[9:0];

    typedef enum logic [1:0] {M_IDLE, M_BUSY, M_READ_WAIT} mstate_t;
    mstate_t mstate;

    int busy_cnt;
    int read_cnt;

    assign DDRAM_BUSY = (mstate != M_IDLE);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            mstate           <= M_IDLE;
            DDRAM_DOUT_READY <= 1'b0;
            DDRAM_DOUT       <= 64'h0;
        end else begin
            DDRAM_DOUT_READY <= 1'b0;

            case (mstate)
                M_IDLE: begin
                    if (DDRAM_WE) begin
                        for (int lane = 0; lane < 8; lane++) begin
                            if (DDRAM_BE[lane]) mem[granule_idx*8 + lane] <= DDRAM_DIN[lane*8 +: 8];
                        end
                        busy_cnt <= BUSY_CYCLES;
                        mstate   <= M_BUSY;
                    end else if (DDRAM_RD) begin
                        DDRAM_DOUT <= {mem[granule_idx*8+7], mem[granule_idx*8+6],
                                       mem[granule_idx*8+5], mem[granule_idx*8+4],
                                       mem[granule_idx*8+3], mem[granule_idx*8+2],
                                       mem[granule_idx*8+1], mem[granule_idx*8+0]};
                        read_cnt <= READ_LATENCY;
                        mstate   <= M_READ_WAIT;
                    end
                end

                M_BUSY: begin
                    if (busy_cnt == 0) mstate <= M_IDLE;
                    else                busy_cnt <= busy_cnt - 1;
                end

                M_READ_WAIT: begin
                    if (read_cnt == 0) begin
                        DDRAM_DOUT_READY <= 1'b1;
                        mstate           <= M_IDLE;
                    end else begin
                        read_cnt <= read_cnt - 1;
                    end
                end
            endcase
        end
    end

    // testbench-only backdoor for pre-seeding/checking memory contents directly
    function automatic void poke_byte(input int byte_addr, input logic [7:0] data);
        mem[byte_addr] = data;
    endfunction

    function automatic logic [7:0] peek_byte(input int byte_addr);
        return mem[byte_addr];
    endfunction

endmodule
