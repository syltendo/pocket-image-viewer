// Behavioral SDRAM model for testing sdram_ctrl.
// 16-bit data, BL8, CL3. Simplified: no refresh needed, instant commands.
`default_nettype none
`timescale 1ns/1ps

module sdram_model (
    input  wire        clk,      // SDRAM chip clock (dram_clk)
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        cke,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n
);
    // 64Mbit = 4M x 16. Model as bank/row/col.
    reg [15:0] mem [0:4194303];
    reg [12:0] open_row [0:3];
    reg [3:0]  open_valid;

    reg [1:0]  cmd_ba;
    reg [12:0] cmd_a;
    reg        cmd_ras_n, cmd_cas_n, cmd_we_n;

    // read pipeline: CL=3
    reg [15:0] rd_pipe [0:2];
    reg [1:0]  rd_ba_pipe [0:2];
    reg [9:0]  rd_col_pipe [0:2];
    reg        rd_valid_pipe [0:2];
    reg [2:0]  rd_burst_cnt;
    reg        rd_active;
    reg [1:0]  rd_ba;
    reg [9:0]  rd_col;

    // write burst
    reg [2:0]  wr_burst_cnt;
    reg        wr_active;
    reg [1:0]  wr_ba;
    reg [12:0] wr_row;
    reg [9:0]  wr_col;

    reg [15:0] dq_out;
    reg        dq_oe;

    assign dq = dq_oe ? dq_out : 16'hzzzz;

    integer i;
    initial begin
        for (i = 0; i < 4194304; i = i + 1) mem[i] = 16'h0000;
        open_valid = 0;
        rd_active = 0; wr_active = 0; dq_oe = 0;
        for (i = 0; i < 3; i = i + 1) rd_valid_pipe[i] = 0;
    end

    function [21:0] addr;
        input [1:0] b; input [12:0] r; input [9:0] c;
        addr = {b, r, c};
    endfunction

    always @(posedge clk) begin
        cmd_ras_n <= ras_n; cmd_cas_n <= cas_n; cmd_we_n <= we_n;
        cmd_ba <= ba; cmd_a <= a;

        // default: stop driving after burst
        if (rd_active) begin
            if (rd_burst_cnt == 0) begin
                rd_active <= 0; dq_oe <= 0;
            end else begin
                rd_burst_cnt <= rd_burst_cnt - 1;
                dq_out <= mem[addr(rd_ba, open_row[rd_ba], rd_col)];
                rd_col <= rd_col + 1;
            end
        end

        if (wr_active) begin
            // capture write data (DQM masked)
            if (!dqm[0]) mem[addr(wr_ba, wr_row, wr_col)][7:0]   <= dq[7:0];
            if (!dqm[1]) mem[addr(wr_ba, wr_row, wr_col)][15:8]  <= dq[15:8];
            wr_col <= wr_col + 1;
            if (wr_burst_cnt == 0) wr_active <= 0;
            else wr_burst_cnt <= wr_burst_cnt - 1;
        end

        // decode command (from previous cycle's pins)
        if (!cmd_ras_n && cmd_cas_n && !cmd_we_n) begin
            // PRECHARGE (A10 = all)
            if (cmd_a[10]) open_valid <= 0;
        end else if (!cmd_ras_n && cmd_cas_n && cmd_we_n) begin
            // ACTIVATE
            open_row[cmd_ba] <= cmd_a;
            open_valid[cmd_ba] <= 1;
        end else if (cmd_ras_n && !cmd_cas_n && cmd_we_n) begin
            // READ: start burst after CL=3 (simplified: start now, model delays)
            rd_ba <= cmd_ba;
            rd_col <= cmd_a[9:0];
            rd_burst_cnt <= 7;
            rd_active <= 1;
            dq_oe <= 1;
            // Note: real CL=3 delay not modeled; testbench accounts for it
        end else if (cmd_ras_n && !cmd_cas_n && !cmd_we_n) begin
            // WRITE
            wr_ba <= cmd_ba;
            wr_row <= open_row[cmd_ba];
            wr_col <= cmd_a[9:0];
            wr_burst_cnt <= 7;
            wr_active <= 1;
        end
        // REFRESH/MRS: ignored (no refresh needed in model)
    end
endmodule
