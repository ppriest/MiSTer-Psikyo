// Hardware double-buffered sprite RAM (0x400000-0x401FFF,
// docs/phase1_memory_map.md "Sprite RAM layout"). MAME models this with
// buffered_spriteram32_device: the CPU freely reads/writes one buffer all
// frame, and the ENTIRE buffer is copied into a second, separate buffer on
// vblank's rising edge -- the sprite engine only ever renders from that
// frozen copy, never from the buffer the CPU is currently mid-write on.
//
// Implemented here as true ping-pong (2 physical banks, roles swapped each
// frame_start) rather than an actual bulk copy -- behaviorally identical to
// MAME's copy-based model as long as the CPU never touches the render-role
// bank, which holds here structurally (the CPU port is only ever wired to
// the write-role bank). Same pattern rtl/video/sprite_frame_buffer.sv
// already uses on the *output* side of the sprite pipeline; this is the
// equivalent on the input (attribute table + display list) side.
//
// Render-side needs 2 concurrent read streams into the SAME render bank
// (sprite_render_engine's dl_addr display-list walk and at_addr attribute
// fetch run concurrently, docs/phase1_video_engine.md "Sprite render
// engine: pipeline design") -- exactly rtl/memory/dpram.sv's 2-port shape
// (port A idle-or-CPU, port B always dl_addr), so only ONE dpram instance
// per bank is needed (unlike vreg_decode.sv, which genuinely needed 3
// simultaneous roles on one un-buffered bank).
//
// The control word (word 0xFFF, docs/phase1_memory_map.md "Control word")
// is deliberately NOT read back out through at_addr/dl_addr (the render
// engine's ports only ever address 0x000-0xFFE) -- it's tracked separately
// as a per-bank shadow register, latched into the active/rendering value
// at the same frame_start edge that swaps bank roles, so sprite_render_
// engine's trans_pen0/trans_pen15 see this frame's frozen value without
// needing a third RAM read port just for one word.
module spriteram_dbuf (
    input  logic clk,
    input  logic reset,

    input  logic frame_start,   // pulse: swap write/render bank roles (video_timing.sv's vblank-rising pulse)

    // CPU-facing port -- always addresses the current write-role bank.
    input  logic [11:0] cpu_addr,
    input  logic         cpu_wel,
    input  logic         cpu_weh,
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rdata,

    // Render-facing ports -- always address the current render-role bank.
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

    logic write_bank_sel; // 0: bank0 is write-role (bank1 render-role); 1: reversed

    logic bank0_is_write;
    assign bank0_is_write = ~write_bank_sel;

    logic [15:0] bank0_a_rdata, bank0_b_rdata;
    logic [15:0] bank1_a_rdata, bank1_b_rdata;

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_bank0 (
        .clk(clk),
        .a_addr(bank0_is_write ? cpu_addr : at_addr),
        .a_wel(bank0_is_write ? cpu_wel : 1'b0),
        .a_weh(bank0_is_write ? cpu_weh : 1'b0),
        .a_wdata(cpu_wdata),
        .a_rdata(bank0_a_rdata),
        .b_addr(dl_addr),
        .b_rdata(bank0_b_rdata)
    );

    dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_bank1 (
        .clk(clk),
        .a_addr(bank0_is_write ? at_addr : cpu_addr),
        .a_wel(bank0_is_write ? 1'b0 : cpu_wel),
        .a_weh(bank0_is_write ? 1'b0 : cpu_weh),
        .a_wdata(cpu_wdata),
        .a_rdata(bank1_a_rdata),
        .b_addr(dl_addr),
        .b_rdata(bank1_b_rdata)
    );

    assign cpu_rdata = bank0_is_write ? bank0_a_rdata : bank1_a_rdata;
    assign at_data   = bank0_is_write ? bank1_a_rdata : bank0_a_rdata;
    assign dl_data   = bank0_is_write ? bank1_b_rdata : bank0_b_rdata;

    // Per-bank shadow of the control word, updated whenever the CPU
    // writes word 0xFFF within whichever bank is currently the write-role
    // bank.
    logic [15:0] ctrl_shadow_bank0, ctrl_shadow_bank1;
    wire         cpu_we = cpu_wel | cpu_weh;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ctrl_shadow_bank0 <= 16'h0000;
            ctrl_shadow_bank1 <= 16'h0000;
        end else if (cpu_we && cpu_addr == CTRL_ADDR) begin
            if (bank0_is_write) ctrl_shadow_bank0 <= cpu_wdata;
            else                 ctrl_shadow_bank1 <= cpu_wdata;
        end
    end

    logic [15:0] ctrl_active;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            write_bank_sel <= 1'b0;
            // Sprites held disabled (bit 0) until the first real frame_start
            // latches genuine CPU-written content -- a safe power-on default.
            ctrl_active     <= 16'h0001;
        end else if (frame_start) begin
            // The bank that was just the write-role bank becomes this
            // frame's render-role bank; adopt its shadowed control word.
            ctrl_active     <= bank0_is_write ? ctrl_shadow_bank0 : ctrl_shadow_bank1;
            write_bank_sel  <= ~write_bank_sel;
        end
    end

    assign sprites_disable = ctrl_active[0];
    assign trans_pen0       = ctrl_active[2];
    assign trans_pen15      = ctrl_active[3];

endmodule
