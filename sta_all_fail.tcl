cd D:/Mister-Psikyo
project_open Psikyo -revision Psikyo
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist
set ck {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
report_timing -setup -npaths 600 -detail summary -from_clock $ck -to_clock $ck -file sta_all_fail.rpt
project_close
