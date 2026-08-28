// Routes Port 2's six logical consumers (per docs/phase1_sdram_map.md's
// "Arbiter architecture" table: sprite gfxrom, sprite spritelut, maincpu
// program fetch, audiocpu program fetch, HPS ioctl_download) onto one
// physical sdram_phy port.
//
// Design reused byte-for-byte from rtl/memory/ddram_arbiter.sv, not
// reinvented: same hold-until-ack round-robin among the four read
// consumers, same "download always wins immediately" absolute-priority
// write path (only active during ROM loading, before gameplay starts, so
// it can't cost anything at runtime -- see ddram_arbiter.sv's own header
// for the reasoning). The only real difference is the physical port shape:
// sdram_phy's client interface is a 25-bit byte address into the 32MB SDR
// SDRAM chip (docs/phase1_sdram_map.md), not ddram_phy's 28-bit DDRAM
// window -- everything else about the req/we/addr/wdata/busy/valid/rdata
// contract lines up exactly, which is what made reusing the design directly
// possible instead of redesigning from scratch.
//
// Read consumers all speak the same 64-bit-granule contract sdram_phy's
// read side provides (8-byte-aligned address in, full burst-4 granule out)
// -- callers narrower than 64 bits (spritelut's 16-bit words, maincpu's
// 16-bit fetch, audiocpu's 8-bit fetch) sit behind rtl/memory/
// sdram_narrow_bridge.sv, which is NOT part of this module: this arbiter
// only knows about 64-bit granules, matching sdram_phy/sdram.sv exactly, so
// it stays a pure transport-layer module with no per-consumer width
// knowledge (same "no notion of regions" posture ddram_arbiter documents
// for addresses).
//
// c0: sprite gfxrom (already 64-bit-granule-native, connects directly, no
//     bridge needed -- see rtl/video/sprite_render_engine.sv's
//     gfx-ROM-row-address comment: always ends in 3'b000, i.e. always
//     8-byte-aligned).
// c1: sprite spritelut (via sdram_narrow_bridge, WORD_BYTES=2)
// c2: maincpu program fetch (via sdram_narrow_bridge, WORD_BYTES=2 --
//     68020, no real wrapper RTL exists yet, see docs/phase1_sdram_map.md)
// c3: audiocpu program fetch (via sdram_narrow_bridge, WORD_BYTES=1 --
//     Z80, blocked on the sound-CPU req/valid conversion bug, see
//     docs/ROADMAP.md -- this arbiter doesn't care, it only sees req/valid)

