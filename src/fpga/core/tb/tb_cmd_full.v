// tb_cmd_full.v — simulate a host sending 0x0082 via bridge writes,
// through core_bridge_cmd into slot_mgr, checking the command completes.
`default_nettype none
`timescale 1ns/1ps

module tb_cmd_full;
    reg clk_74a = 0;
    always #6.73 clk_74a = ~clk_74a;

    reg clk_mem = 0;
    always #5.05 clk_mem = ~clk_mem;

    reg reset_n = 0;
    reg mem_rst_n = 0;

    // bridge signals (driven by TB as the host)
    reg         bridge_wr = 0;
    reg  [31:0] bridge_addr = 0;
    reg  [31:0] bridge_wr_data = 0;
    reg         bridge_rd = 0;
    wire [31:0] bridge_rd_data;

    // slot_mgr <-> parser (stub parser: ready immediately)
    wire        sm_ps_start;
    wire [2:0]  sm_ps_slot;
    wire [21:0] sm_ps_words;
    wire [1:0]  sm_ps_last;
    wire        sm_ps_clear;
    reg         ps_ready = 0;
    reg         ps_done = 0;
    reg         ps_op_valid = 0;

    wire        ack;
    wire        ok;

    core_bridge_cmd icb (
        .clk(clk_74a), .reset_n(reset_n),
        .bridge_endian_little(1'b1),
        .bridge_addr(bridge_addr),
        .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .status_boot_done(1'b1),
        .status_setup_done(1'b1),
        .status_running(1'b1),
        .dataslot_requestwrite_ack(ack),
        .dataslot_requestwrite_ok(ok),
        // tie off the rest
        .dataslot_requestread_ack(1'b0),
        .dataslot_requestread_ok(1'b0),
        .dataslot_requestwrite(dataslot_requestwrite),
        .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_requestwrite_size(dataslot_requestwrite_size),
        .dataslot_allcomplete(),
        .dataslot_requestread(),
        .dataslot_requestread_id(),
        .dataslot_update(),
        .dataslot_update_id(),
        .dataslot_update_size()
    );

    wire        dataslot_requestwrite;
    wire [15:0] dataslot_requestwrite_id;
    wire [31:0] dataslot_requestwrite_size;

    slot_mgr sm (
        .clk(clk_74a), .rst_n(reset_n),
        .dataslot_requestwrite(dataslot_requestwrite),
        .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_requestwrite_size(dataslot_requestwrite_size),
        .dataslot_allcomplete(1'b0),
        .dataslot_requestwrite_ack(ack),
        .dataslot_requestwrite_ok(ok),
        .bridge_addr(bridge_addr),
        .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .fifo_wr_data(), .fifo_wr_en(), .fifo_wr_full(1'b0),
        .mem_clk(clk_mem), .mem_rst_n(mem_rst_n),
        .ps_start(sm_ps_start), .ps_slot_id(sm_ps_slot),
        .ps_total_words(sm_ps_words), .ps_last_valid(sm_ps_last),
        .ps_clear_only(sm_ps_clear),
        .ps_ready(ps_ready), .ps_done(ps_done), .ps_op_valid(ps_op_valid),
        .slot_valid(), .busy(), .fifo_overflow()
    );

    // host task: write to bridge
    task bridge_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk_74a); #1;
        bridge_addr = addr;
        bridge_wr_data = data;
        bridge_wr = 1;
        @(posedge clk_74a); #1;
        bridge_wr = 0;
    end
    endtask

    // host task: read bridge status (host_0 at 0xF8000000)
    task bridge_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk_74a); #1;
        bridge_addr = addr;
        bridge_rd = 1;
        @(posedge clk_74a); #1;
        data = bridge_rd_data;
        bridge_rd = 0;
    end
    endtask

    reg [31:0] status;
    integer timeout;

    initial begin
        #100;
        reset_n = 1;
        mem_rst_n = 1;
        #1000;

        // Send 0x0082 command like the Pocket does:
        // 1. Write params to 0xF8000020 (id) and 0xF8000024 (size)
        // 2. Write 'CM' + cmd to 0xF8000000
        $display("[%0t] sending 0x0082...", $time);
        bridge_write(32'hF8000020, 32'd0);        // slot id = 0
        bridge_write(32'hF8000024, 32'd1780000);  // size = 1.78MB
        bridge_write(32'hF8000000, 32'h434D0082); // 'CM' + 0x0082

        // Poll status until done (host_0[31:16] == 'BU' (0x4255) means busy)
        timeout = 0;
        status = 32'h42550000; // busy
        while (status[31:16] == 16'h4255 && timeout < 100000) begin
            bridge_read(32'hF8000000, status);
            timeout = timeout + 1;
            #100;
        end

        if (status[31:16] == 16'h4255) begin
            $display("FAIL: command timed out (target not responding)");
        end else begin
            $display("[%0t] command completed, result=%0d", $time, status[15:0]);
            if (status[15:0] == 0)
                $display("PASS: 0x0082 ACKed successfully");
            else
                $display("FAIL: result code %0d", status[15:0]);
        end
        $finish;
    end
endmodule
