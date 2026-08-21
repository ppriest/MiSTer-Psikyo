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
    output logic [7:0]  dl_data,
    input  logic         dl_busy
);

    typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT} dstate_t;
    dstate_t dstate;

    logic [24:0] addr_r;
    logic [7:0]  data_r;

    assign dl_addr = addr_r;
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
