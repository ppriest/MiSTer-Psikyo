// Fast ROM loading: bulk copy from DDR3 into the SDRAM ROM map.
//
// The slow path streams the ROM through hps_io's ioctl interface a byte at a
// time, stalling the HPS with ioctl_wait for an SDRAM transaction on every
// one of ~14MB. The fast path removes the FPGA from the transfer entirely:
// an `address="0x30000000"` attribute on the .mra's <rom index="0"> makes
// the HPS DMA the ROM straight into DDR3, so the core sees ioctl_download
// assert and deassert with NO ioctl_wr pulses at all. This module then
// copies DDR3 -> SDRAM at full speed with the core held in reset, reading
// 8-byte granules and writing them as four 16-bit SDRAM words.
// (Mechanism taken from srg320/Arcade-PsikyoSH2_MiSTer.)
//
// The two paths coexist: an .mra WITHOUT the address attribute still streams
// through ioctl and sdram_download exactly as before. The caller decides
// which ran by watching whether any ioctl_wr arrived during the download.
module rom_loader #(
	// Bytes to copy: the whole SDRAM ROM map (docs/phase1_sdram_map.md).
	// Copying the full map unconditionally avoids having to know each set's
	// real length, and costs only the copy time of the padding.
	parameter logic [27:0] LENGTH = 28'h1280000
) (
	input  logic clk,
	input  logic reset,

	input  logic         start,   // pulse: begin the copy
	output logic         busy,    // 1 while copying; hold the core in reset

	// samuraia/sngkace ADPCM-A bit 6/7 swap. On the ioctl path this is done
	// as the bytes arrive; on this path they never pass through the FPGA, so
	// it has to happen here instead.
	input  logic         needs_adpcma_swap,
	input  logic [24:0] adpcma_base,

	// DDR3 read port (rtl/memory/ddram_phy.sv): 8-byte granules, byte offset
	// from the 0x30000000 HPS extra-RAM base the .mra loads to.
	output logic         ddr_req,
	output logic [27:0] ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0] ddr_rdata,

	// SDRAM write port -- same hold-until-busy contract as sdram_download's.
	output logic         dl_req,
	output logic [24:0] dl_addr,
	output logic [15:0] dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	typedef enum logic [2:0] {L_IDLE, L_RD, L_RDWAIT, L_WR, L_WRACK, L_NEXT} lstate_t;
	lstate_t state;

	logic [27:0] byte_addr;    // running offset, granule-aligned
	logic [63:0] gran;
	logic [1:0]  word_idx;     // which 16-bit word of the granule

	assign busy    = (state != L_IDLE);
	assign ddr_req = (state == L_RD);
	assign ddr_addr = byte_addr;
	assign dl_req  = (state == L_WR);
	assign dl_we16 = 1'b1;     // both byte lanes, one SDRAM transaction per word
	assign dl_addr = 25'(byte_addr) + {23'd0, word_idx, 1'b0};

	// The granule arrives little-endian: ROM byte N sits at bit (N%8)*8, so
	// word k is simply gran[k*16 +: 16] and lands at byte_addr + k*2.
	logic [15:0] raw_word;
	always_comb begin
		unique case (word_idx)
			2'd0: raw_word = gran[15:0];
			2'd1: raw_word = gran[31:16];
			2'd2: raw_word = gran[47:32];
			2'd3: raw_word = gran[63:48];
		endcase
	end

	// Per BYTE, and only inside the 1MB ADPCM-A window -- a ROM-mastering
	// artifact of the individual sample bytes (MAME's init_sngkace).
	wire in_adpcma = (dl_addr >= adpcma_base) && (dl_addr < adpcma_base + 25'h100000);
	wire [7:0] lo = {raw_word[6],  raw_word[7],  raw_word[5:0]};
	wire [7:0] hi = {raw_word[14], raw_word[15], raw_word[13:8]};
	assign dl_data = (needs_adpcma_swap && in_adpcma) ? {hi, lo} : raw_word;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state     <= L_IDLE;
			byte_addr <= 28'd0;
			word_idx  <= 2'd0;
		end else begin
			case (state)
				L_IDLE: if (start) begin
					byte_addr <= 28'd0;
					word_idx  <= 2'd0;
					state     <= L_RD;
				end

				// ddram_phy takes a pulse only while not busy
				L_RD: if (!ddr_busy) state <= L_RDWAIT;

				L_RDWAIT: if (ddr_valid) begin
					gran     <= ddr_rdata;
					word_idx <= 2'd0;
					state    <= L_WR;
				end

				// hold dl_req until the arbiter takes it, then until it frees
				L_WR:    if (dl_busy)  state <= L_WRACK;
				L_WRACK: if (!dl_busy) begin
					if (word_idx == 2'd3) state <= L_NEXT;
					else begin
						word_idx <= word_idx + 2'd1;
						state    <= L_WR;
					end
				end

				L_NEXT: begin
					if (byte_addr + 28'd8 >= LENGTH) state <= L_IDLE;
					else begin
						byte_addr <= byte_addr + 28'd8;
						state     <= L_RD;
					end
				end

				default: state <= L_IDLE;
			endcase
		end
	end

endmodule
