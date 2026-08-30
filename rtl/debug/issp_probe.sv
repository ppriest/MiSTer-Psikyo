// In-System Sources and Probes instrumentation for the SDRAM path.
//
// WHY THIS RATHER THAN SIGNALTAP
// SignalTap acquisition is not scriptable in Quartus Prime Lite 17.0 -- there
// are no *signaltap*/*stp* Tcl commands, only the GUI. In-System Sources and
// Probes IS scriptable (start_insystem_source_probe / read_probe_data /
// write_source_data), which matters for a headless workflow.
//
// It also suits the question better. The failure is "SDRAM reads return 0000
// for every address", and what distinguishes the possible causes is not a
// waveform but a handful of counts:
//
//   writes issued == 0            -> the one-shot never fires (dl_req/ready)
//   issued > 0, acked == 0        -> the controller never accepts writes
//   issued == acked, reads == 0   -> reads are not being serviced
//   reads > 0, never non-zero     -> memory is genuinely empty; download lost
//
// Counters saturate rather than wrap so a reading is never ambiguous about
// whether something happened a lot or exactly 65536 times.
module issp_probe #(
	parameter [7:0] INSTANCE_ID = "D"
) (
	input logic clk,

	input logic wr_issued,      // one write request pulse
	input logic wr_acked,       // controller acknowledged a write
	input logic cpu_rd_acked,   // a CPU ROM read completed
	input logic cpu_rd_nonzero, // ...and returned something other than 0000
	input logic         sdram_ready,
	input logic         dl_req,
	input logic         ioctl_download,

	// The decisive question: what does the CPU actually read at boot? The
	// first four reads after reset are the 68020's reset vector (SP then PC).
	// If those come back wrong, nothing else matters.
	input logic         reset,
	input logic [18:0]  cpu_rd_addr,
	input logic [15:0]  cpu_rd_data
);

	logic [15:0] wr_issued_cnt, wr_ack_cnt, cpu_rd_cnt;
	logic        dl_req_seen, dl_seen, rd_nonzero_seen;
	logic        clear;

	// First four post-reset reads, latched once and never overwritten.
	logic [15:0] boot_data [0:3];
	logic [18:0] boot_addr0;
	logic [2:0]  boot_n;

	always_ff @(posedge clk) begin
		if (reset) begin
			boot_n <= 3'd0;
		end else if (cpu_rd_acked && boot_n < 3'd4) begin
			boot_data[boot_n[1:0]] <= cpu_rd_data;
			if (boot_n == 3'd0) boot_addr0 <= cpu_rd_addr;
			boot_n <= boot_n + 3'd1;
		end
	end

	always_ff @(posedge clk) begin
		if (clear) begin
			wr_issued_cnt <= '0; wr_ack_cnt <= '0; cpu_rd_cnt <= '0;
			dl_req_seen <= 1'b0; dl_seen <= 1'b0; rd_nonzero_seen <= 1'b0;
		end else begin
			if (wr_issued    && wr_issued_cnt != 16'hFFFF) wr_issued_cnt <= wr_issued_cnt + 1'b1;
			if (wr_acked     && wr_ack_cnt    != 16'hFFFF) wr_ack_cnt    <= wr_ack_cnt    + 1'b1;
			if (cpu_rd_acked && cpu_rd_cnt    != 16'hFFFF) cpu_rd_cnt    <= cpu_rd_cnt    + 1'b1;
			if (dl_req)                    dl_req_seen      <= 1'b1;
			if (ioctl_download)            dl_seen          <= 1'b1;
			if (cpu_rd_acked && cpu_rd_nonzero) rd_nonzero_seen <= 1'b1;
		end
	end

	// 16*4 + 19 + 3 + 4 + 48 = 138 bits
	wire [137:0] probe_bus = {boot_data[3], boot_data[2], boot_data[1], boot_data[0],
							   boot_addr0, boot_n,
							   rd_nonzero_seen, dl_seen, dl_req_seen, sdram_ready,
							   cpu_rd_cnt, wr_ack_cnt, wr_issued_cnt};
	wire [0:0]  source_bus;
	assign clear = source_bus[0];

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(138),
		.source_width(1),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp (
		.probe(probe_bus),
		.source(source_bus),
		.source_clk(clk),
		.source_ena(1'b1)
	);

endmodule
