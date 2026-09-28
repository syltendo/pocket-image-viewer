// video_scanout.v
//
// 800x720 @ 60 Hz video scanout for the Analogue Pocket image viewer.
//
// Two clock domains:
//   mem_clk (99 MHz): SDRAM read client. Reads the selected slot's
//     framebuffer line by line (1600 words/line), packing word pairs into
//     32-bit FIFO entries {g,b,8'h00,r} -> pixel {r,g,b}.
//   vid_clk (39.6 MHz): 880x750 timing, 800x720 active. Pops one FIFO
//     entry per active pixel.
//
// Framebuffer layout (2 words per pixel):
//   word[2*i]   = {8'h00, r}
//   word[2*i+1] = {g, b}
//   slot base   = slot * 1152000 words; row dy = base + dy*1600
//
// Slots that were never successfully decoded (slot_valid=0) are not read
// at all; the video side shows black for them. Slot switches take effect
// at vblank: no tearing.

`default_nettype none

module video_scanout (
    // ---- mem_clk domain (99 MHz) ----
    input  wire        mem_clk,
    input  wire        mem_rst_n,

    // SDRAM read port (hold rd_req until rd_busy)
    output reg         rd_req,
    output reg [24:0]  rd_addr,
    output reg [15:0]  rd_len,
    input  wire        rd_busy,
    input  wire [15:0] rd_data,
    input  wire        rd_valid,
    output wire        rd_ready,

    // async control in (synchronized inside to mem_clk)
    input  wire [2:0]  display_slot,   // from navigation (clk_74a)
    input  wire [7:0]  slot_valid,     // from slot_mgr (clk_74a)
    input  wire        sdram_init_done, // from SDRAM controller (mem_clk)
    input  wire [4:0]  parser_state,    // DEBUG: parser FSM state (mem_clk)
    input  wire [31:0] diag_rd_burst,   // DEBUG: SDRAM READ bursts issued (mem_clk)
    input  wire [31:0] diag_rd_word,    // DEBUG: SDRAM words captured (mem_clk)
    input  wire [31:0] diag_wr_burst,   // DEBUG: SDRAM WRITE bursts issued (mem_clk)
    input  wire [31:0] diag_wr_word,    // DEBUG: SDRAM words written (mem_clk)

    // packed-pixel FIFO to vid_clk (mem_clk write side)
    output wire [31:0] pfifo_wr_data,
    output wire        pfifo_wr_en,
    input  wire        pfifo_wr_full,
    input  wire [11:0] pfifo_wr_level, // for read pacing

    // ---- vid_clk domain (39.6 MHz) ----
    input  wire        vid_clk,
    input  wire        vid_rst_n,
    input  wire [31:0] pfifo_rd_data,
    input  wire        pfifo_rd_empty,
    output wire        pfifo_rd_en,

    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_vs,
    output reg         video_hs,
    output wire        video_skip,
    output reg         underrun        // sticky: FIFO empty during active
);

    // ------------------------------------------------------ video timing
    localparam H_ACTIVE = 800, H_TOTAL = 880;   // hs: 808..871
    localparam V_ACTIVE = 720, V_TOTAL = 750;   // vs: 724..727

    // vblank toggle from the vid_clk side (declared here for use below)
    reg vblank_t_vid;

    // DEBUG: sync "slot invalid" flag to vid_clk for red-screen diagnostic.
    // When the parser rejects the header (slot_valid=0), the video shows
    // solid red instead of black, proving the video pipeline works.
    // Blue = SDRAM init not done, Red = init done but parser failed.
    reg slot_invalid_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n)
            slot_invalid_m <= 1'b1;
        else
            slot_invalid_m <= ~svalid_m2[dslot_m2];
    end
    reg init_done_v1, init_done_v2;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            init_done_v1 <= 1'b0;
            init_done_v2 <= 1'b0;
        end else begin
            init_done_v1 <= sdram_init_done;
            init_done_v2 <= init_done_v1;
        end
    end
    wire init_done_vid = init_done_v2;
    reg [4:0] pstate_v1, pstate_v2;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            pstate_v1 <= 5'd0;
            pstate_v2 <= 5'd0;
        end else begin
            pstate_v1 <= parser_state;
            pstate_v2 <= pstate_v1;
        end
    end
    wire [4:0] pstate_vid = pstate_v2;
    reg slot_invalid_v1, slot_invalid_v2;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            slot_invalid_v1 <= 1'b1;
            slot_invalid_v2 <= 1'b1;
        end else begin
            slot_invalid_v1 <= slot_invalid_m;
            slot_invalid_v2 <= slot_invalid_v1;
        end
    end
    wire slot_invalid_vid = slot_invalid_v2;

    // DEBUG: sync SDRAM read diagnostics to vid_clk for color diagnostic.
    // When slot_valid=1 but the FIFO is empty (black screen), these tell us
    // where the read path is broken:
    //   orange = no READ bursts issued (video not requesting / controller stuck)
    //   purple = READs issued but no data captured (capture timing wrong)
    //   white  = data captured but FIFO empty (FIFO/drain issue)
    reg rd_burst_m, rd_word_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            rd_burst_m <= 1'b0;
            rd_word_m  <= 1'b0;
        end else begin
            if (diag_rd_burst != 32'd0) rd_burst_m <= 1'b1;
            if (diag_rd_word  != 32'd0) rd_word_m  <= 1'b1;
        end
    end
    // DEBUG: did the SDRAM controller issue any WRITE bursts?
    reg wr_burst_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            wr_burst_m <= 1'b0;
        end else begin
            if (diag_wr_burst != 32'd0) wr_burst_m <= 1'b1;
        end
    end
    reg rd_burst_v1, rd_burst_v2, rd_word_v1, rd_word_v2;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            rd_burst_v1 <= 1'b0; rd_burst_v2 <= 1'b0;
            rd_word_v1  <= 1'b0; rd_word_v2  <= 1'b0;
        end else begin
            rd_burst_v1 <= rd_burst_m; rd_burst_v2 <= rd_burst_v1;
            rd_word_v1  <= rd_word_m;  rd_word_v2  <= rd_word_v1;
        end
    end
    wire rd_burst_vid = rd_burst_v2;
    wire rd_word_vid  = rd_word_v2;
    reg wr_burst_v1, wr_burst_v2;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            wr_burst_v1 <= 1'b0; wr_burst_v2 <= 1'b0;
        end else begin
            wr_burst_v1 <= wr_burst_m; wr_burst_v2 <= wr_burst_v1;
        end
    end
    wire wr_burst_vid = wr_burst_v2;

    // ------------------------------------------------- mem_clk: control sync
    reg [2:0] dslot_m1, dslot_m2;
    reg [7:0] svalid_m1, svalid_m2;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            dslot_m1 <= 3'd0; dslot_m2 <= 3'd0;
            svalid_m1 <= 8'd0; svalid_m2 <= 8'd0;
        end else begin
            dslot_m1 <= display_slot;  dslot_m2 <= dslot_m1;
            svalid_m1 <= slot_valid;   svalid_m2 <= svalid_m1;
        end
    end

    // frame-start pulse from vid_clk (toggle)
    reg vblank_t_v1, vblank_t_v2, vblank_t_v3;
    wire frame_start = vblank_t_v2 ^ vblank_t_v3;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            vblank_t_v1 <= 1'b0; vblank_t_v2 <= 1'b0; vblank_t_v3 <= 1'b0;
        end else begin
            vblank_t_v1 <= vblank_t_vid;
            vblank_t_v2 <= vblank_t_v1;
            vblank_t_v3 <= vblank_t_v2;
        end
    end

    // ------------------------------------------------- mem_clk: read client
    reg [2:0]  slot_cur;
    reg [9:0]  line;              // 0..719
    reg        rd_active;
    reg        frame_pending;

    // word-pair packing: {w1,w0} -> one 32-bit FIFO entry per pixel
    reg [15:0] pack_w0;
    reg        pack_have;
    reg [31:0] pack_data;
    reg        pack_wr;

    assign pfifo_wr_data = pack_data;
    assign pfifo_wr_en   = pack_wr;
    // accept an SDRAM word if we can pack it (need FIFO room only when
    // completing a pair)
    assign rd_ready = !pack_have || !pfifo_wr_full;

    wire slot_ok = svalid_m2[dslot_m2];

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            slot_cur <= 3'd0;
            line <= 10'd0;
            rd_active <= 1'b0;
            frame_pending <= 1'b0;
            rd_req <= 1'b0;
            rd_addr <= 25'd0;
            rd_len <= 16'd0;
            pack_have <= 1'b0;
            pack_w0 <= 16'd0;
            pack_data <= 32'd0;
            pack_wr <= 1'b0;
        end else begin
            pack_wr <= 1'b0;

            // pack incoming SDRAM words into pixels
            if (rd_valid && rd_ready) begin
                if (!pack_have) begin
                    pack_w0   <= rd_data;
                    pack_have <= 1'b1;
                end else begin
                    pack_data <= {rd_data, pack_w0}; // {g,b,8'h00,r}
                    pack_wr   <= 1'b1;
                    pack_have <= 1'b0;
                end
            end

            // frame start: latch the slot, restart at line 0
            if (frame_start) begin
                if (!rd_active && !rd_req) begin
                    slot_cur <= dslot_m2;
                    line     <= 10'd0;
                end else begin
                    frame_pending <= 1'b1;
                end
            end
            if (frame_pending && !rd_active && !rd_req) begin
                slot_cur      <= dslot_m2;
                line          <= 10'd0;
                frame_pending <= 1'b0;
            end

            // read one line at a time; pace so the FIFO never overflows
            // (rd_ready backpressure is the hard guarantee)
            if (!rd_active) begin
                if (!rd_req) begin
                    if (slot_ok && (line < 10'd720) &&
                        (pfifo_wr_level < 12'd3072)) begin
                        rd_req  <= 1'b1;
                        rd_addr <= (slot_cur * 25'd1152000) + (line * 11'd1600);
                        rd_len  <= 16'd1600;
                    end
                end else if (rd_busy) begin
                    rd_req    <= 1'b0;
                    rd_active <= 1'b1;
                end
            end else begin
                if (!rd_busy) begin
                    rd_active <= 1'b0;
                    line      <= line + 10'd1;
                end
            end
        end
    end

    // ------------------------------------------------- vid_clk: timing
    reg [9:0] hpos;   // 0..879
    reg [9:0] vpos;   // 0..749
    reg       active;
    reg       rd_en_q;
    reg       vs_q, hs_q, de_q;
    reg [23:0] rgb_q;

    assign pfifo_rd_en = rd_en_q;
    assign video_skip  = 1'b0;

    reg in_vblank;

    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            hpos <= 10'd0;
            vpos <= 10'd0;
            active <= 1'b0;
            rd_en_q <= 1'b0;
            rgb_q <= 24'd0;
            video_rgb <= 24'd0;
            video_de <= 1'b0;
            video_vs <= 1'b0;
            video_hs <= 1'b0;
            vs_q <= 1'b0; hs_q <= 1'b0; de_q <= 1'b0;
            underrun <= 1'b0;
            vblank_t_vid <= 1'b0;
            in_vblank <= 1'b1;
        end else begin
            // counters
            if (hpos == H_TOTAL - 1) begin
                hpos <= 10'd0;
                if (vpos == V_TOTAL - 1)
                    vpos <= 10'd0;
                else
                    vpos <= vpos + 10'd1;
            end else begin
                hpos <= hpos + 10'd1;
            end

            active <= (hpos < H_ACTIVE) && (vpos < V_ACTIVE);

            // FIFO pop: one entry per active pixel; data valid next cycle.
            // rd_en_q doubles as the "data valid next cycle" flag.
            rd_en_q <= (hpos < H_ACTIVE) && (vpos < V_ACTIVE) && !pfifo_rd_empty;
            if (rd_en_q) begin
                // DEBUG: if FIFO data is all zeros and slot is valid, the
                // SDRAM returned zeros. Distinguish "no writes happened"
                // (dark red) from "writes happened but data lost" (black).
                if ({pfifo_rd_data[7:0], pfifo_rd_data[31:24],
                     pfifo_rd_data[23:16]} == 24'd0 &&
                    init_done_vid && !slot_invalid_vid)
                    rgb_q <= wr_burst_vid ? 24'h000000 : 24'h800000;
                else
                    rgb_q <= {pfifo_rd_data[7:0], pfifo_rd_data[31:24],
                              pfifo_rd_data[23:16]};
            end else begin
                // DEBUG colors: blue=SDRAM init stuck, cyan=parser idle,
                // yellow=header, magenta=divider, green=geom/pixel/SDRAM write, red=failed
                if (!init_done_vid)
                    rgb_q <= 24'h0000FF;  // blue: SDRAM init not done
                else if (pstate_vid == 5'd0)
                    rgb_q <= 24'h00FFFF;  // cyan: parser in IDLE (no start)
                else if (pstate_vid == 5'd4)
                    rgb_q <= 24'hFFFF00;  // yellow: parser in HDR (reading header)
                else if (pstate_vid >= 5'd5 && pstate_vid <= 5'd7)
                    rgb_q <= 24'hFF00FF;  // magenta: parser in DIV (divider wait)
                else if ((pstate_vid >= 5'd8 && pstate_vid <= 5'd23) || pstate_vid == 5'd25)
                    rgb_q <= 24'h00FF00;  // green: parser in GEOM/pixel/SDRAM write
                else if (slot_invalid_vid)
                    rgb_q <= 24'hFF0000;  // red: parser failed
                else if (!rd_burst_vid)
                    rgb_q <= 24'hFF8000;  // orange: no SDRAM READs issued
                else if (!rd_word_vid)
                    rgb_q <= 24'h8000FF;  // purple: READs issued, no data captured
                else
                    rgb_q <= 24'hFFFFFF;  // white: data captured but FIFO empty
            end

            // underrun: wanted a pixel but the FIFO was empty
            if (active && pfifo_rd_empty)
                underrun <= 1'b1;

            // vblank toggle: entering vblank (first blank line)
            if (vpos == V_ACTIVE && hpos == 10'd0 && !in_vblank) begin
                vblank_t_vid <= ~vblank_t_vid;
                in_vblank <= 1'b1;
            end else if (vpos == 10'd0 && hpos == 10'd0) begin
                in_vblank <= 1'b0;
            end

            // registered outputs (1-cycle delayed data path)
            video_rgb <= rgb_q;
            video_de  <= de_q;
            video_vs  <= vs_q;
            video_hs  <= hs_q;
            de_q <= active;
            vs_q <= (vpos >= 724 && vpos < 728);
            hs_q <= (hpos >= 808 && hpos < 872);
        end
    end

endmodule
