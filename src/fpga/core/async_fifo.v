// async_fifo.v
//
// Dual-clock FIFO with Gray-coded pointers. Depth = 2^ADDR_W, width = DATA_W.
// Full/empty are conservative (safe). Read data is registered: rd_data is
// valid one rd_clk after rd_en.
//
// rd_level: occupancy in the read domain (binary, exact).
// wr_level: occupancy in the write domain (binary, conservative: the synced
//           read pointer can lag, so this may read slightly high).

module async_fifo #(
    parameter DATA_W = 8,
    parameter ADDR_W = 14            // depth = 2^ADDR_W
)(
    // write side
    input  wire              wr_clk,
    input  wire              wr_rst_n,
    input  wire [DATA_W-1:0] wr_data,
    input  wire              wr_en,
    output wire              wr_full,
    output wire [ADDR_W:0]   wr_level,
    // read side
    input  wire              rd_clk,
    input  wire              rd_rst_n,
    output wire [DATA_W-1:0] rd_data,
    input  wire              rd_en,
    output wire              rd_empty,
    output wire [ADDR_W:0]   rd_level
);
    localparam DEPTH = (1 << ADDR_W);

    // Gray -> binary (for level computation)
    function [ADDR_W:0] gray2bin;
        input [ADDR_W:0] g;
        integer i;
        begin
            gray2bin[ADDR_W] = g[ADDR_W];
            for (i = ADDR_W-1; i >= 0; i = i-1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    // ---------------------------------------------------------------- memory
    // (Inferred block RAM. Quartus maps to M9K.)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------- write pointer
    reg [ADDR_W:0] wr_bin;
    reg [ADDR_W:0] wr_gray;
    wire [ADDR_W:0] wr_bin_next  = wr_bin + 1'b1;
    wire [ADDR_W:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;

    // read pointer synced into write domain
    reg [ADDR_W:0] rd_gray_w1, rd_gray_w2;

    // Full when the binary pointers differ by DEPTH: the Gray codes then
    // match except for the top two (inverted) bits. Uses the CURRENT write
    // Gray pointer because wr_full gates writes combinationally.
    wire wr_full_next = (wr_gray == {~rd_gray_w2[ADDR_W:ADDR_W-1],
                                     rd_gray_w2[ADDR_W-2:0]});

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {(ADDR_W+1){1'b0}};
            wr_gray <= {(ADDR_W+1){1'b0}};
            rd_gray_w1 <= {(ADDR_W+1){1'b0}};
            rd_gray_w2 <= {(ADDR_W+1){1'b0}};
        end else begin
            if (wr_en && !wr_full) begin
                mem[wr_bin[ADDR_W-1:0]] <= wr_data;
                wr_bin  <= wr_bin_next;
                wr_gray <= wr_gray_next;
            end
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
        end
    end
    assign wr_full = wr_full_next;
    assign wr_level = wr_bin - gray2bin(rd_gray_w2);

    // -------------------------------------------------------- read pointer
    reg [ADDR_W:0] rd_bin;
    reg [ADDR_W:0] rd_gray;
    wire [ADDR_W:0] rd_bin_next  = rd_bin + 1'b1;
    wire [ADDR_W:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // write pointer synced into read domain
    reg [ADDR_W:0] wr_gray_r1, wr_gray_r2;
    wire [ADDR_W:0] wr_bin_r = gray2bin(wr_gray_r2);

    reg [DATA_W-1:0] rd_data_q;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin    <= {(ADDR_W+1){1'b0}};
            rd_gray   <= {(ADDR_W+1){1'b0}};
            rd_data_q <= {DATA_W{1'b0}};
            wr_gray_r1 <= {(ADDR_W+1){1'b0}};
            wr_gray_r2 <= {(ADDR_W+1){1'b0}};
        end else begin
            if (rd_en && !rd_empty) begin
                rd_data_q <= mem[rd_bin[ADDR_W-1:0]];
                rd_bin    <= rd_bin_next;
                rd_gray   <= rd_gray_next;
            end
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
        end
    end

    assign rd_data  = rd_data_q;
    assign rd_empty = (rd_gray == wr_gray_r2);
    assign rd_level = wr_bin_r - rd_bin;

endmodule
