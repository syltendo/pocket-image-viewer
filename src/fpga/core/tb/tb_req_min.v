// tb_req_min.v — minimal test of slot_mgr request latching
`default_nettype none
`timescale 1ns/1ps

module tb_req_min;
    reg clk = 0;
    always #6.73 clk = ~clk;

    reg rst_n = 0;
    reg req = 0;
    reg [15:0] req_id = 0;
    reg [31:0] req_size = 0;
    wire ack, ok;

    slot_mgr sm (
        .clk(clk), .rst_n(rst_n),
        .dataslot_requestwrite(req),
        .dataslot_requestwrite_id(req_id),
        .dataslot_requestwrite_size(req_size),
        .dataslot_allcomplete(1'b0),
        .dataslot_requestwrite_ack(ack),
        .dataslot_requestwrite_ok(ok),
        .bridge_addr(32'd0), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
        .fifo_wr_data(), .fifo_wr_en(), .fifo_wr_full(1'b0),
        .mem_clk(clk), .mem_rst_n(rst_n),
        .ps_start(), .ps_slot_id(), .ps_total_words(), .ps_last_valid(),
        .ps_clear_only(),
        .ps_ready(1'b0), .ps_done(1'b0), .ps_op_valid(1'b0),
        .slot_valid(), .busy(), .fifo_overflow()
    );

    initial begin
        $monitor("[%0t] req=%b req_1=%b rise=%b pend=%b state=%0d",
                 $time, req, sm.req_1, sm.req_rise, sm.pending, sm.state);
        #100 rst_n = 1;
        #100;
        @(posedge clk);
        #1;  // move past the edge to avoid race
        req_id = 16'd0;
        req_size = 32'd100;
        req = 1;
        #200;
        $finish;
    end
endmodule
