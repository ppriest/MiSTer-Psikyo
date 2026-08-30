// Translates hps_io's real ROM-download interface into sdram_arbiter5's
// hold-until-acknowledged dl_req contract -- identical in every respect to
// rtl/memory/ddram_download.sv except dl_addr is 25 bits (sdram_arbiter5's
// byte address into the 32MB SDR SDRAM chip) instead of ddram_arbiter's
// 28-bit DDRAM window. See ddram_download.sv's own header for the full
// hps_io interface reasoning (ioctl_wr is a one-shot pulse, ioctl_wait must
// be held from acceptance until fully ready for the next byte, only
// ioctl_index==0 is accepted) -- not repeated here since nothing about that
// reasoning changes for the SDRAM transport.

module sdram_download (
	input  logic clk,
	input  logic reset,

	// hps_io side
	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	// sdram_arbiter5 side
	output logic         dl_req,
	output logic [24:0] dl_addr,
	output logic [15:0] dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	// ---- byte-pair coalescing ----
	// ROM loading used to cost one full SDRAM round trip per BYTE, with
	// ioctl_wait stalling the HPS for every one of ~14MB. The stream is
	// sequential, so an EVEN byte is just latched -- accepted with no SDRAM
	// transaction and no stall at all -- and its ODD partner then writes
	// both lanes in a single transaction (sdram_phy's we16). That halves the
	// SDRAM transactions AND the number of stalls.
	//
	// hps_io is deliberately NOT in WIDE mode: sys/hiscore.v parses the ioctl
	// stream byte-wise, so the widening has to happen here rather than at the
	// interface.
	//
	// A pending even byte that does not get its partner (a non-sequential
	// jump, or the end of the download) is flushed as a single-byte write,
	// so no data can be silently dropped.
	typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT} dstate_t;
	dstate_t dstate;

	logic [24:0] addr_r;
	logic [15:0] data_r;
	logic        we16_r;

	// buffered even byte awaiting its odd partner
	logic        pend_valid;
	logic [24:0] pend_addr;
	logic [7:0]  pend_data;

	wire         accept = ioctl_download && (ioctl_index == 16'd0) && ioctl_wr;
	// incoming byte completes the buffered one: buffered is the EVEN half,
	// incoming is the ODD half of the same word
	wire         pairs  = pend_valid && !pend_addr[0] && ioctl_addr[0]
	                     && (ioctl_addr[24:1] == pend_addr[24:1]);

	assign dl_addr = addr_r;
	assign dl_data = data_r;
	assign dl_we16 = we16_r;
	assign dl_req  = (dstate == D_REQ);
	// An even byte that merely lands in the buffer needs no stall; only a
	// real SDRAM transaction does.
	assign ioctl_wait = (dstate != D_IDLE);

	logic dl_active_d;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			dstate     <= D_IDLE;
			pend_valid <= 1'b0;
			we16_r     <= 1'b0;
			dl_active_d <= 1'b0;
		end else begin
			dl_active_d <= ioctl_download;

			case (dstate)
				D_IDLE: begin
					// Every accepted byte is buffered; a transaction is only
					// emitted once a pair completes, the buffer must make way
					// for a byte that does not pair with it, or the download
					// ends. Nothing is ever dropped: ioctl_wr is a one-shot
					// pulse, so the incoming byte is always kept.
					if (accept) begin
						if (pairs) begin
							addr_r     <= pend_addr;
							data_r     <= {ioctl_dout, pend_data};
							we16_r     <= 1'b1;   // both lanes, one transaction
							pend_valid <= 1'b0;
							dstate     <= D_REQ;
						end else if (pend_valid) begin
							// no pair: write the buffered byte alone and keep
							// the new one for the next round
							addr_r     <= pend_addr;
							data_r     <= {8'd0, pend_data};
							we16_r     <= 1'b0;
							pend_addr  <= ioctl_addr;
							pend_data  <= ioctl_dout;
							dstate     <= D_REQ;
						end else begin
							// buffer only -- no SDRAM transaction, no stall
							pend_addr  <= ioctl_addr;
							pend_data  <= ioctl_dout;
							pend_valid <= 1'b1;
						end
					end else if (pend_valid && dl_active_d && !ioctl_download) begin
						// download ended with a byte still buffered
						addr_r     <= pend_addr;
						data_r     <= {8'd0, pend_data};
						we16_r     <= 1'b0;
						pend_valid <= 1'b0;
						dstate     <= D_REQ;
					end
				end

				D_REQ: begin
					if (dl_busy) dstate <= D_WAIT;
				end

				D_WAIT: begin
					if (!dl_busy) dstate <= D_IDLE;
				end
			endcase
		end
	end

endmodule
