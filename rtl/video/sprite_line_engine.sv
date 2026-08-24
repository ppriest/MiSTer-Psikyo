// Per-scanline sprite renderer.
//
// Renders only the sprites intersecting one scanline, into a 320-pixel line
// buffer, instead of rendering every sprite's full height into a whole-frame
// buffer. This is the shape real arcade hardware used and the shape the rest
// of the MiSTer ecosystem uses (JTFRAME's JTFRAME_LF_BUFFER, including
// JTFRAME_LF_ZOOM for zoomed sprites); Arcade-Cave is the exception because
// CAVE's real hardware genuinely has a frame buffer.
//
// See docs/sprite_buffering.md for why the frame-buffer version was replaced:
// its defects (mid-scanout tearing, sprites retained between frames, dropped
// writes while the buffer cleared) all came from the buffer's size and the
// clear it needs, and are structurally impossible here.
//
// Every decode stage is the SAME already-verified module the frame engine
// uses -- sprite_record_decode, sprite_pos_transform, sprite_zoom_lut,
// sprite_subtile_step, sprite_zoom_src_index, tile_row_decode. The only new
// logic is the FSM: instead of looping every sub-tile row of every sprite,
// it finds the single sub-tile row that contains `render_line` and renders
// just that one pixel row.
//
// Per-sprite flow:
//   walk display list -> fetch 4-word record -> decode/zoom (registered once)
//   -> search iy = 0..ny-1 for the sub-tile row containing render_line
//   -> if none, skip the sprite immediately (this early-out is what makes
//      per-line rendering affordable)
//   -> else for ix = 0..nx-1: spritelut -> gfx row fetch -> emit dst_size_x
//      pixels
//
// Budget: 5472 clk cycles per scanline (htotal 456 at clk/12), less the line
// buffer's 320-cycle clear.

