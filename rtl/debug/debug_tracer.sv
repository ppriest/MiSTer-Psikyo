// Reusable on-hardware trace buffer for bring-up, read out through the video
// output and controlled live from the OSD.
//
// WHY THIS EXISTS
// ---------------
// With no JTAG available, hardware visibility on this project has come from
// driving internal state onto VGA_R/G/B and decoding the screenshot
// (scripts/decode_debug_screenshot.py). Doing that ad-hoc cost a ~12-minute
// build/deploy/decode cycle every time the probe changed, and -- worse -- two
// of six such rounds on 2026-08-23 produced CONFIDENTLY WRONG findings. Both
// failures are designed out here:
//
//   1. "Counters read zero" twice, because they were cleared by the very
//      reset being investigated (MiSTer holds core RESET for the whole ROM
//      download). THIS MODULE HAS NO RESET PORT. Registers power up to zero
//      at configuration and are only ever re-armed deliberately. Do not add
//      a reset to it.
//   2. A combinational signal sampled at the wrong edge appeared to show the
//      CPU latching corrupt data. The caller supplies an explicit one-cycle
//      `cap_stb`, so the capture point is a deliberate decision -- and it
//      must be proven in simulation against a known-good run before its
//      hardware output is trusted.
//
// See docs/LESSONS_LEARNED.md, "Debug instrumentation: how to not fool
// yourself".
//
// USAGE
// -----
// Capture: pulse `cap_stb` for one clk cycle per event, with `cap_data` valid
// that cycle. Recording stops when the buffer is full and holds its contents,
// so the readout is static and a screenshot can be taken at any time.
//
// Readout: `rd_index` is normally the video line counter, giving one captured
// entry per scanline -- DEPTH consecutive events in a single screenshot.
// `rd_data` is registered (a real BRAM read port), so it lags one cycle;
// irrelevant at line rate.
//
// Window: `ctl_window` skips ctl_window*DEPTH events before recording, so the
// capture window can be walked across a long boot sequence FROM THE OSD with
// no rebuild. That is the main reason this module is worth having.
//
// Re-arm: any CHANGE on `ctl_rearm` (level, driven from an OSD bit) restarts
// capture with the current window. Toggling that bit re-triggers without
// resetting the core, so the CPU's state is not disturbed.
//
// The module captures from configuration onward without needing a re-arm, so
// the power-on boot sequence is caught by default.

module debug_tracer #(
    parameter int DEPTH = 256,   // entries; also the events-per-window step
    parameter int WIDTH = 24     // bits per entry (24 = one RGB pixel)
) (
    input  logic              clk,

    // ---- capture side ----
    input  logic              cap_stb,    // ONE cycle per event
    input  logic [WIDTH-1:0]  cap_data,

    // ---- live control (OSD status bits; deliberately NOT reset-coupled) ----
    input  logic              ctl_rearm,  // any change restarts capture
    input  logic [3:0]        ctl_window, // skip ctl_window*DEPTH events first

    // ---- readout ----
    input  logic [8:0]        rd_index,
    output logic [WIDTH-1:0]  rd_data
);

    localparam int AW = $clog2(DEPTH);

    (* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

    // NOTE the initialisers and the deliberate absence of any reset -- see
    // the header. Quartus powers these to 0 at configuration.
    logic [AW:0]  wptr      = '0;   // extra MSB is the "full" flag
    logic [19:0]  skip_cnt  = '0;
    logic         rearm_d   = 1'b0;

    wire full        = wptr[AW];
    wire [19:0] skip_target = {8'd0, ctl_window, 8'd0};   // ctl_window * 256

    always_ff @(posedge clk) begin
        rearm_d <= ctl_rearm;

        if (ctl_rearm != rearm_d) begin
            // deliberate re-arm from the OSD -- restart with the current window
            wptr     <= '0;
            skip_cnt <= '0;
        end else if (cap_stb && !full) begin
            if (skip_cnt < skip_target) begin
                skip_cnt <= skip_cnt + 20'd1;
            end else begin
                mem[wptr[AW-1:0]] <= cap_data;
                wptr              <= wptr + 1'b1;
            end
        end
    end

    // Registered read -- infers a proper BRAM port rather than a huge mux.
    always_ff @(posedge clk) begin
        rd_data <= mem[rd_index[AW-1:0]];
    end

endmodule
