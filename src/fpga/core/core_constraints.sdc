#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# The PLL output counters - update hierarchy for pll_imageviewer
# (ic = core_top instance name in apf_top)
#
# NOTE (2026-09-28, revised): general[2] (99MHz controller clock, 0 deg) and
# general[3] (99MHz SDRAM chip clock, 180 deg = 5051ps) are frequency-locked
# with a known phase offset, so they share ONE group: TimeQuest analyzes
# launch(general[2]) -> latch(general[3]) paths, which is what the SDRAM
# output-delay constraints at the bottom of this file need. Both are cut from
# every other clock (the video/bridge clocks), whose crossings already have
# dedicated false-path synchronizer constraints below. (Putting general[2]
# and general[3] in no group at all was tried and wrongly exposed unrelated
# cross-domain paths, e.g. general[2] <-> clk_74a.)
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk }

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
# outclk_2 = general[2], 99MHz 0ps (controller / parser / scanout mem IF)
# Multicycle: ALL intra-99MHz register->register paths get 2 cycles for setup
# (1 for hold). The 99MHz domain (SDRAM controller, BMP parser, video scanout
# memory interface, FIFOs) does not close at single-cycle; 2 cycles is safe
# because SDRAM protocol timing is counted in clock cycles, not ns.
# NOTE: must use get_clocks; bare string patterns do not match reliably.
set_multicycle_path -setup 2 -from [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold 1 -from [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_clocks {ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

# ---------------------------------------------------------------------------
# MEASUREMENT (2026-09-28): SDRAM output timing.
# Pocket SDRAM = Alliance AS4C32M16MSA-6BIN; datasheet AC characteristics:
#   Data In Setup Time to Clock (tCDS) = 2.0 ns
#   Data In Hold  Time to Clock (tCDH) = 1.0 ns
#   Command/Address Setup (tCMS)       = 2.0 ns
# The controller launches every SDRAM output on general[2] (0 deg); the chip
# samples on general[3] (180 deg = 5051 ps later). Verified against the
# controller RTL (sdram_ctrl.v): the WRITE command is launched one cycle
# before the first data word, so each word is sampled half a cycle after its
# launch. These constraints make TimeQuest report the real setup slack =
# 5.051 - 2.0 - Tco. Negative slack proves that output cannot meet timing;
# positive slack refutes it.
# (Hold needs no constraint: data changes one full 10.1ns period later.)
# ---------------------------------------------------------------------------
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_dq[*]}]
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_dqm[*]}]
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_a[*]}]
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_ba[*]}]
set_output_delay -clock [get_clocks {ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] -max 2.0 [get_ports {dram_ras_n dram_cas_n dram_we_n dram_cke}]
