// sdram_ctrl.v
//
// SDRAM controller for the Pocket image viewer.
//   99 MHz controller clock; 16-bit data bus; 13 row bits / 10 col bits /
//   2 banks (64 MB). Burst length 8, CAS latency 3, sequential bursts.
//   Single write port + single read port. Reads are given priority because
//   video scanout is real-time; writes use the remaining bandwidth.
//
// Word address map: word_addr[24:0] = {bank[1:0], row[12:0], col[9:0]}.
//
// Every SDRAM burst is issued at an 8-word-aligned column. Words outside the
// requested range (unaligned head/tail) are masked with DQM, so the requester
// only ever moves the exact words it asked for. Bursts never cross a row
// boundary. At the end of every request all banks are precharged, so at most
// one row is ever open at a time.
//
// Refresh is interleaved between bursts: long transfers are paused for a
// refresh whenever the 7.8 us interval expires, so tREFI is always met.
//
// Write data path: the requester streams wr_data/wr_valid and the controller
// answers with wr_ready. A burst is only issued once all of its words are
// buffered, so the SDRAM never sees a mid-burst stall.
// Read data path: rd_data/rd_valid with rd_ready backpressure. READ commands
// are pipelined (one every 8 clocks); a delay line generates the capture
// enables so back-to-back bursts produce a contiguous data stream.
//
// Read capture timing (see pll_imageviewer.v): dram_clk lags the controller
// clock by ~9.6ns (340 deg). The SDRAM samples the READ ~9.6ns after issue
// and launches the first data word 3 dram_clk cycles later, so it is valid
// at the FPGA ~41-52ns after issue. The controller samples it 5 clocks
// (50.5ns) after issuing the READ.
//   RD_TAP = 4: capture enable for an issued READ is high during controller
//   cycles [issue+5, issue+12].
// NOTE: the phase/latency numbers are hand-derived, not measured on hardware.

