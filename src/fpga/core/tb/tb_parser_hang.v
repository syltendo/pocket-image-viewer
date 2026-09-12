// tb_parser_hang.v — reproduce the "Target not responding" hang.
//
// Scenario: host sends dataslot_requestwrite -> slot_mgr waits for parser
// `ready` before ACKing. This TB drives the parser exactly like slot_mgr
// does (start pulse + params) and checks that `ready` asserts, i.e. the
// framebuffer clear completes through sdram_ctrl + sdram_model.
//
// A timeout on `ready` reproduces the hardware hang and tells us which
// stage (init / start / clear) is stuck.

`default_nettype none
`timescale 1ns/1ps

module tb_parser_hang;

    reg clk = 0;
    always #5.05 clk = ~clk;   // ~99 MHz

    reg rst_n = 0;

    // ---- SDRAM controller ----
    wire        init_done;
    wire        p_wr_req, p_wr_busy, p_wr_valid, p_wr_ready;
    wire [24:0] p_wr_addr;
    wire [20:0] p_wr_len;
    wire [15:0] p_wr_data;

    // read port tied off
    wire v_rd_busy, v_rd_valid;
    wire [15:0] v_rd_data;

    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire        dram_ras_n, dram_cas_n, dram_we_n;
    wire [1:0]  dram_dqm;
    wire        dram_cke;
    wire [15:0] dram_dq;

    sdram_ctrl mem_ctrl (
        .clk(clk), .rst_n(rst_n),
        .init_done(init_done),
        .wr_req(p_wr_req), .wr_addr(p_wr_addr), .wr_len(p_wr_len),
        .wr_busy(p_wr_busy), .wr_data(p_wr_data),
        .wr_valid(p_wr_valid), .wr_ready(p_wr_ready),
        .rd_req(1'b0), .rd_addr(25'd0), .rd_len(16'd0),
        .rd_busy(v_rd_busy), .rd_data(v_rd_data), .rd_valid(v_rd_valid),
        .rd_ready(1'b1),
        .dram_a(dram_a), .dram_ba(dram_ba),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_dqm(dram_dqm),
        .dram_cke(dram_cke), .dram_dq(dram_dq)
    );

    // SDRAM chip model on the same clock (phase shift ignored in TB)
    sdram_model chip (
        .clk(clk), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
        .cke(dram_cke), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n)
    );

    // ---- BMP parser ----
    reg        p_start = 0;
    reg [2:0]  p_slot = 0;
    reg [21:0] p_words = 22'd100;
    reg [1:0]  p_last = 2'd0;
    reg        p_clear_only = 0;
    wire       p_ready, p_idle, p_done, p_op_valid;
    wire       p_fifo_rd;

    bmp_parser parser (
        .clk(clk), .rst_n(rst_n),
        .start(p_start), .slot_id(p_slot),
        .total_words(p_words), .last_valid(p_last),
        .clear_only(p_clear_only),
        .sdram_init_done(init_done),
        .ready(p_ready), .idle(p_idle), .done(p_done), .op_valid(p_op_valid),
        .fifo_data(32'd0), .fifo_empty(1'b1), .fifo_rd(p_fifo_rd),
        .wr_req(p_wr_req), .wr_addr(p_wr_addr), .wr_len(p_wr_len),
        .wr_busy(p_wr_busy), .wr_data(p_wr_data),
        .wr_valid(p_wr_valid), .wr_ready(p_wr_ready)
    );

    // ---- stimulus ----
    integer timeout;
    initial begin
        $dumpfile("tb_parser_hang.vcd");
        $dumpvars(0, tb_parser_hang);

        #100 rst_n = 1;
        $display("[%0t] reset released", $time);

        // wait for SDRAM init
        timeout = 0;
        while (!init_done && timeout < 100000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        if (!init_done) begin
            $display("FAIL: sdram init_done never asserted after %0d cycles", timeout);
            $finish;
        end
        $display("[%0t] init_done asserted after %0d cycles", $time, timeout);

        // pulse start like slot_mgr does
        @(posedge clk); p_start = 1;
        @(posedge clk); p_start = 0;
        $display("[%0t] start pulsed", $time);

        // wait for ready (parser clear done) — this is what the ACK waits on
        timeout = 0;
        while (!p_ready && timeout < 20000000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        if (!p_ready) begin
            $display("FAIL: parser ready never asserted after %0d cycles -- HANG REPRODUCED", timeout);
            $display("      parser state = %0d, wr_busy = %b", parser.state, p_wr_busy);
            $finish;
        end
        $display("[%0t] parser ready asserted after %0d cycles -- clear OK", $time, timeout);

        // wait for done (no pixel data: fifo empty, should finish via no_more_data)
        timeout = 0;
        while (!p_done && timeout < 20000000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        if (!p_done)
            $display("FAIL: parser done never asserted");
        else
            $display("[%0t] parser done asserted, op_valid=%b -- PASS", $time, p_op_valid);

        $finish;
    end

endmodule
