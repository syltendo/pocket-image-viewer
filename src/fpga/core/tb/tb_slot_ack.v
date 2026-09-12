// tb_slot_ack.v — full dataslot_requestwrite -> ACK path.
//
// Instantiates slot_mgr + bmp_parser + sdram_ctrl + sdram_model exactly
// like core_top does, drives dataslot_requestwrite (like core_bridge_cmd),
// and checks that dataslot_requestwrite_ack asserts. A timeout here is
// the "Target not responding" hang.

`default_nettype none
`timescale 1ns/1ps

module tb_slot_ack;

    reg clk_74a = 0;
    always #6.73 clk_74a = ~clk_74a;   // 74.25 MHz

    reg clk_mem = 0;
    always #5.05 clk_mem = ~clk_mem;    // 99 MHz

    reg reset_n = 0;
    reg mem_rst_n = 0;

    // ---- bridge side stimulus (like core_bridge_cmd) ----
    reg        dataslot_requestwrite = 0;
    reg [15:0] dataslot_requestwrite_id = 0;
    reg [31:0] dataslot_requestwrite_size = 0;
    reg        dataslot_allcomplete = 0;
    wire       dataslot_requestwrite_ack;
    wire       dataslot_requestwrite_ok;

    reg [31:0] bridge_addr = 0;
    reg        bridge_wr = 0;
    reg [31:0] bridge_wr_data = 0;

    // ---- slot_mgr <-> parser ----
    wire [31:0] fifo_wr_data, fifo_in_rd_data;
    wire        fifo_wr_en, fifo_wr_full;
    wire        fifo_in_rd_en, fifo_in_rd_empty;
    wire        sm_ps_start, sm_ps_clear_only, sm_ps_ready, sm_ps_done, sm_ps_op_valid;
    wire [2:0]  sm_ps_slot_id;
    wire [21:0] sm_ps_total_words;
    wire [1:0]  sm_ps_last_valid;
    wire [7:0]  slot_valid;

    slot_mgr sm (
        .clk(clk_74a), .rst_n(reset_n),
        .dataslot_requestwrite(dataslot_requestwrite),
        .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_requestwrite_size(dataslot_requestwrite_size),
        .dataslot_allcomplete(dataslot_allcomplete),
        .dataslot_requestwrite_ack(dataslot_requestwrite_ack),
        .dataslot_requestwrite_ok(dataslot_requestwrite_ok),
        .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .fifo_wr_data(fifo_wr_data), .fifo_wr_en(fifo_wr_en),
        .fifo_wr_full(fifo_wr_full),
        .mem_clk(clk_mem), .mem_rst_n(mem_rst_n),
        .ps_start(sm_ps_start), .ps_slot_id(sm_ps_slot_id),
        .ps_total_words(sm_ps_total_words), .ps_last_valid(sm_ps_last_valid),
        .ps_clear_only(sm_ps_clear_only),
        .ps_ready(sm_ps_ready), .ps_done(sm_ps_done),
        .ps_op_valid(sm_ps_op_valid),
        .slot_valid(slot_valid), .busy(), .fifo_overflow()
    );

    // input FIFO (small for TB speed)
    async_fifo #(.DATA_W(32), .ADDR_W(10)) fifo_in (
        .wr_clk(clk_74a), .wr_rst_n(reset_n),
        .wr_data(fifo_wr_data), .wr_en(fifo_wr_en),
        .wr_full(fifo_wr_full), .wr_level(),
        .rd_clk(clk_mem), .rd_rst_n(mem_rst_n),
        .rd_data(fifo_in_rd_data), .rd_en(fifo_in_rd_en),
        .rd_empty(fifo_in_rd_empty), .rd_level()
    );

    // ---- parser + SDRAM ----
    wire        p_wr_req, p_wr_busy, p_wr_valid, p_wr_ready;
    wire [24:0] p_wr_addr;
    wire [20:0] p_wr_len;
    wire [15:0] p_wr_data;
    wire        sdram_init_done;
    wire [12:0] dram_a;
    wire [1:0]  dram_ba;
    wire        dram_ras_n, dram_cas_n, dram_we_n;
    wire [1:0]  dram_dqm;
    wire        dram_cke;
    wire [15:0] dram_dq;

    bmp_parser parser (
        .clk(clk_mem), .rst_n(mem_rst_n),
        .start(sm_ps_start), .slot_id(sm_ps_slot_id),
        .total_words(sm_ps_total_words), .last_valid(sm_ps_last_valid),
        .clear_only(sm_ps_clear_only),
        .sdram_init_done(sdram_init_done),
        .ready(sm_ps_ready), .idle(), .done(sm_ps_done), .op_valid(sm_ps_op_valid),
        .fifo_data(fifo_in_rd_data), .fifo_empty(fifo_in_rd_empty),
        .fifo_rd(fifo_in_rd_en),
        .wr_req(p_wr_req), .wr_addr(p_wr_addr), .wr_len(p_wr_len),
        .wr_busy(p_wr_busy), .wr_data(p_wr_data),
        .wr_valid(p_wr_valid), .wr_ready(p_wr_ready)
    );

    sdram_ctrl mem_ctrl (
        .clk(clk_mem), .rst_n(mem_rst_n),
        .init_done(sdram_init_done),
        .wr_req(p_wr_req), .wr_addr(p_wr_addr), .wr_len(p_wr_len),
        .wr_busy(p_wr_busy), .wr_data(p_wr_data),
        .wr_valid(p_wr_valid), .wr_ready(p_wr_ready),
        .rd_req(1'b0), .rd_addr(25'd0), .rd_len(16'd0),
        .rd_busy(), .rd_data(), .rd_valid(), .rd_ready(1'b1),
        .dram_a(dram_a), .dram_ba(dram_ba),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_dqm(dram_dqm),
        .dram_cke(dram_cke), .dram_dq(dram_dq)
    );

    sdram_model chip (
        .clk(clk_mem), .a(dram_a), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm),
        .cke(dram_cke), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n)
    );

    integer timeout;
    initial begin
        // (VCD dumping disabled: fills /tmp on long runs)

        #100;
        reset_n = 1;
        mem_rst_n = 1;
        $display("[%0t] resets released", $time);

        // wait for SDRAM init
        timeout = 0;
        while (!sdram_init_done && timeout < 100000) begin
            @(posedge clk_mem); timeout = timeout + 1;
        end
        if (!sdram_init_done) begin
            $display("FAIL: sdram init_done never asserted");
            $finish;
        end
        $display("[%0t] init_done OK", $time);

        // host sends dataslot_requestwrite for slot 0, 1.7MB
        @(posedge clk_74a);
        #1;  // avoid race with DUT's posedge block
        dataslot_requestwrite_id = 16'd0;
        dataslot_requestwrite_size = 32'd1780000;
        dataslot_requestwrite = 1;
        $display("[%0t] requestwrite asserted", $time);
        $display("  sm.dataslot_requestwrite=%b sm.req_1=%b sm.req_rise=%b sm.rst_n=%b",
                 sm.dataslot_requestwrite, sm.req_1, sm.req_rise, sm.rst_n);
        // trace next 10 cycles in detail
        repeat (10) begin
            @(posedge clk_74a);
            #1;
            $display("  cyc: req=%b req_1=%b rise=%b pend=%b state=%0d",
                     sm.dataslot_requestwrite, sm.req_1, sm.req_rise,
                     sm.pending, sm.state);
        end

        // wait for ACK (this is what the Pocket waits for)
        // print state periodically to see where it sticks
        timeout = 0;
        while (!dataslot_requestwrite_ack && timeout < 5000000) begin
            @(posedge clk_74a); timeout = timeout + 1;
            if (timeout % 500000 == 0)
                $display("  ... %0d cycles: sm.state=%0d pend=%b req=%b req_1=%b rise=%b parser.state=%0d ready=%b wr_busy=%b init=%b",
                         timeout, sm.state, sm.pending, sm.dataslot_requestwrite,
                         sm.req_1, sm.req_rise, parser.state,
                         sm_ps_ready, p_wr_busy, sdram_init_done);
        end
        if (!dataslot_requestwrite_ack) begin
            $display("FAIL: ACK never asserted after %0d clk_74a cycles -- HANG REPRODUCED", timeout);
            $display("      sm.state=%0d parser.state=%0d init_done=%b",
                     sm.state, parser.state, sdram_init_done);
            $finish;
        end
        $display("[%0t] ACK asserted (ok=%b) after %0d cycles -- PASS",
                 $time, dataslot_requestwrite_ok, timeout);

        // host deasserts, like core_bridge_cmd does after ACK
        @(posedge clk_74a);
        dataslot_requestwrite = 0;

        #1000;
        $display("DONE");
        $finish;
    end

endmodule
