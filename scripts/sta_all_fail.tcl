# Run from the stage: quartus_sta -t ../scripts/sta_all_fail.tcl [rev]
set rev "Psikyo"
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
project_open $rev
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist
set ck {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
report_timing -setup -npaths 600 -detail summary -from_clock $ck -to_clock $ck -file sta_all_fail.rpt
project_close
