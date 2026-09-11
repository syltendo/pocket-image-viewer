// tb_async_fifo.v — verify data integrity across unrelated clocks,
// full/empty behavior, and level counts.
`default_nettype none
`timescale 1ns/1ps

module tb_async_fifo;

    localparam DATA_W = 16;
    localparam ADDR_W = 4;   // depth 16, small so we hit full/empty

    reg wr_clk = 0, rd_clk = 0;
    reg wr_rst_n = 0, rd_rst_n = 0;
    reg wr_en = 0;
    reg [DATA_W-1:0] wr_data = 0;
    wire wr_full;
    wire [ADDR_W:0] wr_level;
    reg rd_en = 0;
    wire [DATA_W-1:0] rd_data;
    wire rd_empty;
    wire [ADDR_W:0] rd_level;

    async_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .wr_en(wr_en), .wr_data(wr_data),
        .wr_full(wr_full), .wr_level(wr_level),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .rd_en(rd_en), .rd_data(rd_data),
        .rd_empty(rd_empty), .rd_level(rd_level)
    );

    // unrelated clocks: 100 MHz write, 61.8 MHz read
    always #5    wr_clk = ~wr_clk;
    always #8.09 rd_clk = ~rd_clk;

    integer errors = 0;
    integer i;
    reg [DATA_W-1:0] expected [0:255];

    initial begin
        #100;
        @(posedge wr_clk) wr_rst_n = 1;
        @(posedge rd_clk) rd_rst_n = 1;
        #100;

        // --- test 1: fill until full
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge wr_clk);
            #1;
            if (wr_full) begin
                $display("ERROR: full too early at i=%0d", i);
                errors = errors + 1;
            end
            wr_data = i * 17 + 3;
            expected[i] = wr_data;
            wr_en = 1;
            @(posedge wr_clk); #1;
            wr_en = 0;
        end
        repeat (4) @(posedge wr_clk); #1;
        if (!wr_full) begin $display("ERROR: not full after 16 writes"); errors = errors + 1; end
        if (wr_level !== 16) begin $display("ERROR: wr_level=%0d, want 16", wr_level); errors = errors + 1; end

        // --- test 2: drain, check order
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge rd_clk);
            while (rd_empty) @(posedge rd_clk);
            #1; rd_en = 1;
            @(posedge rd_clk); #1; rd_en = 0;
            @(posedge rd_clk); #1;
            if (rd_data !== expected[i]) begin
                $display("ERROR: read[%0d]=%0d, want %0d", i, rd_data, expected[i]);
                errors = errors + 1;
            end
        end
        repeat (10) @(posedge rd_clk); #1;
        if (!rd_empty) begin $display("ERROR: not empty after drain"); errors = errors + 1; end

        // --- test 3: streaming with both sides active (stress)
        fork
            begin : writer
                integer wi;
                for (wi = 0; wi < 200; wi = wi + 1) begin
                    @(posedge wr_clk);
                    while (wr_full) @(posedge wr_clk);
                    #1;
                    wr_data = 1000 + wi;
                    expected[wi] = 1000 + wi;
                    wr_en = 1;
                    @(posedge wr_clk); #1;
                    wr_en = 0;
                end
            end
            begin : reader
                integer ri;
                for (ri = 0; ri < 200; ri = ri + 1) begin
                    @(posedge rd_clk);
                    while (rd_empty) @(posedge rd_clk);
                    #1; rd_en = 1;
                    @(posedge rd_clk); #1; rd_en = 0;
                    @(posedge rd_clk); #1;
                    if (rd_data !== expected[ri]) begin
                        $display("ERROR: stream read[%0d]=%0d want %0d", ri, rd_data, expected[ri]);
                        errors = errors + 1;
                    end
                end
            end
        join

        repeat (20) @(posedge wr_clk);
        if (errors == 0) $display("PASS: async_fifo");
        else $display("FAIL: async_fifo (%0d errors)", errors);
        $finish;
    end

    // watchdog
    initial begin #20000000; $display("FAIL: timeout"); $finish; end

endmodule
