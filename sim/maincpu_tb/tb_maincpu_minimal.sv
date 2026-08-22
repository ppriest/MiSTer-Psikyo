// Minimal reset-only repro for maincpu.sv, built to isolate the crash
// tb_maincpu.sv hit (ModelSim SIGSEGV + cascading memory-allocation
// failures within the first ~5 clock cycles, still inside reset) --
// deliberately as small as possible: a handful of NOP fetches, no RAM
// region traffic, no stack usage, no interrupt. If this ALSO crashes, the
// bug is in the basic TG68K instantiation/reset wiring (most likely
// RESET/HALT, simplified from the real `inout` port's resolved-signal
// semantics the sim/tg68k_spike testbench modeled more carefully -- see
// maincpu.sv's header). If this does NOT crash, the bug is specific to
// something exercised only once real bus/RAM/stack/IRQ activity happens,
// and complexity gets added back incrementally from here rather than
// guessed at in the full testbench.

module tb_maincpu_minimal;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;

    logic         rom_req;
    logic [18:0] rom_addr;
    logic         rom_valid;
    logic [15:0] rom_data;

    logic [11:0] spriteram_addr;
    logic         spriteram_wel, spriteram_weh;
    logic [15:0] spriteram_wdata;
    logic [15:0] spriteram_rdata = 16'h0000;

    logic [11:0] palette_addr;
    logic         palette_wel, palette_weh;
    logic [15:0] palette_wdata;
    logic [15:0] palette_rdata = 16'h0000;

    logic [11:0] vram0_addr;
    logic         vram0_wel, vram0_weh;
    logic [15:0] vram0_wdata;
    logic [15:0] vram0_rdata = 16'h0000;

    logic [11:0] vram1_addr;
    logic         vram1_wel, vram1_weh;
    logic [15:0] vram1_wdata;
    logic [15:0] vram1_rdata = 16'h0000;

    logic [12:0] vregs_addr;
    logic         vregs_wel, vregs_weh;
    logic [15:0] vregs_wdata;
    logic [15:0] vregs_rdata = 16'h0000;

    logic [15:0] workram_addr;
    logic         workram_wel, workram_weh;
    logic [15:0] workram_wdata;
    logic [15:0] workram_rdata = 16'h0000;

    logic [31:0] p1p2_in = 32'h0;
    logic [31:0] dsw_in  = 32'h0;
    logic [31:0] coin_in = 32'h0;
    logic [7:0]  latch_data;
    logic         latch_write;
    logic         vblank = 1'b0;

    maincpu #(.BOARD_GUNBIRD(1'b0)) dut (.*);

    // Trivial ROM model: immediate-valid (1-cycle), no req/valid latency
    // games -- minimizes variables while isolating the reset/boot crash.
    // NOP (opcode 0x4E71) at every address, so the CPU just free-runs
    // fetching NOPs forever once booted -- no branches, no memory access
    // beyond straight-line opcode fetch, deliberately trivial.
    logic rom_req_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rom_valid <= 1'b0;
            rom_req_d <= 1'b0;
        end else begin
            rom_req_d <= rom_req;
            rom_valid <= rom_req;
            rom_data  <= 16'h4E71;   // NOP
        end
    end

    initial begin
        #200000;
        $display("Ran 200000ps (=20000 cycles) with no crash -- minimal repro is clean");
        $finish;
    end

    initial begin
        reset = 1;
        repeat (15) @(posedge clk);
        reset = 0;
    end

endmodule
