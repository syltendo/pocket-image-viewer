// tb_parser_start_latch.v
// Verifies that bmp_parser latches the 1-cycle start pulse and waits for
// sdram_init_done, rather than missing the pulse if SDRAM isn't ready.

`timescale 1ns/1ps

module tb_parser_start_latch;

reg clk;
reg rst_n;
reg start;
reg [2:0] slot_id;
reg [21:0] total_words;
reg [1:0] last_valid;
reg clear_only;
reg sdram_init_done;
wire ready;
wire idle;
wire done;
wire op_valid;
reg [31:0] fifo_data;
reg fifo_empty;
wire fifo_rd;
wire wr_req;
wire [24:0] wr_addr;
wire [20:0] wr_len;
reg wr_busy;
wire [15:0] wr_data;
wire wr_valid;
reg wr_ready;

bmp_parser dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .slot_id(slot_id),
    .total_words(total_words),
    .last_valid(last_valid),
    .clear_only(clear_only),
    .sdram_init_done(sdram_init_done),
    .ready(ready),
    .idle(idle),
    .done(done),
    .op_valid(op_valid),
    .fifo_data(fifo_data),
    .fifo_empty(fifo_empty),
    .fifo_rd(fifo_rd),
    .wr_req(wr_req),
    .wr_addr(wr_addr),
    .wr_len(wr_len),
    .wr_busy(wr_busy),
    .wr_data(wr_data),
    .wr_valid(wr_valid),
    .wr_ready(wr_ready)
);

// 99 MHz clock
initial clk = 0;
always #5.05 clk = ~clk;

integer pass;
integer fail;

initial begin
    pass = 0;
    fail = 0;
    
    // Initialize
    rst_n = 0;
    start = 0;
    slot_id = 3'd0;
    total_words = 22'd100;
    last_valid = 2'd0;
    clear_only = 0;
    sdram_init_done = 0;  // SDRAM NOT ready
    fifo_data = 32'd0;
    fifo_empty = 1;
    wr_busy = 0;
    wr_ready = 0;
    
    // Reset
    #100;
    rst_n = 1;
    #20;
    
    // TEST 1: Pulse start while sdram_init_done=0
    // The parser should LATCH it, not miss it.
    $display("TEST 1: Start pulse with sdram_init_done=0 (should latch, not start yet)");
    @(posedge clk);
    start = 1;
    @(posedge clk);
    start = 0;
    
    // Wait a few cycles - parser should still be idle (waiting for SDRAM)
    #50;
    if (idle == 1) begin
        $display("  PASS: Parser still idle (waiting for SDRAM init)");
        pass = pass + 1;
    end else begin
        $display("  FAIL: Parser left idle without SDRAM ready!");
        fail = fail + 1;
    end
    
    if (wr_req == 0) begin
        $display("  PASS: wr_req not asserted (correctly waiting)");
        pass = pass + 1;
    end else begin
        $display("  FAIL: wr_req asserted without SDRAM ready!");
        fail = fail + 1;
    end
    
    // TEST 2: Assert sdram_init_done - parser should now start
    $display("TEST 2: Assert sdram_init_done (parser should start)");
    @(posedge clk);
    sdram_init_done = 1;
    
    // Wait for parser to leave idle
    // Note: with clear bypass, parser goes directly to S_HDR (header parse)
    // instead of S_CLEAR_REQ, so wr_req won't be asserted immediately.
    #100;
    if (idle == 0) begin
        $display("  PASS: Parser left idle (started operation)");
        pass = pass + 1;
    end else begin
        $display("  FAIL: Parser still idle after SDRAM ready! (start pulse was missed)");
        fail = fail + 1;
    end
    
    // Parser should be in header parsing state (not clearing)
    // We verify by checking it's not idle and hasn't asserted done yet
    if (done == 0) begin
        $display("  PASS: Parser busy (not done yet, parsing header)");
        pass = pass + 1;
    end else begin
        $display("  FAIL: Parser asserted done too early!");
        fail = fail + 1;
    end
    
    // Summary
    $display("");
    $display("========================================");
    $display("Results: %0d passed, %0d failed", pass, fail);
    $display("========================================");
    
    if (fail == 0)
        $display("ALL TESTS PASSED - Start latch works correctly");
    else
        $display("TESTS FAILED - Start latch is broken");
    
    $finish;
end

// Timeout
initial begin
    #10000;
    $display("TIMEOUT!");
    $finish;
end

endmodule
