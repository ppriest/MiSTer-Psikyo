// Routes four req/valid read-only consumers -- tilemap layer 0 gfxrom,
// tilemap layer 1 gfxrom, sprite gfxrom, sprite spritelut (the four ports
// docs/phase1_ddram_map.md's "Arbiter architecture" section lists as
// already req/valid and ready to serve without redesign) -- plus one
// download-write port (for the HPS ioctl_download ROM-loading path, not
// yet wired to hps_io -- top-level integration work, out of scope here)
// onto the single physical ddram_phy port.
//
// Download always wins immediately (no round-robin fairness against it --
// it's only active during ROM loading, before gameplay starts, so it can
// safely take absolute priority with no real gameplay-time cost, per the
// design doc). Among the four read consumers, a simple rotating-pointer
// round robin: whichever consumer gets served has its priority rotated to
// the back, so sustained pressure from one consumer can't starve another
// -- correctness-and-fairness first, not throughput-optimized (matches
// this project's ddram_phy v1 stance: no bursting yet either).
//
// Client-facing addresses (c0_addr..c3_addr, dl_addr) are already full
// byte offsets into the DDRAM window, including whatever per-region base
// offset docs/phase1_ddram_map.md assigns -- this module has no notion of
// regions, it's purely a transport-layer arbiter.
//
// Request contract, all five ports (c0..c3_req, dl_req): HOLD req asserted
// until the matching valid/busy acknowledgment, don't just pulse it for
// one cycle -- matches the real gfxrom_req/lut_req convention already
// established in tilemap_line_engine/sprite_render_engine (checked
// directly against sprite_render_engine.sv, not assumed), and is required
// here because this arbiter can take many cycles to get around to a given
// consumer while serving others; a one-shot pulse would silently be lost
// if it arrived while the arbiter was mid-transaction elsewhere (a real
// bug caught in tb_ddram_arbiter.sv's Case 4 during this module's own
// testbench work). dl_req specifically: hps_io's real ioctl_wr is a
// one-shot pulse, so the eventual HPS-facing wrapper (top-level
// integration, not built yet) is responsible for translating that into
// this held-request convention -- most likely via ioctl_wait backpressure
// while dl_req is asserted and !dl_busy hasn't yet flipped to busy.

module ddram_arbiter (
	input  logic clk,
	input  logic reset,

	// physical port (to ddram_phy)
	output logic         phy_req,
	output logic         phy_we,
	output logic [27:0] phy_addr,
	output logic [7:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0] phy_rdata,

	// consumer 0: tilemap layer 0 gfxrom
	input  logic         c0_req,
	input  logic [27:0] c0_addr,
	output logic         c0_valid,
	output logic [63:0] c0_data,

	// consumer 1: tilemap layer 1 gfxrom
	input  logic         c1_req,
	input  logic [27:0] c1_addr,
	output logic         c1_valid,
	output logic [63:0] c1_data,

	// consumer 2: sprite gfxrom
	input  logic         c2_req,
	input  logic [27:0] c2_addr,
	output logic         c2_valid,
	output logic [63:0] c2_data,

	// consumer 3: sprite spritelut
	input  logic         c3_req,
	input  logic [27:0] c3_addr,
	output logic         c3_valid,
	output logic [63:0] c3_data,

	// HPS ROM-download write path -- absolute priority, pulse dl_req for
	// one cycle while !dl_busy to write one byte
	input  logic         dl_req,
	input  logic [27:0] dl_addr,
	input  logic [7:0]  dl_data,
	output logic         dl_busy
);

	logic [3:0] c_req;
	logic [27:0] c_addr [0:3];
	assign c_req    = {c3_req, c2_req, c1_req, c0_req};
	assign c_addr[0] = c0_addr;
	assign c_addr[1] = c1_addr;
	assign c_addr[2] = c2_addr;
	assign c_addr[3] = c3_addr;

	typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT_READ, A_WAIT_WRITE} astate_t;
	astate_t astate;

	logic [1:0] rr_ptr;
	logic [1:0] sel;
	logic         sel_is_dl;

	// combinational round-robin picker: starting at rr_ptr, find the first
	// requesting channel (wrapping mod 4)
	logic [1:0] next_sel;
	logic         found;
	always_comb begin
		found    = 1'b0;
		next_sel = rr_ptr;
		for (int i = 0; i < 4; i++) begin
			logic [1:0] idx;
			idx = rr_ptr + i[1:0];
			if (!found && c_req[idx]) begin
				next_sel = idx;
				found    = 1'b1;
			end
		end
	end

	assign dl_busy = (astate != A_IDLE) && sel_is_dl;

	assign phy_addr  = sel_is_dl ? dl_addr : c_addr[sel];
	assign phy_wdata = dl_data;
	assign phy_we    = sel_is_dl;
	assign phy_req   = (astate == A_ISSUE) && !phy_busy;

	assign c0_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 2'd0) && phy_valid;
	assign c1_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 2'd1) && phy_valid;
	assign c2_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 2'd2) && phy_valid;
	assign c3_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 2'd3) && phy_valid;
	assign c0_data  = phy_rdata;
	assign c1_data  = phy_rdata;
	assign c2_data  = phy_rdata;
	assign c3_data  = phy_rdata;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			astate <= A_IDLE;
			rr_ptr <= 2'd0;
			sel_is_dl <= 1'b0;
		end else begin
			case (astate)
				A_IDLE: begin
					if (dl_req) begin
						sel_is_dl <= 1'b1;
						astate    <= A_ISSUE;
					end else if (found) begin
						sel       <= next_sel;
						sel_is_dl <= 1'b0;
						astate    <= A_ISSUE;
					end
				end

				A_ISSUE: begin
					// phy_req pulsed this cycle (combinational, gated by
					// !phy_busy). Once accepted, move to the matching wait
					// state; if phy_busy was unexpectedly still high (should
					// not happen given this arbiter fully serializes access
					// to ddram_phy), simply retry next cycle.
					if (!phy_busy) astate <= sel_is_dl ? A_WAIT_WRITE : A_WAIT_READ;
				end

				A_WAIT_READ: begin
					if (phy_valid) begin
						rr_ptr <= sel + 2'd1;
						astate <= A_IDLE;
					end
				end

				A_WAIT_WRITE: begin
					if (!phy_busy) astate <= A_IDLE;
				end
			endcase
		end
	end

endmodule
