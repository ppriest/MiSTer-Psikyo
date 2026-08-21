// Checks sprite_pos_transform's offset correction and zoom transform
// against independently-computed reference values, swept over the actual
// domain sprite_record_decode ever produces: x_pos in [-128,383] (512
// values), y_pos in [-256,255] (512 values), nx/ny in [1,8], zoom_raw in
// [0,15]. (Not the full 10-bit signed range -- x_pos+offset can reach 541
// for out-of-domain x_pos near 511, which would overflow the 10-bit signed
// output and wrap; that's not a real bug, just outside what this module is
// ever actually fed, so it's not what's being tested here.)

module tb_sprite_pos_transform;

    logic signed [9:0] x_pos, y_pos;
    logic [3:0]         nx, ny;
    logic [3:0]         zoom_x_raw, zoom_y_raw;

    logic signed [9:0] x_adj, y_adj;
    logic [5:0]         zoom_x_transformed, zoom_y_transformed;

    sprite_pos_transform dut (.*);

    int errors;

    task automatic check_x(int xp, int n, int z);
        int exp_offset, exp_adj, exp_zoomt;
        x_pos      = xp[9:0];
        nx         = n[3:0];
        zoom_x_raw = z[3:0];
        #1;
        exp_offset = (n * z + 2) >> 2;
        exp_adj    = xp + exp_offset;
        exp_zoomt  = 32 - z;
        if (x_adj !== exp_adj[9:0] || zoom_x_transformed !== exp_zoomt[5:0]) begin
            errors++;
            if (errors <= 10)
                $display("FAIL(x) xp=%0d nx=%0d z=%0d got=(adj=%0d zoomt=%0d) expected=(adj=%0d zoomt=%0d)",
                          xp, n, z, x_adj, zoom_x_transformed, exp_adj, exp_zoomt);
        end
    endtask

    task automatic check_y(int yp, int n, int z);
        int exp_offset, exp_adj, exp_zoomt;
        y_pos      = yp[9:0];
        ny         = n[3:0];
        zoom_y_raw = z[3:0];
        #1;
        exp_offset = (n * z + 2) >> 2;
        exp_adj    = yp + exp_offset;
        exp_zoomt  = 32 - z;
        if (y_adj !== exp_adj[9:0] || zoom_y_transformed !== exp_zoomt[5:0]) begin
            errors++;
            if (errors <= 10)
                $display("FAIL(y) yp=%0d ny=%0d z=%0d got=(adj=%0d zoomt=%0d) expected=(adj=%0d zoomt=%0d)",
                          yp, n, z, y_adj, zoom_y_transformed, exp_adj, exp_zoomt);
        end
    endtask

    initial begin
        errors = 0;
        nx = 4'd1; ny = 4'd1; zoom_x_raw = 4'd0; zoom_y_raw = 4'd0; x_pos = 0; y_pos = 0;

        for (int xp = -128; xp <= 383; xp++)
            for (int n = 1; n <= 8; n++)
                for (int z = 0; z <= 15; z++)
                    check_x(xp, n, z);
        $display("X sweep done (512*8*16=65536 checks)");

        for (int yp = -256; yp <= 255; yp++)
            for (int n = 1; n <= 8; n++)
                for (int z = 0; z <= 15; z++)
                    check_y(yp, n, z);
        $display("Y sweep done (512*8*16=65536 checks)");

        if (errors == 0)
            $display("PASS: sprite_pos_transform matches reference for the full realistic input domain (131072 checks)");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
