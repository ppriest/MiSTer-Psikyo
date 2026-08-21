// Bridges a narrow (byte- or word-wide) req/valid read port onto a
// 64-bit-granule sdram_arbiter5/sdram_phy consumer port. Exists because
// sdram.sv's burst-4 controller only ever hands back a full 8-byte-aligned
// granule (rtl/memory/sdram/sdram.sv, rtl/memory/sdram_arbiter5.sv) -- every
// Port 2 consumer narrower than that (sprite spritelut's 16-bit words,
// maincpu's 16-bit program fetch, audiocpu's 8-bit program fetch, per
// docs/phase1_sdram_map.md) needs the same "fetch the containing granule,
// then pick out the wanted slice" logic, so it's built once here rather
// than copy-pasted per consumer.
//
// Byte/word layout within a fetched granule, derived directly from
// sdram.sv's own read-capture logic and sdram_chip_model.sv's write-mask
// decode (not assumed) -- word i (0-3, ascending byte address) occupies
// g_data[16*i +: 16] (sdram.sv: STATE_READ0->dout[15:0] is the FIRST/lowest-
// address word, STATE_READ3->dout[63:48] the last), and within a 16-bit
// word, the EVEN byte address (addr[0]=0) is the LOW byte, ODD (addr[0]=1)
// is the HIGH byte (sdram_phy.sv: wrl <= we && !addr[0] selects the byte
// sdram_chip_model.sv writes to mem[][7:0], the low half) -- ordinary
// little-endian packing within each 16-bit lane. So for any byte address
// `addr`, word_index = addr[2:1] and (for WORD_BYTES=1) byte_in_word =
// addr[0] selecting low/high half of that word.
//
// req/valid contract matches every other consumer in this project: HOLD
// req until the matching valid pulse (client side); this bridge itself
// holds g_req the same way toward the arbiter, one request at a time (no
// pipelining -- matches sdram_arbiter5's own single-outstanding-transaction
// design).

module sdram_narrow_bridge #(
    parameter int WORD_BYTES = 2   // 1 = byte-wide client (e.g. Z80/audiocpu),
                                     // 2 = word-wide client (e.g. spritelut, maincpu)
) (
    input  logic clk,
    input  logic reset,

    // narrow client side
    input  logic                     req,
    input  logic [24:0]              addr,    // byte address of the desired unit
    output logic                     valid,
    output logic [8*WORD_BYTES-1:0] data,

    // wide granule side (one sdram_arbiter5 consumer port)
    output logic         g_req,
    output logic [24:0] g_addr,
    input  logic         g_valid,
    input  logic [63:0] g_data
);

    typedef enum logic {B_IDLE, B_WAIT} bstate_t;
    bstate_t bstate;

    logic [1:0] word_sel;
    logic         byte_sel;

    assign g_addr = {addr[24:3], 3'b000};   // 8-byte-align down to the granule base
    assign g_req  = (bstate == B_WAIT);

    logic [15:0] sel_word;
    assign sel_word = g_data[16*word_sel +: 16];

    generate
        if (WORD_BYTES == 1) begin : g_byte
            assign data = byte_sel ? sel_word[15:8] : sel_word[7:0];
        end else begin : g_word
            assign data = sel_word;
        end
    endgenerate

    assign valid = (bstate == B_WAIT) && g_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bstate <= B_IDLE;
        end else begin
            case (bstate)
                B_IDLE: begin
                    if (req) begin
                        word_sel <= addr[2:1];
                        byte_sel <= addr[0];
                        bstate   <= B_WAIT;
                    end
                end
                B_WAIT: begin
                    if (g_valid) bstate <= B_IDLE;
                end
            endcase
        end
    end

endmodule