module sprite_line_engine (
    input  logic clk,
    input  logic reset,

    input  logic         line_start,    // pulse: render `render_line`
    input  logic [7:0]  render_line,   // 0-223
    output logic         busy,

    input  logic trans_pen0,
    input  logic trans_pen15,

    // display list BRAM port (word offsets 0xC00-0xFFE)
    output logic [11:0] dl_addr,
    input  logic [15:0] dl_data,

    // attribute table BRAM port (word offsets 0x000-0xBFF)
    output logic [11:0] at_addr,
    input  logic [15:0] at_data,

    // spritelut ROM
    output logic         lut_req,
    output logic [16:0] lut_addr,
    input  logic         lut_valid,
    input  logic [15:0] lut_data,

    // sprite gfx ROM
    output logic         gfxrom_req,
    output logic [22:0] gfxrom_addr,
    input  logic         gfxrom_valid,
    input  logic [63:0] gfxrom_data,

    // line buffer write port
    output logic         fb_we,
    output logic [8:0]  fb_x,
    output logic [3:0]  fb_pixel,
    output logic [4:0]  fb_color,
    output logic [1:0]  fb_priority
);

    // ---- display list walker ----
    logic        dl_start, dl_busy, dl_advance;
    logic        dl_entry_valid, dl_done;
    logic [9:0] dl_sprite_index;

    sprite_display_list_walker u_walker (
        .clk(clk), .reset(reset),
        .start(dl_start), .busy(dl_busy), .advance(dl_advance),
        .sram_addr(dl_addr), .sram_data(dl_data),
        .entry_valid(dl_entry_valid), .sprite_index(dl_sprite_index), .done(dl_done)
    );

    // ---- per-sprite attribute record ----
    logic        rf_start, rf_busy, rf_record_valid;
    logic [15:0] rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo;

    sprite_record_fetch u_record_fetch (
        .clk(clk), .reset(reset),
        .start(rf_start), .sprite_index(dl_sprite_index), .busy(rf_busy),
        .sram_addr(at_addr), .sram_data(at_data),
        .record_valid(rf_record_valid),
        .word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo)
    );

    // ---- combinational decode chain ----
    logic [3:0]        rd_zoom_y_raw, rd_zoom_x_raw, rd_ny, rd_nx;
    logic signed [9:0] rd_y_pos, rd_x_pos;
    logic               rd_flip_y, rd_flip_x;
    logic [4:0]        rd_color;
    logic [1:0]        rd_priority_field;
    logic [16:0]       rd_code;

    sprite_record_decode u_record_decode (
        .word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo),
        .zoom_y_raw(rd_zoom_y_raw), .zoom_x_raw(rd_zoom_x_raw), .ny(rd_ny), .nx(rd_nx),
        .y_pos(rd_y_pos), .x_pos(rd_x_pos), .flip_y(rd_flip_y), .flip_x(rd_flip_x),
        .color(rd_color), .priority_field(rd_priority_field), .code(rd_code)
    );

    logic signed [9:0] pt_x_adj, pt_y_adj;
    logic [5:0]        pt_zoom_x_t, pt_zoom_y_t;

    sprite_pos_transform u_pos_transform (
        .x_pos(rd_x_pos), .y_pos(rd_y_pos), .nx(rd_nx), .ny(rd_ny),
        .zoom_x_raw(rd_zoom_x_raw), .zoom_y_raw(rd_zoom_y_raw),
        .x_adj(pt_x_adj), .y_adj(pt_y_adj),
        .zoom_x_transformed(pt_zoom_x_t), .zoom_y_transformed(pt_zoom_y_t)
    );

    logic [4:0]  zl_dst_size_x, zl_dst_size_y;
    logic [16:0] zl_dx_x, zl_dx_y;

    sprite_zoom_lut u_zoom_lut_x (.raw_zoom(rd_zoom_x_raw), .dst_size(zl_dst_size_x), .dx(zl_dx_x));
    sprite_zoom_lut u_zoom_lut_y (.raw_zoom(rd_zoom_y_raw), .dst_size(zl_dst_size_y), .dx(zl_dx_y));

    // ---- per-sprite constants, registered once (same idea as the frame
    // engine's stage A: these are constant for the whole sprite, and leaving
    // them combinational put the whole decode chain in series with the inner
    // loop and blew the timing path) ----
    logic [3:0]        a_nx, a_ny;
    logic              a_flip_x, a_flip_y;
    logic [4:0]        a_color;
    logic [1:0]        a_priority;
    logic [16:0]       a_code;
    logic signed [9:0] a_x_adj, a_y_adj;
    logic [5:0]        a_zoom_x_t, a_zoom_y_t;
    logic [4:0]        a_dst_size_x, a_dst_size_y;
    logic [16:0]       a_dx_x, a_dx_y;

    // ---- sub-tile stepping ----
    logic [3:0] ix, iy;
    logic [5:0] subtile_ordinal;
    logic [3:0] dst_row, dst_col;

    logic signed [9:0] st_sub_x, st_sub_y;
    logic [16:0]       st_sub_code;

    // Visitation is row-major, so the ordinal for an arbitrary (ix,iy) is
    // iy*nx + ix. The frame engine could just increment a counter because it
    // visited every sub-tile; here we jump straight to the row we need.
    assign subtile_ordinal = 6'({iy * a_nx}) + 6'({2'd0, ix});

    sprite_subtile_step u_subtile_step (
        .ix(ix), .iy(iy), .nx(a_nx), .ny(a_ny), .flip_x(a_flip_x), .flip_y(a_flip_y),
        .x_adj(a_x_adj), .y_adj(a_y_adj),
        .zoom_x_transformed(a_zoom_x_t), .zoom_y_transformed(a_zoom_y_t),
        .subtile_ordinal(subtile_ordinal), .code_base(a_code),
        .sub_x(st_sub_x), .sub_y(st_sub_y), .sub_code(st_sub_code)
    );

    assign lut_addr = st_sub_code & 17'h1FFFF;

    // Does this sub-tile row cover the scanline being rendered?
    logic signed [10:0] row_off;
    assign row_off = $signed({render_line[7], 3'd0, render_line}) - $signed({st_sub_y[9], st_sub_y});
    wire row_hit = (row_off >= 0) && (row_off < $signed({6'd0, a_dst_size_y}));

    // ---- gfx row fetch / decode ----
    logic [15:0] tile_code_r;
    logic [3:0]  zsi_src_row, zsi_src_col;

    sprite_zoom_src_index u_zsi_y (
        .col(dst_row), .dst_size(a_dst_size_y[3:0]), .dx(a_dx_y), .flip(a_flip_y), .src_index(zsi_src_row)
    );
    sprite_zoom_src_index u_zsi_x (
        .col(dst_col), .dst_size(a_dst_size_x[3:0]), .dx(a_dx_x), .flip(a_flip_x), .src_index(zsi_src_col)
    );

    assign gfxrom_addr = {tile_code_r, zsi_src_row, 3'b000};

    logic [7:0] row_bytes_r [0:7];
    logic [3:0] row_pixel [0:15];

    tile_row_decode u_row_decode (
        .row_bytes(row_bytes_r), .flip_x(1'b0), .pixel(row_pixel)
    );

    logic [3:0] cur_pixel;
    assign cur_pixel = row_pixel[zsi_src_col];

    logic opaque;
    assign opaque = !((cur_pixel == 4'd0 && trans_pen0) || (cur_pixel == 4'd15 && trans_pen15));

    logic signed [10:0] screen_x_full;
    assign screen_x_full = $signed({st_sub_x[9], st_sub_x}) + $signed({7'd0, dst_col});
    wire onscreen = (screen_x_full >= 0) && (screen_x_full < 11'sd320);

    // ---- FSM ----
    typedef enum logic [2:0] {
        S_IDLE, S_WALK_WAIT, S_RECORD_WAIT, S_FIND_ROW, S_LUT_WAIT, S_ROW_WAIT, S_COL
    } state_t;
    state_t state;

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= S_IDLE;
            dl_start    <= 1'b0;
            dl_advance  <= 1'b0;
            rf_start    <= 1'b0;
            lut_req     <= 1'b0;
            gfxrom_req  <= 1'b0;
            fb_we       <= 1'b0;
            ix          <= 4'd0;
            iy          <= 4'd0;
            dst_row     <= 4'd0;
            dst_col     <= 4'd0;
            tile_code_r <= 16'd0;
            a_nx <= 4'd1; a_ny <= 4'd1; a_flip_x <= 1'b0; a_flip_y <= 1'b0;
            a_color <= 5'd0; a_priority <= 2'd0; a_code <= 17'd0;
            a_x_adj <= 10'sd0; a_y_adj <= 10'sd0;
            a_zoom_x_t <= 6'd32; a_zoom_y_t <= 6'd32;
            a_dst_size_x <= 5'd16; a_dst_size_y <= 5'd16;
            a_dx_x <= 17'd0; a_dx_y <= 17'd0;
            for (int i = 0; i < 8; i++) row_bytes_r[i] <= 8'd0;
        end else begin
            dl_start   <= 1'b0;
            dl_advance <= 1'b0;
            rf_start   <= 1'b0;
            fb_we      <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (line_start) begin
                        dl_start <= 1'b1;
                        state     <= S_WALK_WAIT;
                    end
                end

                S_WALK_WAIT: begin
                    if (dl_entry_valid) begin
                        rf_start <= 1'b1;
                        state     <= S_RECORD_WAIT;
                    end else if (dl_done) begin
                        state <= S_IDLE;
                    end
                end

                S_RECORD_WAIT: begin
                    if (rf_record_valid) begin
                        a_nx         <= rd_nx;
                        a_ny         <= rd_ny;
                        a_flip_x     <= rd_flip_x;
                        a_flip_y     <= rd_flip_y;
                        a_color      <= rd_color;
                        a_priority   <= rd_priority_field;
                        a_code       <= rd_code;
                        a_x_adj      <= pt_x_adj;
                        a_y_adj      <= pt_y_adj;
                        a_zoom_x_t   <= pt_zoom_x_t;
                        a_zoom_y_t   <= pt_zoom_y_t;
                        a_dst_size_x <= zl_dst_size_x;
                        a_dst_size_y <= zl_dst_size_y;
                        a_dx_x       <= zl_dx_x;
                        a_dx_y       <= zl_dx_y;
                        ix           <= 4'd0;
                        iy           <= 4'd0;
                        state        <= S_FIND_ROW;
                    end
                end

                // Search the sprite's sub-tile rows for the one covering this
                // scanline. Most sprites do not cover it at all, and this is
                // where they are dropped -- one cycle per sub-tile row.
                S_FIND_ROW: begin
                    if (row_hit) begin
                        dst_row <= row_off[3:0];
                        ix      <= 4'd0;
                        lut_req <= 1'b1;
                        state   <= S_LUT_WAIT;
                    end else if (iy == a_ny - 4'd1) begin
                        dl_advance <= 1'b1;      // sprite misses this line
                        state      <= S_WALK_WAIT;
                    end else begin
                        iy <= iy + 4'd1;
                    end
                end

                S_LUT_WAIT: begin
                    if (lut_valid) begin
                        tile_code_r <= lut_data;
                        lut_req     <= 1'b0;
                        gfxrom_req  <= 1'b1;
                        state       <= S_ROW_WAIT;
                    end
                end

                S_ROW_WAIT: begin
                    if (gfxrom_valid) begin
                        row_bytes_r[0] <= gfxrom_data[63:56];
                        row_bytes_r[1] <= gfxrom_data[55:48];
                        row_bytes_r[2] <= gfxrom_data[47:40];
                        row_bytes_r[3] <= gfxrom_data[39:32];
                        row_bytes_r[4] <= gfxrom_data[31:24];
                        row_bytes_r[5] <= gfxrom_data[23:16];
                        row_bytes_r[6] <= gfxrom_data[15:8];
                        row_bytes_r[7] <= gfxrom_data[7:0];
                        gfxrom_req     <= 1'b0;
                        dst_col        <= 4'd0;
                        state          <= S_COL;
                    end
                end

                S_COL: begin
                    if (onscreen && opaque) begin
                        fb_we       <= 1'b1;
                        fb_x        <= screen_x_full[8:0];
                        fb_pixel    <= cur_pixel;
                        fb_color    <= a_color;
                        fb_priority <= a_priority;
                    end

                    if ({1'b0, dst_col} != a_dst_size_x - 5'd1) begin
                        dst_col <= dst_col + 4'd1;
                    end else if (ix != a_nx - 4'd1) begin
                        ix      <= ix + 4'd1;   // next sub-tile column, same row
                        lut_req <= 1'b1;
                        state   <= S_LUT_WAIT;
                    end else begin
                        dl_advance <= 1'b1;      // sprite done for this line
                        state      <= S_WALK_WAIT;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
