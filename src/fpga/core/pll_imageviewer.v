// pll_imageviewer.v
//
// Clock PLL for the Pocket image viewer core.
// Reference: clk_74a = 74.25 MHz from the APF framework.
//
// Outputs (VCO = 792 MHz, fractional-N):
//   outclk_0 :  39.6 MHz,   0 ps  - video pixel clock (800x720@60)
//   outclk_1 :  39.6 MHz, 6313 ps - video pixel clock, 90 deg (scaler capture)
//   outclk_2 :  49.5 MHz,   0 ps  - SDRAM controller clock
//   outclk_3 :  49.5 MHz, 10101 ps - SDRAM chip clock (dram_clk), 180 deg
//
// NOTE: 49.5 MHz (not 99 MHz): the 99MHz SDRAM output timing could not close
// (Tco 8.5ns vs 3.05ns budget). At 49.5MHz the budget is 8.1ns. Bandwidth
// 49.5*16/8=99MB/s still exceeds the 69MB/s needed for 800x720.
// VCO=792 gives integer dividers: 792/20=39.6 (video), 792/16=49.5.
// 100 MHz has no common VCO with 39.6 MHz in the valid range.
//
// 180-degree shift matches agg23's proven SDRAM controller, which generates
// the SDRAM clock via DDR output (inherently 180 deg from controller clock).
// See agg23/openfpga-wonderswan sdram.sv lines 385-391.
// hardware. If images show noise/tearing, it is the first thing to tune.

`timescale 1 ps / 1 ps
module pll_imageviewer (
    input  wire refclk,     // 74.25 MHz
    input  wire rst,
    output wire outclk_0,   // 39.6 MHz video
    output wire outclk_1,   // 39.6 MHz video, 90 deg
    output wire outclk_2,   // 49.5 MHz SDRAM controller
    output wire outclk_3,   // 49.5 MHz SDRAM chip clock, 180 deg
    output wire locked
);

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(4),
        .output_clock_frequency0("39.6 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("39.6 MHz"),
        .phase_shift1("6313 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("49.5 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("49.5 MHz"),
        .phase_shift3("10101 ps"),
        .duty_cycle3(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst     (rst),
        .outclk  ({outclk_3, outclk_2, outclk_1, outclk_0}),
        .locked  (locked),
        .fboutclk(),
        .fbclk   (1'b0),
        .refclk  (refclk)
    );

endmodule
