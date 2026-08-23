# Report the worst setup-failing paths on the main core clock domain.
# Run: quartus_sta -t sta_failing_paths.tcl
# (uses the existing post-fit netlist -- no re-fit, no placement change)
# cd inside the script: the shell cwd is not reliably the project dir when
# this is launched as a background command.
cd D:/Mister-Psikyo
project_open Psikyo -revision Psikyo
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist

set ck {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

# 1) Summary of the 50 worst failing endpoints -- shows WHERE the failures cluster
report_timing -setup -npaths 50 -detail summary \
    -from_clock $ck -to_clock $ck \
    -file sta_top50_summary.rpt

# 2) Full detail on the 5 worst paths -- shows the actual cell-by-cell critical path
report_timing -setup -npaths 5 -detail full_path \
    -from_clock $ck -to_clock $ck \
    -file sta_worst5_full.rpt

project_close
