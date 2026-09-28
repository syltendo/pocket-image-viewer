#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# The PLL output counters - update hierarchy for pll_imageviewer
# (ic = core_top instance name in apf_top)
#
# NOTE (2026-09-28): general[2] (99MHz controller clock, 0 deg) and general[3]
# (99MHz SDRAM chip clock, 180 deg = 5051ps) are intentionally NOT in async
# groups. They are frequency-locked with a known phase offset, and the SDRAM
# output-delay constraints at the bottom of this file need TimeQuest to
# analyze launch(general[2]) -> latch(general[3]) paths. (The old async groups
# silently nullified both the multicycle exceptions below and any
# output-delay constraints.)
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# False paths for async FIFO Gray-code synchronizers (2FF sync is safe by design)
# The synchronizer registers are in async_fifo instances; cut timing on them.
set_false_path -to [get_registers {*|async_fifo:*|rd_gray_w1[*]}]
set_false_path -to [get_registers {*|async_fifo:*|rd_gray_w2[*]}]
set_false_path -to [get_registers {*|async_fifo:*|wr_gray_r1[*]}]
set_false_path -to [get_registers {*|async_fifo:*|wr_gray_r2[*]}]

# False paths for reset and slot synchronizers (synch_3)
set_false_path -to [get_registers {*|s_mem_rst|*}]
set_false_path -to [get_registers {*|s_vid_rst|*}]
set_false_path -to [get_registers {*|s01|*}]
set_false_path -to [get_registers {*|s_sys_rst_mem|*}]

# Multicycle paths for SDRAM 180° phase shift (matches agg23's proven design)
# The SDRAM chip clock (outclk_3) is 180° shifted from the controller clock
# (outclk_2). This gives 2 cycles of setup margin for signals crossing
# between the controller and the SDRAM I/O pins.
# outclk_2 = general[2], 99MHz 0ps (controller)
# See: https://github.com/agg23/openfpga-SNES/blob/master/target/pocket/core_constraints.sdc
set_multicycle_path -from {*|mem_ctrl_inst|*} -to [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -start -setup 2
set_multicycle_path -from {*|mem_ctrl_inst|*} -to [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -start -hold 1
set_multicycle_path -from [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -to {*|mem_ctrl_inst|*} -setup 2
set_multicycle_path -from [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -to {*|mem_ctrl_inst|*} -hold 1

# ---------------------------------------------------------------------------
# MEASUREMENT ONLY (2026-09-28): SDRAM write-data output timing.
# Pocket SDRAM = Alliance AS4C32M16MSA-6BIN; datasheet AC characteristics:
#   Data In Setup Time to Clock (tCDS) = 2.0 ns
#   Data In Hold  Time to Clock (tCDH) = 1.0 ns
# The DQ/DQM output registers launch on general[2] (0 deg); the chip samples
# on general[3] (180 deg = 5051 ps later). These constraints make TimeQuest
# report the real setup slack = 5.051 - 2.0 - Tco. Negative slack proves the
# write path cannot meet timing; positive slack refutes it.
# (Hold needs no constraint: data changes one full 10.1ns period later.)
# ---------------------------------------------------------------------------
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_dq[*]}]
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_dqm[*]}]
