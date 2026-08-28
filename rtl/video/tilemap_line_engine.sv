// Tilemap scanline sequencer -- one instance per layer. Drives the
// combinational address/decode chain (tilemap_coord -> tilemap_addrgen ->
// tile_cell_decode -> tile_row_decode) against real per-cycle timing and
// memory latency, prefetching up to PREFETCH_DEPTH tiles ahead of display
// through a ring buffer (was a fixed 2-entry ping-pong; widened after real
// SDRAM contention measurement, see the buf_pixels/buf_ready declaration
// below and docs/phase1_sdram_map.md).
//
// See docs/phase1_video_engine.md ("Tilemap scanline sequencer") for the
// full design rationale -- interface contract, the fetch-must-complete-
// within-16-cycles timing requirement, and why the row-scroll table fetch
// index is the raw scanline number, not the Y-scrolled one.

module tilemap_line_engine #(
    parameter int LAYER = 0,   // 0 or 1 -- passed through to tile_cell_decode
    // Prefetch ring buffer depth. 32 >= the 21 tiles fetched per line, so the
    // ring cannot wrap mid-line; at 8 it wrapped 2.6 times per line, and an
    // off-by-one at a wrap would shift every tile after it.
    // See the buf_pixels/buf_ready declaration
    // below for why this became a parameter instead of a fixed 2-entry
    // ping-pong (real SDRAM contention measurement, docs/phase1_sdram_map.md).
    parameter int PREFETCH_DEPTH = 32
) (
    input  logic        clk,
    input  logic         reset,

    // Timing (from a not-yet-built top-level generator; see doc for the
    // hcnt/vcnt convention this module assumes)
    input  logic [7:0]  vcnt,        // 0-223, current active scanline
    // One pixel is consumed per ce_pix, not per clk. clk is 85.909 MHz and the
    // pixel clock is 85.909/12 = 7.159 MHz; without this the display side
    // drains the line's 21 prefetched tiles (336 pixels, one per clk) in
    // 336/12 = 28 pixel clocks and reports fetch_overrun for the rest of the
    // line. That was the observed defect: correct content in columns 0..27 of
    // every scanline, backdrop across the remaining 292.
    input  logic         ce_pix,      // 1-in-12 pixel-clock enable
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
    //
    // gfxrom_req deasserts COMBINATIONALLY on gfxrom_valid (see the
    // assign below) -- the registered clear alone left req visibly high
    // for the one cycle after valid, and rtl/memory/sdram_phy.sv is back
    // in S_IDLE sampling req that exact cycle, so it launched a DUPLICATE
    // transaction for the address it had just served. From then on every
    // response the engine consumed belonged to the PREVIOUS request:
    // tile shape from cell N-1 rendered at position N with position N's
    // own (correctly latched) colour -- the single off-by-one behind both
    // the one-tile layer offset and the wrong-palette tiles
    // (docs/TILEMAP_BUG.md). Latency-dependent and invisible to every
    // short-latency behavioral testbench: the duplicate happened there
    // too, but its response landed while the FSM was between states and
    // was silently dropped; the real controller's longer latency landed
    // it squarely in the next S_GFXROM_WAIT. Root-caused via
    // sim/tilemap_addr_trace_tb/tb_tilemap_screen_sdram.sv, which
    // reproduced the real-hardware screen pixel-for-pixel and traced the
    // phy's transaction address diverging from the engine's request
    // address from the second fetch of every line onward.
    output logic         gfxrom_req,
    output logic [21:0] gfxrom_addr,   // tile_number*128 + fine_y*8
    input  logic         gfxrom_valid,
    input  logic [63:0] gfxrom_data,   // 8 bytes, MSB-first (matches tile_row_decode's row_bytes[0])

    output logic         pixel_valid,
    output logic [3:0]  pixel_index,
    output logic [6:0]  pixel_color,
    output logic         fetch_overrun  // sticky: fetch pipeline didn't keep up with display
`ifdef DEBUG_ISSP
    ,
    // Every stage of the fetch pipeline for the wrong-palette/one-tile-shift
    // investigation, latched by the caller (not here -- see psikyo_core.sv's
    // issp_probe instance) at the moment the bad tile is displayed. No cost
    // to the shipping build.
    output logic [11:0] dbg_fetch_vram_addr,
    output logic [15:0] dbg_vram_data,
    output logic [14:0] dbg_cell_tile_number,
    output logic [6:0]  dbg_cell_color,
    output logic [1:0]  dbg_mode_latched,
    output logic [1:0]  dbg_bank_latched,
    output logic [11:0] dbg_pixel_src_addr,
    output logic [15:0] dbg_pixel_src_word
`endif
);

    // Declared here (top of the body), not next to buf_pixels/buf_ready
    // below where it's conceptually explained -- PTR_W is used by
    // fetch_target's declaration, which comes first in file order, and this
    // toolchain (vlog -sv) does not resolve forward references to
    // body-local declarations across statements (same class of issue as
    // sdram.sv's mode/reset reordering, see rtl/memory/sdram/PROVENANCE.md).
    localparam int PTR_W = $clog2(PREFETCH_DEPTH);

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
    logic [PTR_W-1:0] fetch_target;   // which buffer index the fetch engine is filling

    // sampled at line_start, held stable through S_ROWSCROLL_WAIT
    logic [15:0] base_x_scroll_latched;
    logic        rowscroll_en_latched;

    logic [15:0] line_x_scroll;
    // One-PIXEL alignment bias, measured on real hardware against the MAME
    // reference (reported by the author of MAME's Psikyo renderer):
    // screen_x shows tilemap pixel (scroll + screen_x + 1), moving the
    // image one pixel LEFT of the unbiased sum. Applied to the shared
    // per-line sum so rowscroll lines get the same bias; both layers
    // inherit it (same module). The SIGN is hardware-verified -- do not
    // flip it from re-derivation alone (docs/LESSONS_LEARNED.md,
    // "Don't guess a sign twice").
    assign line_x_scroll = base_x_scroll_latched + (rowscroll_en_latched ? rowscroll_data : 16'd0) + 16'd1;

    logic [14:0] tile_number_reg;
    logic [6:0]  color_reg;
`ifdef DEBUG_ISSP
    // Frozen at the SAME cycle as color_reg (S_CELLDEC), not read live
    // later at S_GFXROM_WAIT -- vram_data can change between those two
    // points if the CPU writes this exact VRAM cell while its GFX-ROM
    // fetch is still in flight (a real, legitimate CPU write, not a bug),
    // which would otherwise make buf_src_word disagree with buf_color for
    // a reason that has nothing to do with the render pipeline -- a false
    // positive in the debug tag itself, not evidence of corruption.
    logic [15:0] vram_data_reg;
`endif

    // Prefetch ring buffer, PREFETCH_DEPTH tiles deep. Was a fixed 2-entry
    // ping-pong (fetch always exactly one tile ahead of display) until real
    // measurement against the SDRAM transport (sim/video_pipeline_tb/
    // tb_video_pipeline_sdram.sv, see docs/phase1_sdram_map.md's
    // "Verification results") showed that's not enough margin: rtl/memory/
    // sdram/sdram.sv's three ports share ONE internal transaction pipeline,
    // so when both tilemap layers request in the same window, one of them
    // occasionally waits out the other's full round trip (measured: nominal
    // 15 cycles, contention-stalled 22 or 35 cycles, against this module's
    // own 16-cycle-per-tile budget). With only one tile banked ahead, that
    // single stall was an immediate visible miss. Depth 4 gives up to 3
    // tile-periods (~48 cycles) of absorption instead of 1 (~16), enough to
    // ride out an isolated stall without needing a faster clock domain or a
    // redesigned (pipelined/overlapping) SDRAM controller -- see
    // PROVENANCE.md-style reasoning in docs/phase1_sdram_map.md for why a
    // faster fetch-domain clock remains the "correct" long-term fix but a
    // separate, larger task.
    logic [3:0] buf_pixels [0:PREFETCH_DEPTH-1][0:15];
    logic [6:0] buf_color  [0:PREFETCH_DEPTH-1];
`ifdef DEBUG_ISSP
    // Tags each buffer slot with the VRAM address it was fetched from, so
    // the DISPLAY side can report which address the pixel it is CURRENTLY
    // showing actually came from -- a genuine same-tile correlation.
    // Comparing the fetch side's cell_color (whatever tile is being
    // prefetched right now, dozens of tiles ahead) against the display
    // side's pixel_color (whatever tile is on screen right now) compares
    // two DIFFERENT tiles and proved nothing; this fixes that.
    logic [11:0] buf_src_addr [0:PREFETCH_DEPTH-1];
    // Raw VRAM word fetched into this slot. Combined with buf_color, this
    // lets the display side self-check: does buf_color[slot] genuinely
    // match what buf_src_word[slot]'s OWN color field predicts? If they
    // ever disagree for the same slot, that is proof of a buffer-level
    // corruption (a write-after-read race, wraparound bug, etc) -- not
    // inferred from an external reference or precise timing, just internal
    // consistency of our own storage.
    logic [15:0] buf_src_word [0:PREFETCH_DEPTH-1];
`endif
    logic [3:0] buf_start  [0:PREFETCH_DEPTH-1];
    logic [4:0] buf_count  [0:PREFETCH_DEPTH-1];

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
    logic fetch_tog [0:PREFETCH_DEPTH-1];
    logic disp_tog  [0:PREFETCH_DEPTH-1];
    logic buf_ready [0:PREFETCH_DEPTH-1];
    generate
        genvar gi;
        for (gi = 0; gi < PREFETCH_DEPTH; gi++) begin : g_buf_ready
            assign buf_ready[gi] = fetch_tog[gi] ^ disp_tog[gi];
        end
    endgenerate

    // Registered request flag, gated combinationally so the EXTERNAL req
    // line drops the same cycle gfxrom_valid pulses -- the registered
    // clear in S_GFXROM_WAIT is one cycle too late for sdram_phy.sv, which
    // is back in S_IDLE sampling req that very cycle and would start a
    // duplicate transaction (see the gfxrom_req port comment above and
    // docs/TILEMAP_BUG.md for the full root-cause trail).
    logic gfxrom_req_r;
    assign gfxrom_req = gfxrom_req_r & ~gfxrom_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_IDLE;
            for (int i = 0; i < PREFETCH_DEPTH; i++) fetch_tog[i] <= 1'b0;
            gfxrom_req_r   <= 1'b0;
        end else if (line_start) begin
            // A new line always takes priority over whatever the fetch FSM
            // was still doing for the previous one -- checked here BEFORE
            // the state case, NOT as a branch inside S_IDLE only: with a
            // fixed 21-tile-per-line fetch budget throttled by the
            // display's own consumption rate (S_WAIT_FREE), the fetch
            // FSM's last tile for a line routinely finishes at or after
            // h_active ends -- i.e. it is NOT reliably back in S_IDLE by
            // the time the next line_start pulse arrives. Since that pulse
            // was only ever checked from S_IDLE, it was silently dropped
            // whenever the FSM was still mid-fetch, permanently desyncing
            // the fetch pipeline from the display for the rest of the
            // frame (found via sim/video_pipeline_tb/, a sustained
            // multi-line integration test -- tilemap_line_engine's own
            // prior single-line testbench never exercised a second
            // line_start arriving while busy, so never caught this).
            // Restarting unconditionally here means any in-flight
            // S_GFXROM_WAIT request gets abandoned (gfxrom_req cleared);
            // a late gfxrom_valid for it is harmless since no state
            // reacts to it before the next real request. The display
            // side already discards whatever wasn't shown on its own
            // line_start handling below, so there is no stale data to
            // preserve here either.
            mode_latched          <= mode;
            bank_latched          <= bank;
            base_x_scroll_latched <= base_x_scroll;
            rowscroll_en_latched  <= rowscroll_enable;
            rowscroll_addr        <= rowscroll_pertile ? {4'd0, vcnt[7:4]} : vcnt;
            for (int i = 0; i < PREFETCH_DEPTH; i++) fetch_tog[i] <= 1'b0;
            fetch_target          <= '0;
            first_tile            <= 1'b1;
            tiles_to_fetch        <= 5'd21;  // fixed worst-case count, see doc
            gfxrom_req_r          <= 1'b0;   // abort any in-flight request cleanly
            // stash what S_ROWSCROLL_WAIT needs that isn't re-derivable there
            eff_y_latched         <= base_y_scroll + {8'd0, vcnt};
            state                 <= S_ROWSCROLL_WAIT;
        end else begin
            unique case (state)

                S_IDLE: begin
                    // line_start is handled above (any state, not just
                    // here) -- nothing to do while idle and no new line
                    // has started yet.
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
                // Without it the FSM races through all 21 tiles
                // back-to-back during blanking, repeatedly overwriting
                // both buffers with tiles far past the correct starting
                // one before display ever begins.
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
`ifdef DEBUG_ISSP
                    vram_data_reg    <= vram_data;
`endif
                    gfxrom_addr     <= {cell_tile_number, fine_y, 3'b000};
                    gfxrom_req_r    <= 1'b1;
                    state           <= S_GFXROM_WAIT;
                end

                S_GFXROM_WAIT: begin
                    if (gfxrom_valid) begin
                        gfxrom_req_r <= 1'b0;
                        for (int i = 0; i < 16; i++)
                            buf_pixels[fetch_target][i] <= decoded_pixel[i];
                        buf_color[fetch_target] <= color_reg;
`ifdef DEBUG_ISSP
                        buf_src_addr[fetch_target] <= fetch_vram_addr;
                        buf_src_word[fetch_target] <= vram_data_reg;
`endif
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
                    fetch_target            <= (fetch_target == PREFETCH_DEPTH-1) ? '0 : fetch_target + 1'b1;
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

    logic [PTR_W-1:0] display_sel;
    logic [3:0]        consumed;

    always_ff @(posedge clk) begin
        if (reset) begin
            display_sel   <= '0;
            consumed      <= 4'd0;
            pixel_valid   <= 1'b0;
            pixel_index   <= 4'd0;
            pixel_color   <= 7'd0;
`ifdef DEBUG_ISSP
            dbg_pixel_src_addr <= 12'd0;
            dbg_pixel_src_word <= 16'd0;
`endif
            fetch_overrun <= 1'b0;
            for (int i = 0; i < PREFETCH_DEPTH; i++) disp_tog[i] <= 1'b0;
        end else if (line_start) begin
            display_sel <= '0;
            consumed    <= 4'd0;
            pixel_valid <= 1'b0;
            for (int i = 0; i < PREFETCH_DEPTH; i++) disp_tog[i] <= 1'b0;
        end else if (h_active) begin
            // Advance only on a pixel-clock tick; between ticks hold the
            // current pixel so the compositor sees a stable value for the
            // whole pixel period.
            if (ce_pix) begin
                if (buf_ready[display_sel]) begin
                    pixel_valid <= 1'b1;
                    pixel_index <= buf_pixels[display_sel][buf_start[display_sel] + consumed];
                    pixel_color <= buf_color[display_sel];
`ifdef DEBUG_ISSP
                    dbg_pixel_src_addr <= buf_src_addr[display_sel];
                    dbg_pixel_src_word <= buf_src_word[display_sel];
`endif

                    if ({1'b0, consumed} + 5'd1 >= buf_count[display_sel]) begin
                        disp_tog[display_sel] <= ~disp_tog[display_sel];  // free this buffer
                        display_sel            <= (display_sel == PREFETCH_DEPTH-1) ? '0 : display_sel + 1'b1;
                        consumed                <= 4'd0;
                    end else begin
                        consumed <= consumed + 4'd1;
                    end
                end else begin
                    pixel_valid   <= 1'b0;
                    fetch_overrun <= 1'b1;   // wanted to display but buffer wasn't ready
                end
            end
        end else begin
            pixel_valid <= 1'b0;
        end
    end

`ifdef DEBUG_ISSP
    // Direct pass-through of the internal fetch-pipeline signals, for the
    // wrong-palette/one-tile-shift investigation (see the port declarations
    // above). Deliberately not latched here -- the caller (psikyo_core.sv's
    // issp_probe instance) captures a snapshot at a chosen moment; keeping
    // these combinational avoids adding any register this module doesn't
    // already have.
    assign dbg_fetch_vram_addr  = fetch_vram_addr;
    assign dbg_vram_data         = vram_data;
    assign dbg_cell_tile_number = cell_tile_number;
    assign dbg_cell_color        = cell_color;
    assign dbg_mode_latched      = mode_latched;
    assign dbg_bank_latched      = bank_latched;
`endif

endmodule
