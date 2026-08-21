// Checks tilemap_coord against an independently-computed expected result
// (using actual %, not the RTL's masking trick) across a spread of
// effective-position values per mode: 0..4095 (covers at least one full
// wrap for every mode's smaller dimension) plus explicit boundary/max-value
// spot checks near 65535.

module tb_tilemap_coord;

    logic [1:0]  mode;
    logic [15:0] eff_x, eff_y;
    logic [7:0]  tile_col;
    logic [6:0]  tile_row;
    logic [3:0]  fine_x, fine_y;

    tilemap_coord dut (
        .mode(mode), .eff_x(eff_x), .eff_y(eff_y),
        .tile_col(tile_col), .tile_row(tile_row),
        .fine_x(fine_x), .fine_y(fine_y)
    );

    int width, height;
    int mx, my;
    int exp_col, exp_row, exp_fx, exp_fy;
    int errors;

    task automatic check(int x, int y);
        eff_x = x[15:0];
        eff_y = y[15:0];
        #1;
        mx = x % width;
        my = y % height;
        exp_col = mx >> 4;
        exp_row = my >> 4;
        exp_fx  = mx & 4'hF;
        exp_fy  = my & 4'hF;
        if (tile_col !== exp_col[7:0] || tile_row !== exp_row[6:0] ||
            fine_x !== exp_fx[3:0] || fine_y !== exp_fy[3:0]) begin
            errors++;
            if (errors <= 10)
                $display("FAIL mode=%0d x=%0d y=%0d got=(col=%0d row=%0d fx=%0d fy=%0d) expected=(col=%0d row=%0d fx=%0d fy=%0d)",
                          mode, x, y, tile_col, tile_row, fine_x, fine_y, exp_col, exp_row, exp_fx, exp_fy);
        end
    endtask

    initial begin
        errors = 0;

        for (int m = 0; m < 4; m++) begin
            mode = m[1:0];
            case (m)
                0: begin width = 1024; height = 1024; end
                1: begin width = 2048; height = 512;  end
                2: begin width = 4096; height = 256;  end
                3: begin width = 512;  height = 2048; end
            endcase

            // spread sweep: covers >=1 full wrap of the smaller dimension
            for (int x = 0; x < 4096; x += 7)
                for (int y = 0; y < 4096; y += 11)
                    check(x, y);

            // boundary + max-value spot checks
            check(0, 0);
            check(width - 1, height - 1);
            check(width, height);
            check(width + 1, height + 1);
            check(2 * width + 3, 2 * height + 5);
            check(65535, 65535);
            check(65535 - width, 65535 - height);

            $display("mode %0d done", m);
        end

        if (errors == 0)
            $display("PASS: tilemap_coord matches independent modulo computation for all 4 modes");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
