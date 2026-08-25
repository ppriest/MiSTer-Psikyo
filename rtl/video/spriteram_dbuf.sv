// Hardware-buffered sprite RAM (0x400000-0x401FFF), modelling MAME's
// buffered_spriteram32_device.
//
// Contract: the CPU sees ONE persistent RAM. On vblank's rising edge the whole
// contents are COPIED into a second buffer, and the sprite engine renders only
// from that frozen copy.
//
// A bank swap is NOT equivalent: under ping-pong the CPU writes bank A one
// frame and bank B the next, so any entry it does not rewrite every frame reads
// back what was written two frames ago -- including the display list's
// end-of-list marker. See docs/LESSONS_LEARNED.md.
//
// The copy is 4096 words, ~4098 cycles against vblank's 207,936. copy_busy is
// exported so the render engine can be held off until it completes.
//
// The control word (0xFFF) is not read back through at_addr/dl_addr, so it is
// shadowed on the live side and latched into ctrl_active at frame_start.
module spriteram_dbuf (
    input  logic clk,
    input  logic reset,

    input  logic frame_start,   // pulse: snapshot the live RAM (video_timing.sv's vblank-rising pulse)
    output logic copy_busy,     // 1 while the snapshot is being taken; render must not start

    // CPU-facing port -- always the live bank, never swapped.
    input  logic [11:0] cpu_addr,
    input  logic         cpu_wel,
    input  logic         cpu_weh,
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rdata,

    // Render-facing ports -- always the frozen snapshot bank.
    input  logic [11:0] dl_addr,
    output logic [15:0] dl_data,
    input  logic [11:0] at_addr,
    output logic [15:0] at_data,

    // This frame's frozen control-word bits (docs/phase1_memory_map.md):
    // bit 0 sprites-disable, bit 2 -> trans pen 0, bit 3 -> trans pen 15.
    output logic         sprites_disable,
    output logic         trans_pen0,
    output logic         trans_pen15
);

    localparam logic [11:0] CTRL_ADDR = 12'hFFF;
    localparam int          DEPTH      = 4096;

    // ---- copy sequencer ----
    // copy_rd_addr is presented to the live bank's port B; dpram registers
    // its read, so the word arrives one cycle later and is written to the
    // snapshot at copy_wr_addr, which trails by exactly that one cycle.
    logic         copying;
    logic [11:0] copy_rd_addr;
    logic [11:0] copy_wr_addr;
    logic         copy_wr_en;

    assign copy_busy = copying | copy_wr_en;

    logic [15:0] live_b_rdata;

    // ---- live bank: CPU on port A, copy read on port B ----
    logic [15:0] live_a_rdata;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_live (
        .clk(clk),
        .a_addr(cpu_addr),
        .a_wel(cpu_wel),
        .a_weh(cpu_weh),
        .a_wdata(cpu_wdata),
        .a_rdata(live_a_rdata),
        .b_addr(copy_rd_addr),
        .b_rdata(live_b_rdata)
    );

    // ---- snapshot bank: copy write / attribute read on port A, display
    // list read on port B. at_addr's read is meaningless during the copy,
    // which is safe because copy_busy holds the render engine off.
    logic [15:0] snap_a_rdata;
    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_snap (
        .clk(clk),
        .a_addr(copy_wr_en ? copy_wr_addr : at_addr),
        .a_wel(copy_wr_en),
        .a_weh(copy_wr_en),
        .a_wdata(live_b_rdata),
        .a_rdata(snap_a_rdata),
        .b_addr(dl_addr),
        .b_rdata(dl_data)
    );

    assign cpu_rdata = live_a_rdata;
    assign at_data   = snap_a_rdata;

    // ---- control word shadow (live side) and this frame's frozen value ----
    logic [15:0] ctrl_shadow;
    logic [15:0] ctrl_active;
    wire         cpu_we = cpu_wel | cpu_weh;

    always_ff @(posedge clk or posedge reset) begin
        if (reset)                                   ctrl_shadow <= 16'h0000;
        else if (cpu_we && cpu_addr == CTRL_ADDR)  ctrl_shadow <= cpu_wdata;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            copying      <= 1'b0;
            copy_rd_addr <= 12'd0;
            copy_wr_addr <= 12'd0;
            copy_wr_en   <= 1'b0;
            // Sprites held disabled (bit 0) until the first real frame_start
            // latches genuine CPU-written content -- a safe power-on default.
            ctrl_active  <= 16'h0001;
        end else begin
            copy_wr_en <= 1'b0;

            if (frame_start) begin
                copying      <= 1'b1;
                copy_rd_addr <= 12'd0;
                ctrl_active  <= ctrl_shadow;
            end else if (copying) begin
                copy_wr_en   <= 1'b1;
                copy_wr_addr <= copy_rd_addr;
                if (copy_rd_addr == DEPTH - 1) copying      <= 1'b0;
                else                             copy_rd_addr <= copy_rd_addr + 12'd1;
            end
        end
    end

    assign sprites_disable = ctrl_active[0];
    assign trans_pen0       = ctrl_active[2];
    assign trans_pen15      = ctrl_active[3];

endmodule
