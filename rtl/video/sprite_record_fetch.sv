// Fetches one sprite's 4-word (8-byte) attribute record from spriteram,
// given the sprite_index sprite_display_list_walker produces (0-767).
// Record layout (docs/phase1_memory_map.md, psikyo_v.cpp:145-183): 4
// consecutive 16-bit words per sprite, base word address = sprite_index*4,
// laid out Y/X/attr/code_lo -- matching sprite_record_decode's port names
// exactly so the two wire together directly with no reshuffling.
//
// Uses its own synchronous read port into spriteram (word offsets
// 0x000-0xBFF, the attribute-table region), independent of
// sprite_display_list_walker's port into the 0xC00-0xFFE display-list
// region -- the two regions never overlap, and Cyclone V M10K blocks are
// true dual-port, so this is one physical BRAM with two simultaneous read
// ports rather than a shared/arbitrated single port. Same 1-cycle sync
// read convention as every other BRAM interface in this project.

module sprite_record_fetch (
    input  logic clk,
    input  logic reset,

    input  logic         start,         // pulse: begin fetching sprite_index's record
    input  logic [9:0]  sprite_index,  // 0-767, sampled when start pulses
    output logic         busy,

    output logic [11:0] sram_addr,   // 0x000-0xBFF (sprite_index*4 + 0..3)
    input  logic [15:0] sram_data,   // 1-cycle sync read latency

    output logic         record_valid,  // pulses once, all 4 words latched
    output logic [15:0] word_y,
    output logic [15:0] word_x,
    output logic [15:0] word_attr,
    output logic [15:0] word_code_lo
);

    typedef enum logic [1:0] {S_IDLE, S_FETCH, S_LATCH} state_t;
    state_t state;

    logic [11:0] base_addr;
    logic [1:0]  word_sel;   // 0=Y, 1=X, 2=attr, 3=code_lo

    assign sram_addr = base_addr + {10'd0, word_sel};
    assign busy        = (state != S_IDLE);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= S_IDLE;
            base_addr     <= 12'd0;
            word_sel      <= 2'd0;
            record_valid <= 1'b0;
            word_y         <= 16'd0;
            word_x         <= 16'd0;
            word_attr     <= 16'd0;
            word_code_lo <= 16'd0;
        end else begin
            record_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        base_addr <= {sprite_index, 2'd0};  // sprite_index * 4
                        word_sel  <= 2'd0;
                        state      <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    state <= S_LATCH;
                end

                S_LATCH: begin
                    case (word_sel)
                        2'd0: word_y         <= sram_data;
                        2'd1: word_x         <= sram_data;
                        2'd2: word_attr     <= sram_data;
                        2'd3: word_code_lo <= sram_data;
                    endcase

                    if (word_sel == 2'd3) begin
                        record_valid <= 1'b1;
                        state         <= S_IDLE;
                    end else begin
                        word_sel <= word_sel + 2'd1;
                        state     <= S_FETCH;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
