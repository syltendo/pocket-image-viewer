## report_worst_paths.tcl
##
## Dumps the actual worst setup-timing paths for the clk_mem domain
## (general[2], the SDRAM controller / parser / scanout clock) to a plain
## text file so CI captures them as a build artifact.
##
## Why: the standard quartus_sh --flow compile run only emits summary
## tables in ap_core.sta.rpt (worst slack + TNS per clock), and the
## "Timing Closure Recommendations" panel that would normally name the
## actual critical path is explicitly omitted from the plain-text .rpt
## ("HTML report is unavailable in plain text report export"). Without
## the named path, root-causing a large negative slack means guessing.
##
## Run standalone after a compile: quartus_sta -t report_worst_paths.tcl ap_core

load_package report
project_open ap_core

create_timing_netlist
read_sdc
update_timing_netlist

set mem_clk {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}

set outdir "output_files"
file mkdir $outdir

# Worst 40 setup paths on the clk_mem domain, full path detail (every node
# and its incremental delay) so the slow stage is visible directly, not
# just start/end points.
report_timing -setup -npaths 40 -detail full_path -multi_corner \
    -to_clock $mem_clk -from_clock $mem_clk \
    -panel_name {Worst Setup Paths (clk_mem)} \
    -file "$outdir/worst_setup_paths.rpt"

# Same, but hold paths, in case that's ever relevant.
report_timing -hold -npaths 20 -detail full_path -multi_corner \
    -to_clock $mem_clk -from_clock $mem_clk \
    -panel_name {Worst Hold Paths (clk_mem)} \
    -file "$outdir/worst_hold_paths.rpt"

project_close
