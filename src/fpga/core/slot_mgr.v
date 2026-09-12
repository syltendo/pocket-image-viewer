// slot_mgr.v
//
// Manages the 8 image data slots.
//
// Bridge side (clk = clk_74a):
//   - Watches dataslot_requestwrite from core_bridge_cmd. In that module
//     the signal stays high only while the 0x0082 command is being
//     processed, and the host blocks until we raise
//     dataslot_requestwrite_ack. We ACK IMMEDIATELY (ok=1 for valid
//     requests) so the bridge never wedges: the host's command handler
//     is single-threaded, and any delay here (e.g. waiting on SDRAM)
//     makes the Pocket report "Target not responding". The parser runs
//     in the background; the input FIFO absorbs the host stream while
//     the parser clears the framebuffer.
//   - While a transfer is active, 32-bit bridge writes to the slot's
//     declared address window (data.json: 0x1n000000 for slot n) are pushed
//     into the parser's input FIFO, in order. The byte count from [0082]
//     determines when the stream ends.
//   - A new request arriving while the parser is still decoding is
//     latched as pending and started when the parser finishes.
//
// Parser side (mem_clk = 99 MHz): emits a 1-cycle start pulse plus stable
// parameters; collects ready/done/op_valid. All CDC is handled inside
// this module (toggle pulses for events, 2FF for stable levels).

