// pll_imageviewer.v
//
// Clock PLL for the Pocket image viewer core.
// Reference: clk_74a = 74.25 MHz from the APF framework.
//
// Outputs (VCO = 792 MHz, integer-N):
//   outclk_0 :  39.6 MHz,   0 ps  - video pixel clock (800x720@60)
//   outclk_1 :  39.6 MHz, 6313 ps - video pixel clock, 90 deg (scaler capture)
//   outclk_2 :  99.0 MHz,   0 ps  - SDRAM controller clock
//   outclk_3 :  99.0 MHz, 9540 ps - SDRAM chip clock (dram_clk), 340 deg
//
// The 340-degree shift on dram_clk delays the SDRAM's sampling point by
// ~9.6ns. Writes then meet setup comfortably (~8ns). Reads: the SDRAM
// launches data 3 dram_clk cycles after sampling the READ, so the first
// word is valid at the FPGA ~41-52ns after the controller issues the READ;
// the controller samples it 5 controller clocks (50.5ns) after issue.
// See docs/architecture.md for the full timing derivation.
// NOTE: this phase was derived by hand calculation, not TimeQuest or
// hardware measurement. If images show noise/tearing, it is the first
// thing to tune.

`timescale 1 ps / 1 ps
module pll_imageviewer (
    input  wire refclk,     // 74.25 MHz
    input  wire rst,
    output wire outclk_0,   // 39.6 MHz video
    output wire outclk_1,   // 39.6 MHz video, 90 deg
    output wire outclk_2,   // 99 MHz SDRAM controller
    output wire outclk_3,   // 99 MHz SDRAM chip clock, 340 deg
    output wire locked
);

    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(4),
        .output_clock_frequency0("39.6 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("39.6 MHz"),
        .phase_shift1("6313 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("99.0 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("99.0 MHz"),
        .phase_shift3("9540 ps"),
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
