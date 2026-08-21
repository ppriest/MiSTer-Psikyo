// Checks sprite_subtile_step against an independently-computed reference.
//
// This module has two kinds of input dimension and they're tested with
// different strategies rather than one flat Cartesian product:
//   - "logic" dimensions (nx, ix, flip_x, zoom_x_transformed and the Y
//     equivalents) select/reverse the grid index and pick the multiplier --
//     this is where an off-by-one or a flip-direction mistake would hide,
//     so these are swept EXHAUSTIVELY (all (nx,ix) pairs x2 flip x16 zoom).
//   - "linear-add" dimensions (x_adj/y_adj, code_base) just get added to an
//     already-checked term -- low bug risk per distinct value, so these are
//     covered by boundary values + a spread of samples rather than their
//     full realistic range, which would blow the Cartesian product up by
//     >500x for no real additional coverage.
// X and Y are checked independently (Y inputs held at a fixed benign value
// while sweeping X, and vice versa), matching how sprite_pos_transform's
// testbench separates the two axes -- this module computes them via
// identical, non-interacting logic.

module tb_sprite_subtile_step;

    logic [3:0]        ix, iy;
    logic [3:0]        nx, ny;
    logic               flip_x, flip_y;
    logic signed [9:0] x_adj, y_adj;
    logic [5:0]        zoom_x_transformed, zoom_y_transformed;
    logic [5:0]        subtile_ordinal;
    logic [16:0]       code_base;

    logic signed [9:0] sub_x, sub_y;
    logic [16:0]       sub_code;

    sprite_subtile_step dut (.*);

    int errors;

    task automatic check_x(int xa, int n, int i, int fx, int zx);
        int dxg, exp_x;
        nx = n[3:0]; ix = i[3:0]; flip_x = fx[0];
        x_adj = xa[9:0]; zoom_x_transformed = zx[5:0];
        #1;
        dxg    = fx ? (n - 1 - i) : i;
        exp_x  = xa + (dxg * zx) / 2;
        if (sub_x !== exp_x[9:0]) begin
            errors++;
            if (errors <= 10)
                $display("FAIL(x) xa=%0d n=%0d i=%0d fx=%0d zx=%0d got=%0d expected=%0d",
                          xa, n, i, fx, zx, sub_x, exp_x);
        end
    endtask

    task automatic check_y(int ya, int n, int i, int fy, int zy);
        int dyg, exp_y;
        ny = n[3:0]; iy = i[3:0]; flip_y = fy[0];
        y_adj = ya[9:0]; zoom_y_transformed = zy[5:0];
        #1;
        dyg    = fy ? (n - 1 - i) : i;
        exp_y  = ya + (dyg * zy) / 2;
        if (sub_y !== exp_y[9:0]) begin
            errors++;
            if (errors <= 10)
                $display("FAIL(y) ya=%0d n=%0d i=%0d fy=%0d zy=%0d got=%0d expected=%0d",
                          ya, n, i, fy, zy, sub_y, exp_y);
        end
    endtask

    task automatic check_code(int cb, int ord);
        int exp_code;
        code_base = cb[16:0];
        subtile_ordinal = ord[5:0];
        #1;
        exp_code = cb + ord;
        if (sub_code !== (exp_code & 17'h1FFFF)) begin
            errors++;
            if (errors <= 10)
                $display("FAIL(code) cb=%h ord=%0d got=%h expected=%h",
                          cb, ord, sub_code, exp_code & 17'h1FFFF);
        end
    endtask

    int x_samples[8]  = '{-128, -64, -1, 0, 1, 200, 412, 413};
    int y_samples[8]  = '{-256, -128, -1, 0, 1, 200, 366, 367};
    int cb_samples[8] = '{0, 1, 63, 65472, 131007, 131070, 131071, 12345};

    initial begin
        errors = 0;
        // benign defaults for the axis not currently under test
        ny = 4'd1; iy = 4'd0; flip_y = 1'b0; y_adj = 10'd0; zoom_y_transformed = 6'd32;
        nx = 4'd1; ix = 4'd0; flip_x = 1'b0; x_adj = 10'd0; zoom_x_transformed = 6'd32;
        code_base = 17'd0; subtile_ordinal = 6'd0;

        foreach (x_samples[k])
            for (int n = 1; n <= 8; n++)
                for (int i = 0; i < n; i++)
                    for (int fx = 0; fx <= 1; fx++)
                        for (int zx = 17; zx <= 32; zx++)
                            check_x(x_samples[k], n, i, fx, zx);
        $display("X sweep done (8 samples * 36 (nx,ix) pairs * 2 flip * 16 zoom = 9216 checks)");

        foreach (y_samples[k])
            for (int n = 1; n <= 8; n++)
                for (int i = 0; i < n; i++)
                    for (int fy = 0; fy <= 1; fy++)
                        for (int zy = 17; zy <= 32; zy++)
                            check_y(y_samples[k], n, i, fy, zy);
        $display("Y sweep done (8 samples * 36 (ny,iy) pairs * 2 flip * 16 zoom = 9216 checks)");

        foreach (cb_samples[k])
            for (int ord = 0; ord < 64; ord++)
                check_code(cb_samples[k], ord);
        $display("code sweep done (8 samples * 64 ordinals = 512 checks)");

        if (errors == 0)
            $display("PASS: sprite_subtile_step matches reference (18944 checks total)");
        else
            $display("FAIL: %0d mismatches", errors);

        $finish;
    end

endmodule
