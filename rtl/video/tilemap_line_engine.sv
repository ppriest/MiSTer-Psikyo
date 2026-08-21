// Tilemap scanline sequencer -- one instance per layer. Drives the
// combinational address/decode chain (tilemap_coord -> tilemap_addrgen ->
// tile_cell_decode -> tile_row_decode) against real per-cycle timing and
// memory latency, double-buffering one tile ahead of display.
//
// See docs/phase1_video_engine.md ("Tilemap scanline sequencer") for the
// full design rationale -- interface contract, the fetch-must-complete-
// within-16-cycles timing requirement, and why the row-scroll table fetch
// index is the raw scanline number, not the Y-scrolled one.

module tilemap_line_engine #(
    parameter int LAYER = 0   // 0 or 1 -- passed through to tile_cell_decode
) (
    input  logic        clk,
    input  logic         reset,

    // Timing (from a not-yet-built top-level generator; see doc for the
    // hcnt/vcnt convention this module assumes)
    input  logic [7:0]  vcnt,        // 0-223, current active scanline
    input  logic         h_active,    // 1 while the active 320-pixel window is being displayed
    input  logic         line_start,  // 1-cycle pulse during blanking, well before h_active next asserts

    // Per-layer control/scroll registers (sampled once per line at line_start)
    input  logic [1:0]  mode,
    input  logic [15:0] base_x_scroll,
    input  logic [15:0] base_y_scroll,
    input  logic [1:0]  bank,
    input  logic         rowscroll_enable,
    input  logic         rowscroll_pertile,

    // Row-scroll table read port (module-local index 0-255 within this
    // layer's table; caller adds the layer's base offset when addressing
    // the shared vregs BRAM). 1-cycle synchronous read latency.
    output logic [7:0]  rowscroll_addr,
    input  logic [15:0] rowscroll_data,

    // VRAM read port. 1-cycle synchronous read latency.
    output logic [11:0] vram_addr,
    input  logic [15:0] vram_data,

    // gfx ROM read port: request/valid handshake, latency not assumed.
    output logic         gfxrom_req,
    output logic [21:0] gfxrom_addr,   // tile_number*128 + fine_y*8
    input  logic         gfxrom_valid,
    input  logic [63:0] gfxrom_data,   // 8 bytes, MSB-first (matches tile_row_decode's row_bytes[0])

    output logic         pixel_valid,
    output logic [3:0]  pixel_index,
    output logic [6:0]  pixel_color,
    output logic         fetch_overrun  // sticky: fetch pipeline didn't keep up with display
);

    // ---- combinational address/decode chain, fed by registered fetch state ----

    logic [15:0] fetch_eff_x, eff_y_latched;
    logic [1:0]  mode_latched, bank_latched;

    logic [7:0] tile_col;
    logic [6:0] tile_row;
    logic [3:0] fine_x_unused, fine_y;

    tilemap_coord u_coord (
        .mode(mode_latched),
        .eff_x(fetch_eff_x),
        .eff_y(eff_y_latched),
        .tile_col(tile_col),
        .tile_row(tile_row),
        .fine_x(fine_x_unused),
        .fine_y(fine_y)
    );

    logic [11:0] fetch_vram_addr;
    tilemap_addrgen u_addrgen (
        .mode(mode_latched),
        .col(tile_col),
        .row(tile_row),
        .vram_index(fetch_vram_addr)
    );

    assign vram_addr = fetch_vram_addr;

    logic [14:0] cell_tile_number;
    logic [6:0]  cell_color;
    tile_cell_decode #(.LAYER(LAYER)) u_celldec (
        .vram_cell(vram_data),
        .bank(bank_latched),
        .tile_number(cell_tile_number),
        .color(cell_color)
    );

    logic [7:0] row_bytes [0:7];
    always_comb begin
        row_bytes[0] = gfxrom_data[63:56];
        row_bytes[1] = gfxrom_data[55:48];
        row_bytes[2] = gfxrom_data[47:40];
        row_bytes[3] = gfxrom_data[39:32];
        row_bytes[4] = gfxrom_data[31:24];
        row_bytes[5] = gfxrom_data[23:16];
        row_bytes[6] = gfxrom_data[15:8];
        row_bytes[7] = gfxrom_data[7:0];
    end

    logic [3:0] decoded_pixel [0:15];
    tile_row_decode u_rowdec (
        .row_bytes(row_bytes),
        .flip_x(1'b0),   // tilemap cells carry no flip bit (sprites do; tiles don't)
        .pixel(decoded_pixel)
    );

    // ---- fetch FSM ----

    typedef enum logic [2:0] {
        S_IDLE, S_ROWSCROLL_WAIT, S_WAIT_FREE, S_COORD, S_CELLDEC, S_GFXROM_WAIT, S_STORE_DONE
    } state_t;
    state_t state;

    logic [3:0]  fine_x_initial;
    logic        first_tile;
    logic [4:0]  tiles_to_fetch;
    logic        fetch_target;   // which buffer index the fetch engine is filling

    // sampled at line_start, held stable through S_ROWSCROLL_WAIT
    logic [15:0] base_x_scroll_latched;
    logic        rowscroll_en_latched;

    logic [15:0] line_x_scroll;
    assign line_x_scroll = base_x_scroll_latched + (rowscroll_en_latched ? rowscroll_data : 16'd0);

    logic [14:0] tile_number_reg;
    logic [6:0]  color_reg;

    // double-buffered decoded tile storage
    logic [3:0] buf_pixels [0:1][0:15];
    logic [6:0] buf_color  [0:1];
    logic [3:0] buf_start  [0:1];
    logic [4:0] buf_count  [0:1];

    // Buffer-ready handshake, race-free by construction: each toggle bit
    // has exactly one writer (fetch_tog here, disp_tog in the display
    // block below), and "ready to display" / "free for fetch" are derived
    // combinationally by comparing them -- never written directly by
    // either side. A first draft used a single buf_valid[] array written
    // from BOTH the fetch and display always_ff blocks (set on fill,
    // meant to be cleared on consume) -- that's a real multi-driver
    // conflict (same class of bug as the VHDL testbench issue from the
    // Phase 0 CPU spike), and it was ALSO simply never cleared on the
    // display side at all, which alone would have permanently stalled
    // the fetch engine after the first two tiles.
    logic fetch_tog [0:1];
    logic disp_tog  [0:1];
    logic buf_ready [0:1];
    assign buf_ready[0] = fetch_tog[0] ^ disp_tog[0];
    assign buf_ready[1] = fetch_tog[1] ^ disp_tog[1];

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_IDLE;
            fetch_tog[0]   <= 1'b0;
            fetch_tog[1]   <= 1'b0;
            gfxrom_req     <= 1'b0;
        end else begin
            unique case (state)

                S_IDLE: begin
                    if (line_start) begin
                        mode_latched          <= mode;
                        bank_latched          <= bank;
                        base_x_scroll_latched <= base_x_scroll;
                        rowscroll_en_latched  <= rowscroll_enable;
                        rowscroll_addr        <= rowscroll_pertile ? {4'd0, vcnt[7:4]} : vcnt;
                        fetch_tog[0]          <= 1'b0;
                        fetch_tog[1]          <= 1'b0;
                        fetch_target          <= 1'b0;
                        first_tile            <= 1'b1;
                        tiles_to_fetch        <= 5'd21;  // fixed worst-case count, see doc
                        // stash what S_ROWSCROLL_WAIT needs that isn't re-derivable there
                        eff_y_latched         <= base_y_scroll + {8'd0, vcnt};
                        state                 <= S_ROWSCROLL_WAIT;
                    end
                end

                S_ROWSCROLL_WAIT: begin
                    // line_x_scroll is a comb wire (below) so no procedural
                    // temp is needed here.
                    fine_x_initial <= line_x_scroll[3:0];
                    fetch_eff_x    <= {line_x_scroll[15:4], 4'd0};   // tile-align
                    state          <= S_WAIT_FREE;
                end

                // Throttle: only start the next fetch once the target
                // buffer has actually been consumed by the display side.
                // An earlier version skipped this and looped straight back
                // to S_COORD from S_STORE_DONE -- it raced through all 21
                // tiles back-to-back during blanking, repeatedly
                // overwriting both buffers with tiles far past the correct
                // starting one before display ever began. Caught via
                // waveform tracing (dut.buf_start/buf_color kept changing
                // long after the correct first fetch), not by inspection.
                S_WAIT_FREE: begin
                    if (!buf_ready[fetch_target])
                        state <= S_COORD;
                end

                S_COORD: begin
                    // vram_addr is combinational (tilemap_coord+addrgen fed by
                    // fetch_eff_x/eff_y_latched/mode_latched, all stable
                    // registers at this point) -- nothing to do here but wait
                    // one cycle for the synchronous VRAM read.
                    state <= S_CELLDEC;
                end

                S_CELLDEC: begin
                    // vram_data now reflects fetch_vram_addr; tile_cell_decode
                    // output is valid combinationally this cycle.
                    tile_number_reg <= cell_tile_number;
                    color_reg       <= cell_color;
                    gfxrom_addr     <= {cell_tile_number, fine_y, 3'b000};
                    gfxrom_req      <= 1'b1;
                    state           <= S_GFXROM_WAIT;
                end

                S_GFXROM_WAIT: begin
                    if (gfxrom_valid) begin
                        gfxrom_req <= 1'b0;
                        for (int i = 0; i < 16; i++)
                            buf_pixels[fetch_target][i] <= decoded_pixel[i];
                        buf_color[fetch_target] <= color_reg;
                        if (first_tile) begin
                            buf_start[fetch_target] <= fine_x_initial;
                            buf_count[fetch_target] <= 5'd16 - {1'b0, fine_x_initial};
                        end else begin
                            buf_start[fetch_target] <= 4'd0;
                            buf_count[fetch_target] <= 5'd16;
                        end
                        state <= S_STORE_DONE;
                    end
                end

                S_STORE_DONE: begin
                    fetch_tog[fetch_target] <= ~fetch_tog[fetch_target];
                    first_tile              <= 1'b0;
                    fetch_eff_x             <= fetch_eff_x + 16'd16;
                    tiles_to_fetch          <= tiles_to_fetch - 5'd1;
                    fetch_target            <= ~fetch_target;
                    if (tiles_to_fetch > 5'd1)
                        state <= S_WAIT_FREE;
                    else
                        state <= S_IDLE;
                end

            endcase
        end
    end

    // ---- display side: independent of the fetch FSM's state, synchronized
    // only via buf_valid/display_sel/consumed.
    //
    // pixel_valid/pixel_index/pixel_color are all registered together here,
    // from the *current* (pre-update) display_sel/consumed/buf_valid, so
    // they carry the same one-cycle latency from h_active and stay mutually
    // consistent -- an earlier draft computed pixel_valid in this always_ff
    // block but pixel_index/pixel_color combinationally from the
    // *already-updated* display_sel/consumed in a separate always_comb,
    // which is a real one-cycle misalignment bug, caught on review before
    // ever compiling it.
    //
    // fetch_overrun is also driven only from here (not from the fetch FSM's
    // reset branch as an earlier draft had it) -- a signal must have exactly
    // one procedural driver; this is the same class of bug as the VHDL
    // testbench multi-driver issue from the Phase 0 CPU spike.

    logic       display_sel;
    logic [3:0] consumed;

    always_ff @(posedge clk) begin
        if (reset) begin
            display_sel   <= 1'b0;
            consumed      <= 4'd0;
            pixel_valid   <= 1'b0;
            pixel_index   <= 4'd0;
            pixel_color   <= 7'd0;
            fetch_overrun <= 1'b0;
            disp_tog[0]   <= 1'b0;
            disp_tog[1]   <= 1'b0;
        end else if (line_start) begin
            display_sel <= 1'b0;
            consumed    <= 4'd0;
            pixel_valid <= 1'b0;
            disp_tog[0] <= 1'b0;
            disp_tog[1] <= 1'b0;
        end else if (h_active) begin
            if (buf_ready[display_sel]) begin
                pixel_valid <= 1'b1;
                pixel_index <= buf_pixels[display_sel][buf_start[display_sel] + consumed];
                pixel_color <= buf_color[display_sel];

                if ({1'b0, consumed} + 5'd1 >= buf_count[display_sel]) begin
                    disp_tog[display_sel] <= ~disp_tog[display_sel];  // free this buffer
                    display_sel            <= ~display_sel;
                    consumed                <= 4'd0;
                end else begin
                    consumed <= consumed + 4'd1;
                end
            end else begin
                pixel_valid   <= 1'b0;
                fetch_overrun <= 1'b1;   // wanted to display but buffer wasn't ready
            end
        end else begin
            pixel_valid <= 1'b0;
        end
    end

endmodule