module sdram_ctrl (
    input  wire        clk,            // 99 MHz controller clock
    input  wire        rst_n,          // synchronous reset, active low

    output reg         init_done,

    // ---- write port (BMP parser side) ----
    input  wire        wr_req,         // hold until wr_busy
    input  wire [24:0] wr_addr,        // word address (any alignment)
    input  wire [20:0] wr_len,        // word count, 1 .. 2097151
    output wire        wr_busy,
    input  wire [15:0] wr_data,
    input  wire        wr_valid,
    output wire        wr_ready,

    // ---- read port (video scanout side) ----
    input  wire        rd_req,         // hold until rd_busy
    input  wire [24:0] rd_addr,        // word address, must be 8-aligned
    input  wire [15:0] rd_len,         // word count, multiple of 8, nonzero
    output wire        rd_busy,
    output wire [15:0] rd_data,
    output wire        rd_valid,
    input  wire        rd_ready,

    // ---- SDRAM pins ----
    output reg  [12:0] dram_a,
    output reg  [1:0]  dram_ba,
    output reg         dram_ras_n,
    output reg         dram_cas_n,
    output reg         dram_we_n,
    output wire [1:0]  dram_dqm,
    output wire        dram_cke,
    inout  wire [15:0] dram_dq,
    // NOTE: dram_clk is driven straight from the PLL in core_top.

    // ---- diagnostics (mem_clk domain, for video debug colors) ----
    output reg [31:0]  diag_rd_burst,  // READ bursts issued
    output reg [31:0]  diag_rd_word,   // words captured to read FIFO
    output reg [31:0]  diag_wr_burst,  // WRITE bursts issued
    output reg [31:0]  diag_wr_word);  // words written to SDRAM

    // ------------------------------------------------------------ timing
    // Conservative, in controller clocks @ 99 MHz (10.1 ns period).
    localparam T_RCD      = 3;         // ACTIVATE -> READ/WRITE
    localparam T_RP       = 3;         // PRECHARGE -> ACTIVATE
    localparam T_RFC      = 10;        // REFRESH -> next command
    localparam T_WR       = 3;         // last write data -> PRECHARGE
    localparam T_MRD      = 2;         // MODE REGISTER SET -> next command
    localparam T_RTP      = 2;         // last read data -> PRECHARGE
    localparam RD_TAP     = 4;         // capture cycles [issue+5, issue+12]
    localparam T_REFI     = 780;       // 7.8 us refresh interval
    localparam INIT_WAIT  = 20000;     // 200 us power-up wait

    // ---------------------------------------------------------------- states
    localparam S_INIT_WAIT = 5'd0,
               S_INIT_PRE  = 5'd1,
               S_INIT_REF1 = 5'd2,
               S_INIT_REF2 = 5'd3,
               S_INIT_MRS  = 5'd4,
               S_IDLE      = 5'd5,
               S_PRE       = 5'd6,
               S_ACT       = 5'd7,
               S_WR_CMD    = 5'd8,
               S_WR_DATA   = 5'd9,
               S_RD_CMD    = 5'd10,
               S_RD_NEXT   = 5'd11,
               S_REF_PRE   = 5'd12,    // refresh between read bursts
               S_REF_ACT   = 5'd13,
               S_REF_DONE  = 5'd14,
               S_WREF_PRE  = 5'd15,    // refresh between write bursts
               S_WREF_ACT  = 5'd16,
               S_WREF_DONE = 5'd17,
               S_FINISH    = 5'd18,
               S_FIN_WAIT  = 5'd19,
               S_IDLE_REF  = 5'd20;    // refresh issued from idle

    reg [4:0] state;
    reg [15:0] timer;                  // generic countdown

    // ------------------------------------------------------- request state
    reg        req_is_write;
    reg [24:0] req_addr;               // current word address (advances)
    reg [20:0] req_rem;                // words remaining
    reg        open_valid;             // a row is currently open
    reg [1:0]  open_bank;
    reg [12:0] open_row;
    reg        wr_dirty;               // write burst issued, tWR not yet met

    // ------------------------------------------------------- burst decode
    // Combinational, from the current request position.
    wire [1:0]  b_bank = req_addr[24:23];
    wire [12:0] b_row  = req_addr[22:10];
    wire [9:0]  b_col  = req_addr[9:0];
    wire [9:0]  b_col_aligned = b_col & ~10'd7;
    wire [2:0]  b_off  = b_col[2:0];
    wire [20:0] b_max  = 21'd8 - {18'd0, b_off};
    wire [20:0] b_n    = (req_rem < b_max) ? req_rem : b_max; // 1..8
    wire [3:0]  b_n4   = b_n[3:0];
    wire [24:0] nxt_addr = req_addr + b_n;   // request position after this burst
    wire next_row_hit = open_valid && (open_bank == nxt_addr[24:23])
                                     && (open_row == nxt_addr[22:10]);
    wire row_hit = open_valid && (open_bank == b_bank) && (open_row == b_row);

    // DQM mask for the 8 word slots of the burst (1 = masked off).
    wire [7:0] b_mask;
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_mask
            // slot gi is live iff b_off <= gi < b_off + b_n
            assign b_mask[gi] = (gi < b_off) || ((gi - b_off) >= b_n4);
        end
    endgenerate

    // ------------------------------------------------------- write data FIFO
    // 64 x 16 synchronous FIFO (infers block RAM).
    reg [15:0] wrf_mem [0:63];
    reg [6:0]  wrf_wr, wrf_rd;         // one extra bit: full vs empty
    wire [6:0] wrf_level = wrf_wr - wrf_rd;
    wire       wrf_full  = (wrf_level == 7'd64);
    wire       wrf_empty = (wrf_level == 7'd0);
    reg        wrf_rd_en;
    wire [15:0] wrf_out = wrf_mem[wrf_rd[5:0]];
    assign wr_ready = !wrf_full;

    always @(posedge clk) begin
        if (wr_valid && wr_ready) begin
            wrf_mem[wrf_wr[5:0]] <= wr_data;
            wrf_wr <= wrf_wr + 1'b1;
        end
        if (wrf_rd_en && !wrf_empty)
            wrf_rd <= wrf_rd + 1'b1;
        if (!rst_n) begin
            wrf_wr <= 7'd0;
            wrf_rd <= 7'd0;
        end
    end

    // ------------------------------------------------------- read data FIFO
    // 32 x 16 synchronous FIFO.
    reg [15:0] rdf_mem [0:31];
    reg [5:0]  rdf_wr, rdf_rd;
    wire [5:0] rdf_level = rdf_wr - rdf_rd;
    wire       rdf_empty = (rdf_level == 6'd0);
    wire       rdf_full  = (rdf_level == 6'd32);
    reg        rdf_wr_en;
    reg [15:0] rdf_wr_data;
    assign rd_data  = rdf_mem[rdf_rd[4:0]];
    assign rd_valid = !rdf_empty;

    always @(posedge clk) begin
        if (rdf_wr_en && !rdf_full) begin
            rdf_mem[rdf_wr[4:0]] <= rdf_wr_data;
            rdf_wr <= rdf_wr + 1'b1;
        end
        if (rd_valid && rd_ready)
            rdf_rd <= rdf_rd + 1'b1;
        if (!rst_n) begin
            rdf_wr <= 6'd0;
            rdf_rd <= 6'd0;
        end
    end

    // ------------------------------------------------------- read capture
    // Delay line: each issued READ shifts a 1 in at bit 0. Bits
    // [RD_TAP+7:RD_TAP] ORed together are the capture enable (high during
    // cycles [issue+5, issue+12]); bit [RD_TAP+8] marks the burst finished.
    // Because READs are spaced >= 8 cycles apart, back-to-back bursts give
    // a contiguous capture stream.
    localparam CAP_W = RD_TAP + 9;     // bits 0 .. RD_TAP+8
    reg [CAP_W-1:0] cap_dly;
    wire issue_now = (state == S_RD_CMD) && (timer == 16'd0) && (rd_gap == 4'd0)
                     && rdf_room && (rdf_inflight < 4'd4);
    wire cap_en    = |cap_dly[RD_TAP+7:RD_TAP];
    wire fin_pulse = cap_dly[RD_TAP+8];
    reg [3:0] rdf_inflight;            // READs issued, capture not finished

    // Space accounting: never issue a READ unless the FIFO can absorb it
    // plus everything already in flight.
    wire [6:0] rdf_occ = {1'b0, rdf_level} + {rdf_inflight, 3'b0};
    wire rdf_room = (rdf_occ <= 7'd24); // 24 + new burst of 8 <= 32

    // ------------------------------------------------------- refresh
    reg [9:0] ref_cnt;
    reg       ref_pending;

    // ------------------------------------------------------- busy flags
    reg wr_busy_q, rd_busy_q;
    assign wr_busy = wr_busy_q;
    assign rd_busy = rd_busy_q;

    // ------------------------------------------------------- DQ / DQM
    reg        dq_oe;
    reg [15:0] dq_out;
    reg [1:0]  dqm_q;
    assign dram_dq  = dq_oe ? dq_out : 16'hzzzz;
    assign dram_dqm = dqm_q;
    assign dram_cke = 1'b1;  // CKE tied high (matches agg23's proven SNES controller).

    reg [2:0] wbit;                    // position inside the write burst
    reg [3:0] rd_gap;                  // spacing between READ commands

    // ------------------------------------------------------- main FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_INIT_WAIT;
            timer        <= INIT_WAIT;
            init_done    <= 1'b0;
            open_valid   <= 1'b0;
            wr_dirty     <= 1'b0;
            wr_busy_q    <= 1'b0;
            rd_busy_q    <= 1'b0;
            ref_cnt      <= 10'd0;
            ref_pending  <= 1'b0;
            cap_dly      <= {(CAP_W){1'b0}};
            rdf_inflight <= 4'd0;
            dq_oe        <= 1'b0;
            dq_out       <= 16'd0;
            dqm_q        <= 2'b00;
            dram_ras_n   <= 1'b1;
            dram_cas_n   <= 1'b1;
            dram_we_n    <= 1'b1;
            dram_a       <= 13'd0;
            dram_ba      <= 2'd0;
            wrf_rd_en    <= 1'b0;
            rdf_wr_en    <= 1'b0;
            wbit         <= 3'd0;
            rd_gap       <= 4'd0;
            diag_rd_burst <= 32'd0;
            diag_rd_word  <= 32'd0;
            diag_wr_burst <= 32'd0;
            diag_wr_word  <= 32'd0;
        end else begin
            // default: NOP on the bus, no FIFO movement
            dram_ras_n <= 1'b1;
            dram_cas_n <= 1'b1;
            dram_we_n  <= 1'b1;
            wrf_rd_en  <= 1'b0;
            rdf_wr_en  <= 1'b0;

            // refresh timer (runs once init is done)
            if (init_done && !ref_pending) begin
                if (ref_cnt == T_REFI - 1)
                    ref_pending <= 1'b1;
                else
                    ref_cnt <= ref_cnt + 1'b1;
            end

            // read-data capture pipeline (runs in every state)
            cap_dly <= {cap_dly[CAP_W-2:0], issue_now};
            if (cap_en) begin
                rdf_wr_data <= dram_dq;
                rdf_wr_en   <= 1'b1;
                diag_rd_word <= diag_rd_word + 1'b1;
            end
            if (issue_now) begin
                diag_rd_burst <= diag_rd_burst + 1'b1;
            end
            // (issue_now and fin_pulse can never coincide: READs are >= 8
            // clocks apart and a burst finishes 13 clocks after its issue)
            if (issue_now && !fin_pulse)
                rdf_inflight <= rdf_inflight + 1'b1;
            else if (fin_pulse && !issue_now)
                rdf_inflight <= rdf_inflight - 1'b1;

            case (state)

            // ------------------------------------------ init sequence
            S_INIT_WAIT: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b0;
                    dram_a[10] <= 1'b1;             // PRECHARGE ALL
                    state <= S_INIT_PRE; timer <= T_RP;
                end else timer <= timer - 1'b1;
            end
            S_INIT_PRE: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    state <= S_INIT_REF1; timer <= T_RFC;  // REFRESH #1
                end else timer <= timer - 1'b1;
            end
            S_INIT_REF1: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    state <= S_INIT_REF2; timer <= T_RFC;  // REFRESH #2
                end else timer <= timer - 1'b1;
            end
            S_INIT_REF2: begin
                if (timer == 16'd0) begin
                    // MODE REGISTER SET: burst length 8, sequential, CL=3
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0;
                    dram_we_n  <= 1'b0; dram_ba <= 2'd0;
                    dram_a <= 13'b0_00_011_0_011;
                    state <= S_INIT_MRS; timer <= T_MRD;
                end else timer <= timer - 1'b1;
            end
            S_INIT_MRS: begin
                if (timer == 16'd0) begin
                    init_done <= 1'b1;
                    state <= S_IDLE;
                end else timer <= timer - 1'b1;
            end

            // ------------------------------------------------ idle
            S_IDLE: begin
                if (ref_pending) begin
                    // All banks are precharged whenever we are idle, and
                    // tRP was met before entering idle: safe to refresh.
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    ref_pending <= 1'b0;
                    ref_cnt     <= 10'd0;
                    state <= S_IDLE_REF; timer <= T_RFC;
                end else if (rd_req) begin
                    req_is_write <= 1'b0;
                    req_addr   <= rd_addr;
                    req_rem    <= {5'd0, rd_len};
                    rd_busy_q  <= 1'b1;
                    rd_gap     <= 4'd0;
                    state <= S_PRE;
                end else if (wr_req) begin
                    req_is_write <= 1'b1;
                    req_addr   <= wr_addr;
                    req_rem    <= wr_len;
                    wr_busy_q  <= 1'b1;
                    state <= S_PRE;
                end
            end
            S_IDLE_REF: begin
                if (timer == 16'd0)
                    state <= S_IDLE;
                else
                    timer <= timer - 1'b1;
            end

            // --------------------------------- open the row if needed
            S_PRE: begin
                // If a write burst just finished, let tWR elapse first.
                if (wr_dirty && timer != 16'd0) begin
                    timer <= timer - 1'b1;
                end else begin
                    // PRECHARGE ALL (harmless if nothing is open).
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b0;
                    dram_a[10] <= 1'b1;
                    open_valid <= 1'b0;
                    wr_dirty   <= 1'b0;
                    state <= S_ACT; timer <= T_RP;
                end
            end
            S_ACT: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b1;
                    dram_ba <= b_bank;
                    dram_a  <= b_row;
                    open_valid <= 1'b1;
                    open_bank  <= b_bank;
                    open_row   <= b_row;
                    timer <= T_RCD;
                    state <= req_is_write ? S_WR_CMD : S_RD_CMD;
                end else timer <= timer - 1'b1;
            end

            // -------------------------------------------- write burst
            S_WR_CMD: begin
                if (timer != 16'd0) begin
                    timer <= timer - 1'b1;         // tRCD after ACTIVATE
                end else if (wrf_level >= {1'b0, b_n[5:0]}) begin
                    // Every word of this burst is buffered: issue WRITE
                    // at the aligned column.
                    dram_ras_n <= 1'b1; dram_cas_n <= 1'b0; dram_we_n <= 1'b0;
                    dram_ba <= b_bank;
                    dram_a  <= {3'd0, b_col_aligned}; // A10=0: no auto-precharge
                    wbit    <= 3'd0;
                    diag_wr_burst <= diag_wr_burst + 1'b1;
                    state   <= S_WR_DATA;
                end
                // else: wait for the writer to stream more words
            end
            S_WR_DATA: begin
                // One word per clock; masked slots drive DQM (don't-care data).
                dq_oe <= 1'b1;
                dqm_q  <= b_mask[wbit] ? 2'b11 : 2'b00;
                if (!b_mask[wbit]) begin
                    dq_out    <= wrf_out;
                    wrf_rd_en <= 1'b1;
                    diag_wr_word <= diag_wr_word + 1'b1;
                end else begin
                    dq_out <= 16'd0;
                end
                if (wbit == 3'd7) begin
                    dq_oe    <= 1'b0;
                    dqm_q    <= 2'b00;
                    wr_dirty <= 1'b1;
                    timer    <= T_WR;              // tWR before any PRECHARGE
                    req_addr <= req_addr + b_n;
                    req_rem  <= req_rem - b_n;
                    if (req_rem == b_n)
                        state <= S_FINISH;        // last burst
                    else if (ref_pending)
                        state <= S_WREF_PRE;      // refresh first
                    else if (next_row_hit) begin
                        timer <= 16'd0;            // row still open: no tRCD
                        state <= S_WR_CMD;
                    end else
                        state <= S_PRE;           // row changed: precharge
                end else begin
                    wbit <= wbit + 1'b1;
                end
            end

            // -------------------------------------------- read bursts
            S_RD_CMD: begin
                if (timer != 16'd0) begin
                    timer <= timer - 1'b1;         // tRCD after ACTIVATE
                end else if (rd_gap != 4'd0) begin
                    rd_gap <= rd_gap - 1'b1;        // spacing between READs
                end else if (rdf_room && rdf_inflight < 4'd4) begin
                    // Room for this burst plus everything in flight.
                    dram_ras_n <= 1'b1; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    dram_ba <= b_bank;
                    dram_a  <= {3'd0, b_col_aligned};
                    req_addr <= req_addr + b_n;
                    req_rem  <= req_rem - b_n;
                    rd_gap   <= 4'd7;              // next READ >= 8 clocks out
                    state    <= S_RD_NEXT;
                end
                // else: no room, wait (gap already 0)
            end
            S_RD_NEXT: begin
                if (rd_gap != 4'd0)
                    rd_gap <= rd_gap - 1'b1;
                if (rdf_inflight == 4'd0 && req_rem == 21'd0) begin
                    timer <= T_RTP;                // last data -> PRECHARGE
                    state <= S_FINISH;
                end else if (rd_gap == 4'd0 && req_rem != 21'd0) begin
                    if (ref_pending)
                        state <= S_REF_PRE;
                    else if (row_hit)
                        state <= S_RD_CMD;         // row still open
                    else
                        state <= S_PRE;            // row changed
                end
            end

            // ------------------------------ refresh between read bursts
            S_REF_PRE: begin
                // Wait until every in-flight capture has landed...
                if (rdf_inflight == 4'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b0;
                    dram_a[10] <= 1'b1;             // PRECHARGE ALL
                    open_valid <= 1'b0;
                    state <= S_REF_ACT; timer <= T_RP;
                end
            end
            S_REF_ACT: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    ref_pending <= 1'b0;
                    ref_cnt     <= 10'd0;
                    state <= S_REF_DONE; timer <= T_RFC;
                end else timer <= timer - 1'b1;
            end
            S_REF_DONE: begin
                if (timer == 16'd0)
                    state <= S_PRE;                // re-open the row
                else
                    timer <= timer - 1'b1;
            end

            // ----------------------------- refresh between write bursts
            S_WREF_PRE: begin
                // ...after tWR has elapsed (timer was set at burst end).
                if (timer != 16'd0) begin
                    timer <= timer - 1'b1;
                end else begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b0;
                    dram_a[10] <= 1'b1;             // PRECHARGE ALL
                    open_valid <= 1'b0;
                    wr_dirty   <= 1'b0;
                    state <= S_WREF_ACT; timer <= T_RP;
                end
            end
            S_WREF_ACT: begin
                if (timer == 16'd0) begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b0; dram_we_n <= 1'b1;
                    ref_pending <= 1'b0;
                    ref_cnt     <= 10'd0;
                    state <= S_WREF_DONE; timer <= T_RFC;
                end else timer <= timer - 1'b1;
            end
            S_WREF_DONE: begin
                if (timer == 16'd0)
                    state <= S_PRE;                // re-open the row
                else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------- end of request
            S_FINISH: begin
                // timer covers tWR (writes) or tRTP (reads) from the last
                // burst before the PRECHARGE.
                if (timer != 16'd0) begin
                    timer <= timer - 1'b1;
                end else begin
                    dram_ras_n <= 1'b0; dram_cas_n <= 1'b1; dram_we_n <= 1'b0;
                    dram_a[10] <= 1'b1;             // PRECHARGE ALL
                    open_valid <= 1'b0;
                    wr_dirty   <= 1'b0;
                    if (req_is_write) wr_busy_q <= 1'b0;
                    else              rd_busy_q <= 1'b0;
                    state <= S_FIN_WAIT; timer <= T_RP;
                end
            end
            S_FIN_WAIT: begin
                // Meet tRP so a refresh can be issued straight from idle.
                if (timer == 16'd0)
                    state <= S_IDLE;
                else
                    timer <= timer - 1'b1;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
