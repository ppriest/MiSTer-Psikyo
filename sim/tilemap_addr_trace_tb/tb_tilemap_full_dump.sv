// Decodes the ENTIRE layer-1 tilemap (all 4096 VRAM cells = the full
// mode-3 32x128 tile grid) using the REAL captured VRAM content, the REAL
// layer-1 config (bank=1), the REAL tiles GFX ROM (u33.bin), AND the REAL
// captured palette RAM content -- all through the actual RTL modules
// (tile_cell_decode.sv, tile_row_decode.sv, compositor.sv, dpram.sv), not
// a Python re-implementation of any of it. Python is used ONLY to arrange
// the RTL's own final rgb output into a bitmap image -- no color math, no
// address formula, happens outside the RTL.
//
// Deliberately bypasses tilemap_line_engine.sv's fetch FSM (sized for one
// 320px screen line, not a full 512px tilemap row) -- raw tile-grid dump,
// address order, no scroll/screen constraint.
//
// compositor.sv is driven with layer 0 and sprites both disabled
// (l0_valid=0, sp_present=0) and layer 1 forced opaque (l1_ctrl_opaque=1,
// so even pen-15 "transparent" pixels render their real palette color
// instead of being skipped -- this is a raw memory dump, not a composited
// frame) -- isolating layer 1's own real pal_addr computation and real
// palette RAM read.
//
// Output: full_tilemap_dump.txt, one line per VRAM address (0-4095):
// "addr tile_number color " followed by 256 space-separated "RRGGBB" hex
// triples (16 rows x 16 pixels, row-major) -- the RTL's OWN final rgb
// output, already xRGB555->RGB888 expanded by... actually rgb stays 15-bit
// (compositor.sv's own output format); expansion to 8-bit/channel is a
// pure bit-replication with no color information added or altered, done
// here in the testbench itself (not Python) for exactly that reason.

module tb_tilemap_full_dump;

	logic clk = 0;
	always #5 clk = ~clk;

	// ---- real VRAM1 content ----
	logic [15:0] vram1 [0:4095];
	initial $readmemh("real_vram1_dump.hex", vram1);

	// ---- real tiles GFX ROM (u33.bin, map="12" byte-swap already applied
	// in the hex file itself) ----
	logic [7:0] gfxrom [0:2097151];
	initial $readmemh("u33_swapped.hex", gfxrom);

	// ---- tile_cell_decode: LAYER=1, bank fixed at 1 (per-layer vreg, not
	// per-cell -- confirmed from the real control word 0x04D0's bit10) ----
	logic [15:0] vram_cell;
	logic [1:0]  bank = 2'd1;
	logic [14:0] tile_number;
	logic [6:0]  color;

	tile_cell_decode #(.LAYER(1)) u_celldec (
		.vram_cell(vram_cell), .bank(bank),
		.tile_number(tile_number), .color(color)
	);

	// ---- tile_row_decode: one row (8 bytes -> 16 pixels) at a time ----
	logic [7:0] row_bytes [0:7];
	logic       flip_x = 1'b0;
	logic [3:0] pixel [0:15];

	tile_row_decode u_rowdec (
		.row_bytes(row_bytes), .flip_x(flip_x), .pixel(pixel)
	);

	// ---- real palette RAM, real captured content, real dpram module --
	// registered read, same 1-cycle latency as production (psikyo_core.sv
	// wires u_palette's b-port exactly this way). ----
	logic [11:0] pal_a_addr = 12'd0;
	logic [15:0] pal_a_wdata = 16'd0;
	logic [15:0] pal_a_rdata;
	logic [11:0] pal_b_addr;
	logic [15:0] pal_b_rdata;

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
		.clk(clk),
		.a_addr(pal_a_addr), .a_wel(1'b0), .a_weh(1'b0),
		.a_wdata(pal_a_wdata), .a_rdata(pal_a_rdata),
		.b_addr(pal_b_addr), .b_rdata(pal_b_rdata)
	);
	initial $readmemh("real_palette_dump.hex", u_palette.mem);

	// ---- real compositor: layer 0 and sprites disabled, layer 1 forced
	// opaque so every pixel (including pen 15) renders its real color --
	// this is a raw dump, not a composited frame with transparency. ----
	logic [11:0] pal_addr;
	logic [14:0] rgb;
	logic [3:0]  pixel_cur;   // fed to compositor.l1_pixel, one value at a time

	compositor u_compositor (
		.l0_valid(1'b0), .l0_pixel(4'd0), .l0_color(7'd0),
		.l0_ctrl_enable(1'b0), .l0_ctrl_opaque(1'b0), .l0_ctrl_transpen_sel(1'b0),

		.l1_valid(1'b1), .l1_pixel(pixel_cur), .l1_color(color),
		.l1_ctrl_enable(1'b1), .l1_ctrl_opaque(1'b1), .l1_ctrl_transpen_sel(1'b0),

		.sp_present(1'b0), .sp_pixel(4'd0), .sp_color(5'd0), .sp_priority(2'd0),

		.pal_addr(pal_addr), .pal_data(pal_b_rdata),
		.rgb(rgb)
	);
	assign pal_b_addr = pal_addr;

	integer fout;
	integer addr, row, col, k;
	integer tile_base;
	logic [4:0] r5, g5, b5;
	logic [7:0] r8, g8, b8;

	initial begin
		fout = $fopen("full_tilemap_dump.txt", "w");
		if (fout == 0) begin
			$display("FAIL: could not open output file");
			$finish;
		end

		@(posedge clk);   // let dpram's initial garbage settle before first real read

		for (addr = 0; addr < 4096; addr = addr + 1) begin
			vram_cell = vram1[addr];
			#1;   // let tile_cell_decode settle

			$fwrite(fout, "%0d %0d %0d ", addr, tile_number, color);

			tile_base = tile_number * 128;
			for (row = 0; row < 16; row = row + 1) begin
				for (k = 0; k < 8; k = k + 1)
					row_bytes[k] = gfxrom[tile_base + row*8 + k];
				#1;   // let tile_row_decode settle -> pixel[0:15] valid

				for (col = 0; col < 16; col = col + 1) begin
					pixel_cur = pixel[col];
					#1;                  // let compositor's pal_addr settle
					@(posedge clk);       // real palette dpram's registered read
					#1;                  // let pal_b_rdata/rgb propagate through compositor
					r5 = rgb[14:10]; g5 = rgb[9:5]; b5 = rgb[4:0];
					r8 = {r5, r5[4:2]}; g8 = {g5, g5[4:2]}; b8 = {b5, b5[4:2]};
					$fwrite(fout, "%02h%02h%02h ", r8, g8, b8);
				end
			end
			$fwrite(fout, "\n");
		end

		$fclose(fout);
		$display("PASS: dumped 4096 cells (tile_number/color/256 RTL-computed rgb pixels each) to full_tilemap_dump.txt");
		$finish;
	end

endmodule
