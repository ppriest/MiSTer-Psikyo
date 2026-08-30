// SH403/SH404 security-device model (Strikers 1945 / Tengai).
//
// The real chip is a PIC16C57, but MAME never executes it
// (`PIC16C57(...).set_disable()`); psikyo.cpp instead simulates the
// protection as ~9 bytes of state plus a command decoder (`s1945_mcu_*`),
// and this module is a direct translation of that simulation -- see
// docs/phase2_sh404.md "The security device" for the traced protocol,
// including the read-side effects.
//
// The per-set answer table (44 meaningful bytes; s1945/s1945a/s1945j
// differ in five positions, s1945k reuses s1945's, tengai has NONE) is
// NOT hardcoded: the .mra delivers it in the mod-ROM payload (index 1,
// bytes 4..47) through the table_w* port. The index is 8-bit into a
// zero-filled 256-byte array, exactly like MAME's `static const u8
// table[256]` with 44 initializers -- unwritten entries read 0.
//
// table_absent (tengai) is not the same as an all-zero table: MAME's
// command 0x013 leaves latch1 UNCHANGED when the table pointer is null,
// rather than loading a zero.
module s1945_mcu (
	input  logic clk,
	input  logic reset,

	// Byte-register write strobes from the 68020 bus decode (one-cycle
	// pulses, maincpu.sv's wr_now gated per byte lane). A word write to
	// 0xC00006 hits data (UDS lane) and bctrl (LDS lane) in the same
	// cycle, which is why the two lanes' data arrive separately.
	input  logic        wr_data,        // 0xC00006 (UDS lane)
	input  logic        wr_bctrl,       // 0xC00007 (LDS lane)
	input  logic        wr_control,     // 0xC00008 (UDS lane)
	input  logic        wr_direction,   // 0xC00009 (LDS lane)
	input  logic        wr_command,     // 0xC0000B (LDS lane)
	input  logic [7:0] wdata_h,         // cpu_dout[15:8] (UDS lane byte)
	input  logic [7:0] wdata_l,         // cpu_dout[7:0]  (LDS lane byte)

	// Read-side values (combinational; the caller muxes them into its
	// input-port reads) and the two read side effects, pulsed by the
	// caller once per bus access:
	//  - rd_consume: the word at 0xC00006 was read. MAME sets the
	//    latching bit AFTER returning the data ("the read consumes it").
	//  - rd_status_toggle: the word at 0xC00002 was read; the free-
	//    running status bit flips (MAME's own "hack" -- POST spins on it
	//    going both ways).
	output logic [7:0] data_byte,       // 0xC00006 read: latch or 0xFF
	output logic [7:0] control_byte,    // 0xC00008 read: latching | 0x08
	output logic [7:0] bctrl,           // tile banks + readback bits 7:4
	output logic        mcu_status,     // P1_P2 bit 2, ACTIVE_HIGH, raw
	input  logic        rd_consume,
	input  logic        rd_status_toggle,

	// Answer table, loaded from the .mra mod payload at download time.
	input  logic        table_absent,
	input  logic        table_we,
	input  logic [7:0] table_waddr,
	input  logic [7:0] table_wdata
);

	// ---- state (reset values = MAME machine_start init) ----
	logic [7:0] direction, inlatch, latch1, latch2, control, index, mode;
	logic [2:0] latching;

	// ---- answer table ----
	// plain always (not always_ff): the initial-block zero fill counts as a
	// second driver under always_ff rules (vlog-7061), and inferred-RAM
	// init needs the initial block.
	logic [7:0] table_mem [0:255];
	initial for (int i = 0; i < 256; i++) table_mem[i] = 8'h00;
	always @(posedge clk) if (table_we) table_mem[table_waddr] <= table_wdata;

	// Continuously registered read at the current index: `index` is set by
	// command 0x11C and consumed by a LATER 0x013 bus access, always many
	// clocks apart, so the one-cycle BRAM latency never races the use.
	logic [7:0] table_rdata;
	always_ff @(posedge clk) table_rdata <= table_mem[index];

	// ---- reads (combinational) ----
	// Not-ready reads return 0xFF, NOT 0x00 -- and control bit 4 selects
	// which latch/ready-bit pair the data port exposes.
	assign data_byte = control[4] ? (latching[2] ? 8'hFF : latch1)
								   : (latching[0] ? 8'hFF : latch2);
	assign control_byte = {4'b0000, 1'b1, latching};   // latching | 0x08

	// ---- writes, command decode, read side effects ----
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			direction  <= 8'h00;
			inlatch    <= 8'hFF;
			latch1     <= 8'hFF;
			latch2     <= 8'hFF;
			latching   <= 3'b101;
			control    <= 8'hFF;
			index      <= 8'h00;
			mode       <= 8'h00;
			bctrl      <= 8'h00;
			mcu_status <= 1'b0;
		end else begin
			if (wr_data)       inlatch    <= wdata_h;
			if (wr_bctrl)      bctrl      <= wdata_l;
			if (wr_control)    control    <= wdata_h;
			if (wr_direction)  direction  <= wdata_l;

			if (wr_command) begin
				// MAME: switch (data | (direction ? 0x100 : 0))
				case ({direction != 8'h00, wdata_l})
					9'h11C: begin
						latching <= 3'b101;
						index    <= inlatch;
					end
					9'h013: begin
						latching <= 3'b001;
						if (!table_absent) latch1 <= table_rdata;
					end
					9'h113: begin
						mode <= inlatch;
						if (inlatch == 8'h01) begin
							// latching &= ~1; latch2 = 0x55; then &= ~4
							latching <= {1'b0, latching[1], 1'b0};
							latch2    <= 8'h55;
						end else begin
							// latching &= ~1; |= 2; then &= ~4
							latching <= 3'b010;
						end
						latch1 <= inlatch;
					end
					9'h010, 9'h110: latching[2] <= 1'b1;
					default: ;   // unhandled commands are ignored, as in MAME
				endcase
			end else if (rd_consume) begin
				// never coincides with wr_command (one 68020 bus op at a
				// time), but the else keeps the priority explicit
				if (control[4]) latching[2] <= 1'b1;
				else             latching[0] <= 1'b1;
			end

			if (rd_status_toggle) mcu_status <= ~mcu_status;
		end
	end

endmodule
