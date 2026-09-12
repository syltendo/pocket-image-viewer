#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# The PLL output counters - update hierarchy for pll_imageviewer
# (ic = core_top instance name in apf_top)
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk }

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
