// Routes two req/valid read-only consumers onto one sdram_phy port --
// same round-robin/hold-until-ack design as ddram_arbiter.sv (fixed-pointer
// rotation: whoever's served rotates to the back, so sustained pressure from
// one consumer can't starve the other), just narrowed to two consumers and
// no download-write path, matching docs/phase1_sdram_map.md's port-grouping
// table (Port 0: tilemap layer 0 + 1 gfxrom; Port 1: sprite gfxrom +
// spritelut -- two instances of this same module cover both groups).
//
// Request contract, both ports (c0_req/c1_req): HOLD req asserted until the
// matching valid acknowledgment -- same reasoning as ddram_arbiter.sv (a
// one-shot pulse would be lost if it arrived while the arbiter was busy
// serving the other consumer).

module sdram_arbiter2 (
    input  logic clk,
    input  logic reset,

    // physical port (to sdram_phy)
    output logic         phy_req,
    output logic [24:0] phy_addr,
    input  logic         phy_busy,
    input  logic         phy_valid,
    input  logic [63:0] phy_rdata,

    // consumer 0
    input  logic         c0_req,
    input  logic [24:0] c0_addr,
    output logic         c0_valid,
    output logic [63:0] c0_data,

    // consumer 1
    input  logic         c1_req,
    input  logic [24:0] c1_addr,
    output logic         c1_valid,
    output logic [63:0] c1_data
);

    typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT} astate_t;
    astate_t astate;

    logic sel;       // 0 = consumer 0, 1 = consumer 1
    logic rr_ptr;    // which consumer round-robin favors next

    logic next_sel;
    logic found;
    always_comb begin
        if (rr_ptr == 1'b0) begin
            if      (c0_req) begin next_sel = 1'b0; found = 1'b1; end
            else if (c1_req) begin next_sel = 1'b1; found = 1'b1; end
            else              begin next_sel = 1'b0; found = 1'b0; end
        end else begin
            if      (c1_req) begin next_sel = 1'b1; found = 1'b1; end
            else if (c0_req) begin next_sel = 1'b0; found = 1'b1; end
            else              begin next_sel = 1'b0; found = 1'b0; end
        end
    end

    assign phy_addr = sel ? c1_addr : c0_addr;
    assign phy_req  = (astate == A_ISSUE) && !phy_busy;

    assign c0_valid = (astate == A_WAIT) && !sel && phy_valid;
    assign c1_valid = (astate == A_WAIT) &&  sel && phy_valid;
    assign c0_data  = phy_rdata;
    assign c1_data  = phy_rdata;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            astate <= A_IDLE;
            rr_ptr <= 1'b0;
        end else begin
            case (astate)
                A_IDLE: begin
                    if (found) begin
                        sel    <= next_sel;
                        astate <= A_ISSUE;
                    end
                end

                A_ISSUE: begin
                    if (!phy_busy) astate <= A_WAIT;
                end

                A_WAIT: begin
                    if (phy_valid) begin
                        rr_ptr <= ~sel;
                        astate <= A_IDLE;
                    end
                end

                default: ;
            endcase
        end
    end

endmodule
