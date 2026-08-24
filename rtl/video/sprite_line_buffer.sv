// Double-buffered 320-pixel sprite line buffer.
//
// Replaces sprite_frame_buffer's whole-frame double buffer. That held
// 2 x 71680 x 12 bits (about 1.7 Mbit) and needed a 71680-cycle clear per
// frame, which is where the sprite defects came from: the display bank
// toggled mid-scanout (tearing), and the clear overlapped the next render
// pass while the buffer ignored writes (dropped sprites and stale pixels).
//
// Two 320-entry banks are 7.7 kbit, about 220x smaller, and both of those
// failure modes stop being possible: the swap happens at hblank so it can
// never tear a visible line, and a bank is cleared while it is neither being
// displayed nor rendered into.
//
// Per-line cycle budget, from video_timing: htotal 456 pixel clocks at
// clk/12, so 5472 clk cycles per line. The clear is 320 of those (6%),
// leaving the rest for rendering the next line's sprites.
//
// Sequencing, driven by line_start:
//   1. swap banks -- the bank just displayed becomes the render bank
//   2. clear it (320 cycles), holding `ready` low
//   3. raise `ready`; the sprite engine renders the NEXT line into it while
//      the other bank is displayed
//
// The clear is a separate pass rather than clear-on-read because read and
// clear would hit the same address in the same cycle, and inferred RAM's
// read-during-write behaviour is not something to depend on.

module sprite_line_buffer (
    input  logic clk,
    input  logic reset,

    // one pulse per scanline, during hblank
    input  logic line_start,
    output logic ready,          // render bank cleared, safe to write

    // write port -- sprite engine, rendering the NEXT line
    input  logic        we,
    input  logic [8:0]  wx,       // 0..319
    input  logic [3:0]  wpixel,
    input  logic [4:0]  wcolor,
    input  logic [1:0]  wpriority,

    // read port -- compositor, displaying the CURRENT line
    input  logic [8:0]  rx,
    output logic        rd_present,
    output logic [3:0]  rd_pixel,
    output logic [4:0]  rd_color,
    output logic [1:0]  rd_priority
);

    localparam int W = 320;

    // packed entry: {present(1), pixel(4), color(5), priority(2)} = 12 bits,
    // same layout sprite_frame_buffer used.
    logic [11:0] mem_a [0:W-1];
    logic [11:0] mem_b [0:W-1];

    logic bank;            // 0: A renders, B displays. 1: reversed.
    logic [8:0] clr_addr;
    logic        clearing;

    assign ready = ~clearing;

    // ---- write/clear mux, per bank ----
    // The render bank takes engine writes; the bank being cleared takes the
    // clear counter. They are the same bank -- clearing happens first, then
    // rendering -- so one write port each is enough.
    logic        wr_en;
    logic [8:0]  wr_addr;
    logic [11:0] wr_data;

    assign wr_en   = clearing ? 1'b1        : we;
    assign wr_addr = clearing ? clr_addr    : wx;
    assign wr_data = clearing ? 12'd0       : {1'b1, wpixel, wcolor, wpriority};

    wire a_is_render = (bank == 1'b0);

    logic [11:0] a_rd, b_rd;
    always_ff @(posedge clk) begin
        if (wr_en &&  a_is_render) mem_a[wr_addr] <= wr_data;
        a_rd <= mem_a[rx];
    end
    always_ff @(posedge clk) begin
        if (wr_en && !a_is_render) mem_b[wr_addr] <= wr_data;
        b_rd <= mem_b[rx];
    end

    // Display reads the bank that is NOT being rendered. bank_d matches the
    // one-cycle latency of the registered reads above.
    logic bank_d;
    logic [11:0] rd_word;
    assign rd_word = (bank_d == 1'b0) ? b_rd : a_rd;

    assign rd_present  = rd_word[11];
    assign rd_pixel     = rd_word[10:7];
    assign rd_color     = rd_word[6:2];
    assign rd_priority = rd_word[1:0];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bank      <= 1'b0;
            bank_d    <= 1'b0;
            clr_addr  <= 9'd0;
            clearing  <= 1'b1;      // clear once out of reset
        end else begin
            bank_d <= bank;

            if (line_start) begin
                bank     <= ~bank;
                clr_addr <= 9'd0;
                clearing <= 1'b1;
            end else if (clearing) begin
                if (clr_addr == W - 1) clearing <= 1'b0;
                else                     clr_addr <= clr_addr + 9'd1;
            end
        end
    end

endmodule
