// Translates hps_io's real ROM-download interface (checked directly
// against sys/hps_io.sv's port list, not assumed) into ddram_arbiter's
// hold-until-acknowledged dl_req contract (rtl/memory/ddram_arbiter.sv).
//
// hps_io delivers one byte per `ioctl_wr` pulse (single cycle, `ioctl_addr`/
// `ioctl_dout` stable that same cycle) while `ioctl_download` is held high
// for the whole transfer. `ioctl_wait` is an OUTPUT from our side back to
// hps_io -- checked directly against hps_io.sv: this module itself doesn't
// interpret ioctl_wait at all, it's wired straight out to HPS_BUS, meaning
// the actual backpressure enforcement happens on the HPS/Linux side with
// some round-trip latency, not as a same-cycle combinational handshake.
// The safe, standard pattern (matching real MiSTer cores): hold
// ioctl_wait=1 continuously from the moment a byte is accepted until this
// module is fully ready for the next one, never assume tighter timing than
// that.
//
// ioctl_addr is 27 bits, relative to the start of THIS download (0-based
// for the rom index="0" blob every Phase 1 .mra uses) -- zero-extended
// directly into dl_addr's 28 bits, no region-base math here. Whether that
// lines up with docs/phase1_ddram_map.md's fixed region layout depends on
// the .mra files actually using that layout, which they don't yet (see
// ROADMAP.md) -- not this module's concern, it just forwards addresses
// faithfully.
//
// Only ioctl_index==0 is accepted (the only rom index any Phase 1 .mra
// uses) -- a download under a different index is ignored here rather than
// misdirected into the DDRAM ROM region.

module ddram_download (
	input  logic clk,
	input  logic reset,

	// hps_io side
	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	// ddram_arbiter side
	output logic         dl_req,
	output logic [27:0] dl_addr,
	output logic [7:0]  dl_data,
	input  logic         dl_busy
);

	typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT} dstate_t;
	dstate_t dstate;

	logic [26:0] addr_r;
	logic [7:0]  data_r;

	assign dl_addr = {1'b0, addr_r};
	assign dl_data = data_r;
	assign dl_req  = (dstate == D_REQ);
	assign ioctl_wait = (dstate != D_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			dstate <= D_IDLE;
		end else begin
			case (dstate)
				D_IDLE: begin
					if (ioctl_download && (ioctl_index == 16'd0) && ioctl_wr) begin
						addr_r <= ioctl_addr;
						data_r <= ioctl_dout;
						dstate <= D_REQ;
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