`default_nettype none

module slot_mgr (
    // ---- bridge clock domain ----
    input  wire        clk,                        // clk_74a
    input  wire        rst_n,

    // from core_bridge_cmd
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,  // bytes
    input  wire        dataslot_allcomplete,        // informational
    output reg         dataslot_requestwrite_ack,
    output reg         dataslot_requestwrite_ok,

    // bridge stream
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,

    // to parser input FIFO (clk side)
    output wire [31:0] fifo_wr_data,
    output wire        fifo_wr_en,
    input  wire        fifo_wr_full,

    // ---- parser clock domain ----
    input  wire        mem_clk,                    // 99 MHz
    input  wire        mem_rst_n,
    output reg         ps_start,                   // 1-cycle pulse
    output reg  [2:0]  ps_slot_id,                 // stable while busy
    output reg  [21:0] ps_total_words,
    output reg  [1:0]  ps_last_valid,
    output reg         ps_clear_only,
    input  wire        ps_ready,                   // parser: clear done
    input  wire        ps_done,                    // parser: 1-cycle pulse
    input  wire        ps_op_valid,

    // ---- status ----
    output reg  [7:0]  slot_valid,                 // bit per slot
    output wire        busy,
    output reg         fifo_overflow               // sticky debug flag
);

    // ------------------------------------------------------------ states
    // NOTE: ST_PREP is retired. We ACK immediately on request (see header);
    // the parser clear/decode runs in the background. Kept as a state
    // encoding for clarity but never entered.
    localparam ST_IDLE   = 3'd0,
               ST_PREP   = 3'd1,   // (unused) was: wait for parser ready
               ST_ACK    = 3'd2,   // ack held until the host moves on
               ST_STREAM = 3'd3,   // routing bridge writes to the FIFO
               ST_REJECT = 3'd4;   // bad id/size: ack with ok=0

    reg [2:0] state;

    // current transfer
    reg [2:0]  cur_slot;
    // pending request latched on req_rise (host serializes on our ACK,
    // so at most one can be pending)
    reg        pending;
    reg [2:0]  pend_slot;
    reg [21:0] pend_words;         // ceil(size/4)
    reg [1:0]  pend_last;          // size[1:0]: valid bytes in last word
    reg        pend_bad;           // id > 7 or size == 0

    // params to mem_clk domain (stable from PREP until next PREP)
    reg [2:0]  pm_slot;
    reg [21:0] pm_words;
    reg [1:0]  pm_last;
    reg        pm_start_t;         // toggle

    reg req_1;
    wire req_rise = dataslot_requestwrite && !req_1;

    // parser status synced back to clk
    reg ready_c1, ready_c2;
    reg done_t_c1, done_t_c2, done_t_c3;
    reg opv_c1, opv_c2;
    wire ready_s    = ready_c2;
    wire done_pulse = done_t_c2 ^ done_t_c3;

    assign busy = (state != ST_IDLE);
    assign fifo_wr_data = bridge_wr_data;
    // During an active transfer, the host streams slot data to the slot's
    // declared address window (data.json: 0x1n000000 for slot n, i.e.
    // bridge_addr[31:24] == 8'h10 + n). Decode for robustness.
    wire route = (state == ST_STREAM) && bridge_wr &&
                 (bridge_addr[31:24] == (8'h10 + {5'd0, cur_slot})) &&
                 !fifo_wr_full;
    assign fifo_wr_en = route;

    // start the parser for the pending request (shared by ST_IDLE)
    // NOTE: called only when pending==1; clears pending.
    // ACKs immediately: the parser start toggle is issued here, but we do
    // NOT wait for the parser. The host streams into the FIFO while the
    // parser clears/decodes in the background.
    task start_pending;
    begin
        pending <= 1'b0;
        if (pend_bad) begin
            state <= ST_REJECT;
        end else begin
            cur_slot    <= pend_slot;
            pm_slot     <= pend_slot;
            pm_words    <= pend_words;
            pm_last     <= pend_last;
            pm_start_t  <= ~pm_start_t;
            slot_valid[pend_slot] <= 1'b0;   // cleared until decoded
            // immediate ACK: don't wait for SDRAM/parser
            dataslot_requestwrite_ack <= 1'b1;
            dataslot_requestwrite_ok  <= 1'b1;
            state <= ST_ACK;
        end
    end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            dataslot_requestwrite_ack <= 1'b0;
            dataslot_requestwrite_ok  <= 1'b0;
            slot_valid <= 8'd0;
            fifo_overflow <= 1'b0;
            pending <= 1'b0;
            pend_bad <= 1'b0;
            req_1 <= 1'b0;
            pm_start_t <= 1'b0;
            ready_c1 <= 1'b0; ready_c2 <= 1'b0;
            done_t_c1 <= 1'b0; done_t_c2 <= 1'b0; done_t_c3 <= 1'b0;
            opv_c1 <= 1'b0; opv_c2 <= 1'b0;
        end else begin
            req_1 <= dataslot_requestwrite;

            // synchronizers from mem_clk
            ready_c1 <= rdy_m1;  ready_c2 <= ready_c1;
            opv_c1   <= opv_m1;  opv_c2   <= opv_c1;
            done_t_c1 <= done_t_mem; done_t_c2 <= done_t_c1; done_t_c3 <= done_t_c2;

            // latch newly arriving requests (host serializes on our ACK)
            if (req_rise && !pending) begin
                pend_slot  <= dataslot_requestwrite_id[2:0];
                pend_words <= (dataslot_requestwrite_size + 32'd3) >> 2;
                pend_last  <= dataslot_requestwrite_size[1:0];
                pend_bad   <= (dataslot_requestwrite_id > 16'd7) ||
                              (dataslot_requestwrite_size == 32'd0);
                pending    <= 1'b1;
            end

            // sticky overflow debug (should never happen)
            if (route && fifo_wr_full)
                fifo_overflow <= 1'b1;

            case (state)
            ST_IDLE: begin
                if (pending)
                    start_pending;
            end
            // ST_PREP retired: ACK is immediate, parser runs in background.
            ST_ACK: begin
                if (!dataslot_requestwrite) begin
                    dataslot_requestwrite_ack <= 1'b0;
                    dataslot_requestwrite_ok  <= 1'b0;
                    state <= ST_STREAM;
                end
            end
            ST_STREAM: begin
                if (done_pulse) begin
                    slot_valid[cur_slot] <= opv_c2;
                    state <= ST_IDLE;   // pending (if any) starts next cycle
                end
            end
            ST_REJECT: begin
                dataslot_requestwrite_ack <= 1'b1;
                dataslot_requestwrite_ok  <= 1'b0;
                if (!dataslot_requestwrite) begin
                    dataslot_requestwrite_ack <= 1'b0;
                    state <= ST_IDLE;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end

    // ------------------------------------------------- mem_clk side
    // start toggle -> mem_clk
    reg st_t1, st_t2, st_t3;
    // params -> mem_clk (stable while busy)
    reg [2:0]  pm_slot_m1, pm_slot_m2;
    reg [21:0] pm_words_m1, pm_words_m2;
    reg [1:0]  pm_last_m1, pm_last_m2;
    // parser status -> clk
    reg        done_t_mem;
    reg        rdy_m1, opv_m1;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            st_t1 <= 1'b0; st_t2 <= 1'b0; st_t3 <= 1'b0;
            pm_slot_m1 <= 3'd0; pm_slot_m2 <= 3'd0;
            pm_words_m1 <= 22'd0; pm_words_m2 <= 22'd0;
            pm_last_m1 <= 2'd0; pm_last_m2 <= 2'd0;
            ps_start <= 1'b0;
            ps_slot_id <= 3'd0;
            ps_total_words <= 22'd0;
            ps_last_valid <= 2'd0;
            ps_clear_only <= 1'b0;
            done_t_mem <= 1'b0;
            rdy_m1 <= 1'b0;
            opv_m1 <= 1'b0;
        end else begin
            st_t1 <= pm_start_t;
            st_t2 <= st_t1;
            st_t3 <= st_t2;
            pm_slot_m1 <= pm_slot;    pm_slot_m2 <= pm_slot_m1;
            pm_words_m1 <= pm_words;  pm_words_m2 <= pm_words_m1;
            pm_last_m1 <= pm_last;    pm_last_m2 <= pm_last_m1;

            if (st_t2 ^ st_t3) begin
                ps_start       <= 1'b1;
                ps_slot_id     <= pm_slot_m2;
                ps_total_words <= pm_words_m2;
                ps_last_valid  <= pm_last_m2;
                ps_clear_only  <= 1'b0;
            end else begin
                ps_start <= 1'b0;
            end

            if (ps_done)
                done_t_mem <= ~done_t_mem;
            rdy_m1 <= ps_ready;
            opv_m1 <= ps_op_valid;
        end
    end

endmodule