module sdram_arbiter6 (
    input  logic clk,
    input  logic reset,

    // physical port (to sdram_phy)
    output logic         phy_req,
    output logic         phy_we,
    output logic [24:0] phy_addr,
    output logic [7:0]  phy_wdata,
    input  logic         phy_busy,
    input  logic         phy_valid,
    input  logic [63:0] phy_rdata,

    // consumer 0: sprite gfxrom
    input  logic         c0_req,
    input  logic [24:0] c0_addr,
    output logic         c0_valid,
    output logic [63:0] c0_data,

    // consumer 1: sprite spritelut
    input  logic         c1_req,
    input  logic [24:0] c1_addr,
    output logic         c1_valid,
    output logic [63:0] c1_data,

    // consumer 2: maincpu program fetch
    input  logic         c2_req,
    input  logic [24:0] c2_addr,
    output logic         c2_valid,
    output logic [63:0] c2_data,

    // consumer 3: audiocpu program fetch
    input  logic         c3_req,
    input  logic [24:0] c3_addr,
    output logic         c3_valid,
    output logic [63:0] c3_data,

    // consumer 4: YM2610 ADPCM-A samples. Very low bandwidth -- 6 channels at
    // ~18.5 kHz is about one byte every 1.5 us aggregate, roughly 130 clk at
    // 85.909 MHz -- so it costs the round robin almost nothing.
    input  logic         c4_req,
    input  logic [24:0] c4_addr,
    output logic         c4_valid,
    output logic [63:0] c4_data,

    // HPS ROM-download write path -- absolute priority, hold dl_req until
    // dl_busy asserts (matches ddram_arbiter's own dl_req contract, NOT
    // hps_io's raw one-shot ioctl_wr pulse -- see rtl/memory/
    // sdram_download.sv for the translation layer)
    input  logic         dl_req,
    input  logic [24:0] dl_addr,
    input  logic [7:0]  dl_data,
    output logic         dl_busy
);

    logic [4:0] c_req;
    logic [24:0] c_addr [0:4];
    assign c_req    = {c4_req, c3_req, c2_req, c1_req, c0_req};
    assign c_addr[0] = c0_addr;
    assign c_addr[1] = c1_addr;
    assign c_addr[2] = c2_addr;
    assign c_addr[3] = c3_addr;
    assign c_addr[4] = c4_addr;

    typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT_READ, A_WAIT_WRITE} astate_t;
    astate_t astate;

    logic [2:0] rr_ptr;
    logic [2:0] sel;
    logic         sel_is_dl;

    // combinational round-robin picker: starting at rr_ptr, find the first
    // requesting channel (wrapping mod 4)
    logic [2:0] next_sel;
    logic         found;
    always_comb begin
        found    = 1'b0;
        next_sel = rr_ptr;
        for (int i = 0; i < 5; i++) begin
            logic [3:0] sum;   // 4 bits: rr_ptr(<=4) + i(<=4) = up to 8 --
                                // the previous 3-bit sum wrapped 4+4 to 0
                                // BEFORE the >=5 check, so with rr_ptr==4
                                // the scan set was {4,0,1,2,0}: client 3
                                // was NEVER scanned. rr_ptr becomes 4
                                // exactly after serving client 3, so a
                                // solo c3 requester (the audiocpu with no
                                // other traffic -- reproduced by
                                // tb_sound_irq_sdram.sv hanging on its
                                // second ROM granule fetch) deadlocked;
                                // with other clients active it "only"
                                // starved c3 until someone else's request
                                // advanced the pointer.
            sum = {1'b0, rr_ptr} + i[3:0];
            if (sum >= 4'd5) sum = sum - 4'd5;
            if (!found && c_req[sum[2:0]]) begin
                next_sel = sum[2:0];
                found    = 1'b1;
            end
        end
    end

    assign dl_busy = (astate != A_IDLE) && sel_is_dl;

    assign phy_addr  = sel_is_dl ? dl_addr : c_addr[sel];
    assign phy_wdata = dl_data;
    assign phy_we    = sel_is_dl;
    assign phy_req   = (astate == A_ISSUE) && !phy_busy;

    assign c0_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd0) && phy_valid;
    assign c1_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd1) && phy_valid;
    assign c2_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd2) && phy_valid;
    assign c3_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd3) && phy_valid;
    assign c0_data  = phy_rdata;
    assign c1_data  = phy_rdata;
    assign c2_data  = phy_rdata;
    assign c3_data  = phy_rdata;
    assign c4_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd4) && phy_valid;
    assign c4_data  = phy_rdata;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            astate <= A_IDLE;
            rr_ptr <= 3'd0;
            sel_is_dl <= 1'b0;
        end else begin
            case (astate)
                A_IDLE: begin
                    if (dl_req) begin
                        sel_is_dl <= 1'b1;
                        astate    <= A_ISSUE;
                    end else if (found) begin
                        sel       <= next_sel;
                        sel_is_dl <= 1'b0;
                        astate    <= A_ISSUE;
                    end
                end

                A_ISSUE: begin
                    // phy_req pulsed this cycle (combinational, gated by
                    // !phy_busy). Once accepted, move to the matching wait
                    // state; if phy_busy was unexpectedly still high (should
                    // not happen given this arbiter fully serializes access
                    // to sdram_phy), simply retry next cycle.
                    if (!phy_busy) astate <= sel_is_dl ? A_WAIT_WRITE : A_WAIT_READ;
                end

                A_WAIT_READ: begin
                    if (phy_valid) begin
                        rr_ptr <= (sel == 3'd4) ? 3'd0 : sel + 3'd1;
                        astate <= A_IDLE;
                    end
                end

                A_WAIT_WRITE: begin
                    if (!phy_busy) astate <= A_IDLE;
                end
            endcase
        end
    end

endmodule
