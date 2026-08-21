// Exercises the real usage sequence: swap (clears the new render bank) ->
// write some sprite pixels into the render bank -> swap again (that data
// becomes the display bank, readable; the other bank gets cleared for next
// frame) -> read back written positions and confirm an unwritten position
// correctly reads present=0 -- which only holds if the earlier clear
// actually ran (uninitialized sim memory reads as X, not 0, so this would
// fail loudly rather than accidentally passing if the clear were broken).

module tb_sprite_frame_buffer;

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset;
    logic frame_swap, swap_busy, swap_done;
    logic         fb_we;
    logic [8:0]  fb_x;
    logic [7:0]  fb_y;
    logic [3:0]  fb_pixel;
    logic [4:0]  fb_color;
    logic [1:0]  fb_priority;
    logic [8:0]  rd_x;
    logic [7:0]  rd_y;
    logic         rd_present;
    logic [3:0]  rd_pixel;
    logic [4:0]  rd_color;
    logic [1:0]  rd_priority;

    sprite_frame_buffer dut (.*);

    int errors;

    task automatic do_swap;
        frame_swap = 1;
        @(posedge clk);
        frame_swap = 0;
        // clearing 71680 entries takes that many cycles; generous margin
        for (int i = 0; i < 72000; i++) begin
            @(posedge clk);
            if (swap_done) return;
        end
        errors++;
        $display("FAIL: swap_done never arrived");
    endtask

    task automatic write_pixel(int x, int y, int pixel, int color, int pri);
        fb_x = x[8:0]; fb_y = y[7:0]; fb_pixel = pixel[3:0]; fb_color = color[4:0]; fb_priority = pri[1:0];
        fb_we = 1;
        @(posedge clk);
        fb_we = 0;
    endtask

    task automatic check_read(string label, int x, int y, int exp_present, int exp_pixel, int exp_color, int exp_pri);
        rd_x = x[8:0]; rd_y = y[7:0];
        @(posedge clk); @(posedge clk);   // 1-cycle sync read + margin
        if (rd_present !== exp_present[0:0]) begin
            errors++;
            $display("FAIL(%s) (%0d,%0d) present: got=%b expected=%b", label, x, y, rd_present, exp_present);
            return;
        end
        if (exp_present && (rd_pixel !== exp_pixel[3:0] || rd_color !== exp_color[4:0] || rd_priority !== exp_pri[1:0])) begin
            errors++;
            $display("FAIL(%s) (%0d,%0d) got=(pix=%0d col=%0d pri=%0d) expected=(pix=%0d col=%0d pri=%0d)",
                      label, x, y, rd_pixel, rd_color, rd_priority, exp_pixel, exp_color, exp_pri);
        end
    endtask

    initial begin
        errors = 0;
        fb_we = 0;
        frame_swap = 0;
        rd_x = 0; rd_y = 0;

        reset = 1;
        @(posedge clk); @(posedge clk);
        reset = 0;
        @(posedge clk);

        // first swap: bank_sel 0->1, clears mem_b (the new render bank)
        do_swap();
        $display("first swap (clear) done");

        // write into the now-current render bank (mem_b)
        write_pixel(0,   0,   1, 3, 0);
        write_pixel(159, 111, 9, 20, 2);
        write_pixel(319, 223, 15, 31, 1);

        // second swap: bank_sel 1->0 -- mem_b (with our writes) becomes the
        // display bank; mem_a gets cleared for the next render pass
        do_swap();
        $display("second swap done");

        check_read("corner0",  0,   0,   1, 1, 3, 0);
        check_read("middle",   159, 111, 1, 9, 20, 2);
        check_read("corner1",  319, 223, 1, 15, 31, 1);
        check_read("unwritten",10,  10,  0, 0, 0, 0);
        check_read("unwritten2", 300, 5, 0, 0, 0, 0);

        if (errors == 0)
            $display("PASS: sprite_frame_buffer matches reference (swap/clear, write-then-readback, unwritten-reads-present0)");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
