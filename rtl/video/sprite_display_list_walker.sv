// Walks the sprite display list (psikyo_v.cpp get_sprites(), re-verified
// against current MAME source, see docs/phase1_memory_map.md):
//
//   for (offs = 0; offs < (0x800-2)/2; offs++) {   // 1023 entries max
//       sprite = spritelist[offs];
//       if (sprite == 0xffff) break;
//       sprite %= 0x300;                            // fold to 0-767
//       ... draw sprite `sprite` ...
//   }
//
// Word offsets 0xC00-0xFFE within the 4096-word (8KB/2) spriteram region are
// the display list itself; the control word at 0xFFF (sprites-disable,
// transparent-pen select) is NOT this module's concern -- the caller (the
// not-yet-built frame-render top-level FSM) is expected to check that once
// per frame and simply not assert `start` at all when sprites are disabled,
// keeping this module focused purely on "walk the list, emit valid indices".
//
// sram_addr/sram_data is a 1-cycle synchronous read port (matches the BRAM
// convention already used for VRAM/row-scroll in tilemap_line_engine.sv):
// this module drives sram_addr combinationally from its own address
// register, and consumes sram_data exactly one cycle later.
//
// entry_valid/sprite_index/done are one-cycle pulses, registered together
// (not derived combinationally from state) to avoid the pixel_valid
// misalignment class of bug documented in tilemap_line_engine.sv's history.
//
// Flow-controlled via `advance`: found integrating this into the top-level
// sprite render engine, not present in the original standalone version --
// a free-running walker (2 cycles/entry) would blow past a consumer that
// needs many cycles per sprite (up to 64 sub-tiles, each a ROM round-trip)
// to actually process each entry, silently dropping entries. After emitting
// entry_valid the walker now HOLDS (address/count not yet advanced) until
// the consumer pulses `advance`, then fetches the next entry. No holding
// happens on `done` (sentinel or exhausted) since there's nothing left to
// advance to.

module sprite_display_list_walker (
    input  logic clk,
    input  logic reset,

    input  logic start,   // pulse: begin walking the display list from offset 0
    output logic busy,

    input  logic advance,  // pulse: consumer has finished with the held entry, fetch the next

    output logic [11:0] sram_addr,   // 0xC00-0xFFE
    input  logic [15:0] sram_data,   // 1-cycle sync read latency

    output logic         entry_valid,   // pulses once per non-terminator entry
    output logic [9:0]  sprite_index,  // 0-767, valid when entry_valid pulses AND while held
    output logic         done            // pulses once when the walk ends (sentinel or exhausted)
);

    localparam logic [11:0] DL_BASE       = 12'hC00;
    localparam int          DL_MAX_ENTRIES = 1023;

    typedef enum logic [1:0] {S_IDLE, S_FETCH, S_PROCESS, S_HOLD} state_t;
    state_t state;

    logic [11:0] addr_r;
    logic [9:0]  count_r;   // 0..1022 -- entries issued so far, zero-based

    assign sram_addr = addr_r;
    assign busy        = (state != S_IDLE);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= S_IDLE;
            addr_r        <= DL_BASE;
            count_r       <= 10'd0;
            entry_valid  <= 1'b0;
            sprite_index <= 10'd0;
            done          <= 1'b0;
        end else begin
            entry_valid <= 1'b0;
            done         <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        addr_r  <= DL_BASE;
                        count_r <= 10'd0;
                        state    <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    state <= S_PROCESS;
                end

                S_PROCESS: begin
                    if (sram_data == 16'hFFFF) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        entry_valid  <= 1'b1;
                        sprite_index <= sram_data % 16'd768;
                        state          <= S_HOLD;
                    end
                end

                S_HOLD: begin
                    if (advance) begin
                        if (count_r == DL_MAX_ENTRIES - 1) begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            addr_r  <= addr_r + 12'd1;
                            count_r <= count_r + 10'd1;
                            state    <= S_FETCH;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
