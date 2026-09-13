// Full parser simulation with real BMP file
`timescale 1ns/1ps

module tb_parser_full;
    reg clk = 0;
    reg rst_n = 0;
    
    // Parser inputs
    reg start = 0;
    reg [2:0] slot_id = 0;
    reg [21:0] total_words;
    reg [1:0] last_valid = 0;
    reg clear_only = 0;
    reg sdram_init_done = 0;
    
    // FIFO interface
    reg [31:0] fifo_data = 0;
    reg fifo_empty = 1;
    wire fifo_rd;
    
    // SDRAM write interface (stubbed: always ready)
    wire wr_req;
    wire [24:0] wr_addr;
    wire [20:0] wr_len;
    reg wr_busy = 0;
    wire [15:0] wr_data;
    wire wr_valid;
    reg wr_ready = 1;
    
    // Outputs
    wire ready;
    wire idle;
    wire done;
    wire op_valid;
    wire [4:0] debug_state;
    
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
        .debug_state(debug_state),
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
    
    always #5 clk = ~clk;  // 100MHz
    
    // BMP file data
    reg [7:0] bmp_bytes [0:2000000];
    integer file_size;
    integer i;
    integer word_idx = 0;
    integer bytes_loaded = 0;
    
    initial begin
        // Load BMP file
        $readmemh("/home/hatch/workspace/user/files/img1.bmp", bmp_bytes);
        // Actually use $fread for binary
        $display("Loading BMP...");
    end
    
    // Simpler: use file I/O
    integer fd;
    integer c;
    initial begin
        fd = $fopen("/home/hatch/workspace/user/files/img1.bmp", "rb");
        if (fd == 0) begin
            $display("ERROR: Cannot open BMP file");
            $finish;
        end
        file_size = 0;
        while (!$feof(fd)) begin
            c = $fgetc(fd);
            if (c != -1) begin
                bmp_bytes[file_size] = c[7:0];
                file_size = file_size + 1;
            end
        end
        $fclose(fd);
        $display("Loaded BMP: %0d bytes", file_size);
        
        total_words = (file_size + 3) / 4;
        $display("Total words: %0d", total_words);
        
        // Reset
        #100;
        rst_n = 1;
        #100;
        
        // SDRAM init done
        sdram_init_done = 1;
        #100;
        
        // Start parser
        start = 1;
        #10;
        start = 0;
        
        // Feed data when parser requests
        fork
            begin
                // Timeout
                #50000000;  // 50ms
                $display("TIMEOUT! State=%0d, done=%b, op_valid=%b", debug_state, done, op_valid);
                $display("FAIL: Parser hung");
                $finish;
            end
            begin
                // Wait for done
                wait(done);
                #100;
                $display("Done! op_valid=%b, state=%0d", op_valid, debug_state);
                if (op_valid)
                    $display("PASS: Parser completed successfully");
                else
                    $display("FAIL: Parser completed but op_valid=0 (header rejected)");
                $finish;
            end
        join
    end
    
    // Feed FIFO data
    always @(posedge clk) begin
        if (fifo_rd && !fifo_empty) begin
            word_idx <= word_idx + 1;
            if (word_idx + 1 >= total_words) begin
                fifo_empty <= 1;
            end
        end
        // Provide data
        if (word_idx < total_words) begin
            fifo_empty <= 0;
            // Pack 4 bytes MSB-first (as bridge does)
            fifo_data <= {bmp_bytes[word_idx*4], bmp_bytes[word_idx*4+1], 
                         bmp_bytes[word_idx*4+2], bmp_bytes[word_idx*4+3]};
        end else begin
            fifo_empty <= 1;
        end
    end
    
    // Monitor state changes
    reg [4:0] prev_state = 0;
    always @(posedge clk) begin
        if (debug_state != prev_state) begin
            $display("Time %0t: State %0d -> %0d", $time, prev_state, debug_state);
            prev_state <= debug_state;
        end
    end
    
endmodule
