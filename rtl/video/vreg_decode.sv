// Video-register decode for the "RAM + Vregs" region (0x804000-0x807FFF,
// docs/phase1_memory_map.md "Video registers"). This region is genuine
// general-purpose scratch RAM the CPU can read/write anywhere across its
// full 8192-word span, but a handful of fixed word offsets are also read
// live, every line/frame, by the tilemap engines: the two layers' row-
// scroll tables (word 0x000-0x0FF layer 0, 0x100-0x1FF layer 1) and six
// single-value control registers (Y-scroll/X-scroll-base/control-word per
// layer).
//
// Backing storage is duplicated into two independent dpram copies (both
// always written identically from the CPU port) purely to get a second,
// independent BRAM read port per layer for the row-scroll table -- a
// standard FPGA pattern for giving one write-side dataset more read ports
// than a single true-dual-port BRAM primitive offers. The six single-value
// control registers are NOT read out of the dpram at all: they're latched
// into plain flip-flops on a matching CPU write, avoiding a third
// (unavailable) BRAM read port and giving the tilemap engines single-cycle,
// always-current combinational access instead of a synchronous BRAM read.
module vreg_decode (
    input  logic         clk,
    input  logic         reset,

    // CPU-facing port -- same shape as maincpu.sv's other BRAM regions.
    input  logic [12:0] cpu_addr,
    input  logic         cpu_wel,
    input  logic         cpu_weh,
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rdata,

    // Row-scroll table read ports, one per layer -- module-local index
    // 0-255 within that layer's table, matching tilemap_line_engine's
    // rowscroll_addr/rowscroll_data port shape.
    input  logic [7:0]  layer0_rowscroll_addr,
    output logic [15:0] layer0_rowscroll_data,
    input  logic [7:0]  layer1_rowscroll_addr,
    output logic [15:0] layer1_rowscroll_data,

    // Decoded per-layer control outputs, matching tilemap_line_engine's
    // mode/base_x_scroll/base_y_scroll/bank/rowscroll_enable/
    // rowscroll_pertile input port shape directly.
    output logic [1:0]  layer0_mode,
    output logic [15:0] layer0_base_x_scroll,
    output logic [15:0] layer0_base_y_scroll,
    output logic [1:0]  layer0_bank,
    output logic         layer0_enable,
    output logic         layer0_rowscroll_enable,
    output logic         layer0_rowscroll_pertile,

    output logic [1:0]  layer1_mode,
    output logic [15:0] layer1_base_x_scroll,
    output logic [15:0] layer1_base_y_scroll,
    output logic [1:0]  layer1_bank,
    output logic         layer1_enable,
    output logic         layer1_rowscroll_enable,
    output logic         layer1_rowscroll_pertile
);

    // Fixed word offsets, from docs/phase1_memory_map.md's "Video
    // registers" table (byte offset >> 1).
    localparam logic [12:0] ADDR_L0_YSCROLL = 13'h201; // byte 0x402
    localparam logic [12:0] ADDR_L0_XSCROLL = 13'h203; // byte 0x406
    localparam logic [12:0] ADDR_L1_YSCROLL = 13'h205; // byte 0x40A
    localparam logic [12:0] ADDR_L1_XSCROLL = 13'h207; // byte 0x40E
    localparam logic [12:0] ADDR_L0_CTRL     = 13'h209; // byte 0x412
    localparam logic [12:0] ADDR_L1_CTRL     = 13'h20B; // byte 0x416

    logic [15:0] l0_ctrl, l1_ctrl;

    wire cpu_we = cpu_wel | cpu_weh;
    // Both byte lanes of these registers are always written together by
    // real code (word-sized scroll/control values) -- a lone byte write
    // still updates the whole register from cpu_wdata, matching how a real
    // 16-bit register would latch whichever lanes are enabled; scoped
    // this way (not per-lane) since nothing in this project's memory map
    // ever byte-writes these six fields individually.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            layer0_base_y_scroll <= 16'h0000;
            layer0_base_x_scroll <= 16'h0000;
            layer1_base_y_scroll <= 16'h0000;
            layer1_base_x_scroll <= 16'h0000;
            l0_ctrl               <= 16'h0000;
            l1_ctrl               <= 16'h0000;
        end else if (cpu_we) begin
            unique case (cpu_addr)
                ADDR_L0_YSCROLL: layer0_base_y_scroll <= cpu_wdata;
                ADDR_L0_XSCROLL: layer0_base_x_scroll <= cpu_wdata;
                ADDR_L1_YSCROLL: layer1_base_y_scroll <= cpu_wdata;
                ADDR_L1_XSCROLL: layer1_base_x_scroll <= cpu_wdata;
                ADDR_L0_CTRL:     l0_ctrl               <= cpu_wdata;
                ADDR_L1_CTRL:     l1_ctrl               <= cpu_wdata;
                default: ;
            endcase
        end
    end

    // Layer control word bits, docs/phase1_memory_map.md's "Layer control
    // word bits" table.
    assign layer0_enable            = l0_ctrl[0];
    assign layer0_mode              = l0_ctrl[7:6];
    assign layer0_rowscroll_enable  = l0_ctrl[8];
    assign layer0_rowscroll_pertile = l0_ctrl[9];
    assign layer0_bank              = 2'd0; // live bank select (ctrl bit 10) is board-specific (m_ka302c_banking) -- not yet wired, fixed banks applied by the caller for now

    assign layer1_enable            = l1_ctrl[0];
    assign layer1_mode              = l1_ctrl[7:6];
    assign layer1_rowscroll_enable  = l1_ctrl[8];
    assign layer1_rowscroll_pertile = l1_ctrl[9];
    assign layer1_bank              = 2'd0; // see layer0_bank note

    dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_ram_l0 (
        .clk(clk),
        .a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
        .b_addr({5'b0, layer0_rowscroll_addr}), .b_rdata(layer0_rowscroll_data)
    );

    logic [15:0] cpu_rdata_l1; // unused -- l1's copy only needed for its own read port
    dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_ram_l1 (
        .clk(clk),
        .a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata_l1),
        .b_addr({4'b0, 1'b1, layer1_rowscroll_addr}), .b_rdata(layer1_rowscroll_data)
    );

endmodule
