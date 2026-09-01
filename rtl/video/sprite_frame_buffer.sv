// RETIRED FROM SYNTHESIS (2026-08-30): replaced by the per-scanline path
// (sprite_line_list + sprite_line_engine + sprite_line_buffer) and removed
// from both .qsf file lists. Kept in the tree as the verified GOLDEN
// REFERENCE for the line path's differential testbench -- it renders the
// same records through the same decode modules, whole-frame.
// Double-buffered 320x224 sprite frame buffer: the memory behind
// sprite_render_engine's write port, plus the ping-pong bank swap and the
// per-frame clear that makes the swap safe (see docs/phase1_video_engine.md,
// "Sprite frame renderer: architecture" for why sprites render a full frame
// ahead rather than just-in-time per scanline).
//
// Why a clear is needed at all: without one, a pixel a sprite drew two
// frames ago but NOT this frame would still show stale "present" data when
// the compositor reads it during this frame's scanout -- pixel value alone
// can't distinguish "opaque pixel 0" from "nothing drawn here" (all 16
// pixel values are legitimately opaque), so a `present` bit is stored per
// pixel, and the bank about to be rendered into must have that bit cleared
// everywhere before rendering starts.
//
// `frame_swap` intentionally combines the bank toggle and the clear into
// one action (rather than exposing them as two things a caller could
// forget to sequence correctly): pulse `frame_swap` once per frame (e.g.
// at vblank), wait for `swap_done`, THEN start sprite_render_engine's
// frame_start into the now-clean render bank. Only one bank is ever being
// cleared/rendered at a time -- the other is simultaneously readable by
// the compositor's read port for the frame currently being scanned out.
//
// Both physical banks always drive both a write path (active only when
// bank_sel selects them as the current render bank) and a read path
// (always live, at rd_x/rd_y) -- standard true-dual-port BRAM inference,
// one read and one write port per array, never used for both roles by the
// same array in the same frame.

module sprite_frame_buffer (
	input logic clk,
	input logic reset,

	input  logic frame_swap,   // pulse: toggle banks, begin clearing the new render bank
	output logic swap_busy,
	output logic swap_done,     // pulse: new render bank is clear, safe to start rendering into it

	// write port, from sprite_render_engine -- ignored while swap_busy
	input logic         fb_we,
	input logic [8:0]  fb_x,
	input logic [7:0]  fb_y,
	input logic [3:0]  fb_pixel,
	input logic [4:0]  fb_color,
	input logic [1:0]  fb_priority,

	// read port, for the (not yet built) compositor -- 1-cycle sync,
	// always reads the current DISPLAY bank (opposite of the render bank)
	input  logic [8:0] rd_x,
	input  logic [7:0] rd_y,
	output logic         rd_present,
	output logic [3:0]  rd_pixel,
	output logic [4:0]  rd_color,
	output logic [1:0]  rd_priority
);

	localparam int PIXELS = 320 * 224;   // 71680

	// packed word: {present(1), pixel(4), color(5), priority(2)} = 12 bits
	logic [11:0] mem_a [0:PIXELS-1];
	logic [11:0] mem_b [0:PIXELS-1];

	logic bank_sel;   // 0: mem_a is render, mem_b is display. 1: reversed.

	// ---- clear FSM ----
	typedef enum logic [1:0] {S_IDLE, S_CLEARING} state_t;
	state_t state;
	logic [16:0] clear_addr;   // 0..71679

	assign swap_busy = (state == S_CLEARING);

	// ---- write path mux: clear counter takes priority over external writes ----
	logic         write_en;
	logic [16:0] write_addr;
	logic [11:0] write_data;

	assign write_en    = (state == S_CLEARING) ? 1'b1 : fb_we;
	assign write_addr = (state == S_CLEARING) ? clear_addr : ({8'd0, fb_y} * 17'd320 + {8'd0, fb_x});
	assign write_data = (state == S_CLEARING) ? 12'd0 : {1'b1, fb_pixel, fb_color, fb_priority};

	logic we_a, we_b;
	assign we_a = write_en && (bank_sel == 1'b0);
	assign we_b = write_en && (bank_sel == 1'b1);

	// ---- read path: always live on both arrays at rd_x/rd_y ----
	logic [16:0] rd_addr;
	assign rd_addr = {8'd0, rd_y} * 17'd320 + {8'd0, rd_x};

	logic [11:0] mem_a_rd_data, mem_b_rd_data;
	logic         bank_sel_d;

	always_ff @(posedge clk) begin
		if (we_a) mem_a[write_addr] <= write_data;
		mem_a_rd_data <= mem_a[rd_addr];
	end

	always_ff @(posedge clk) begin
		if (we_b) mem_b[write_addr] <= write_data;
		mem_b_rd_data <= mem_b[rd_addr];
	end

	logic [11:0] rd_word;
	assign rd_word = (bank_sel_d == 1'b0) ? mem_b_rd_data : mem_a_rd_data;   // display = NOT render

	assign rd_present  = rd_word[11];
	assign rd_pixel     = rd_word[10:7];
	assign rd_color     = rd_word[6:2];
	assign rd_priority = rd_word[1:0];

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state       <= S_IDLE;
			bank_sel    <= 1'b0;
			bank_sel_d <= 1'b0;
			clear_addr <= 17'd0;
			swap_done   <= 1'b0;
		end else begin
			swap_done   <= 1'b0;
			bank_sel_d <= bank_sel;

			case (state)
				S_IDLE: begin
					if (frame_swap) begin
						bank_sel    <= ~bank_sel;
						clear_addr <= 17'd0;
						state         <= S_CLEARING;
					end
				end

				S_CLEARING: begin
					if (clear_addr == PIXELS - 1) begin
						swap_done <= 1'b1;
						state      <= S_IDLE;
					end else begin
						clear_addr <= clear_addr + 17'd1;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
