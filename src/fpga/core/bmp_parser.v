// bmp_parser.v
//
// Decodes a 24-bit uncompressed BMP stream straight into an SDRAM
// framebuffer, with scale-to-fit (aspect preserved, letterboxed).
//
// Clock: 99 MHz (same as sdram_ctrl). One pass, no intermediate storage
// except a single 800-pixel line buffer.
//
// Byte order: the APF bridge delivers each 32-bit word big-endian, i.e.
// the first file byte is in bits [31:24] (this matches the 'CM' command
// word convention used by core_bridge_cmd with bridge_endian_little=0).
//
// Framebuffer layout per slot (32-bit XRGB per pixel = 2 SDRAM words):
//   word[2*i]   = {8'h00, r}
//   word[2*i+1] = {g, b}
//   slot base   = slot_id * 1152000 words  (800*720*2)
//   row dy      = slot_base + dy*1600
//
// Operation:
//   start pulse -> clear the slot's framebuffer -> ready goes high
//   (the slot manager only then ACKs the host, so no input can arrive
//   during the clear) -> parse header -> decode rows -> done pulse.
//   clear_only=1 skips the decode (used to blank a slot).
//
// A truncated stream still finishes: whatever decoded so far stays on
// screen, the rest remains black from the clear. op_valid=1 iff the BMP
// header was accepted (even if pixel data was truncated).

`default_nettype none

module bmp_parser (
    input  wire        clk,
    input  wire        rst_n,              // synchronous, active low

    // ---- control (all synchronous to clk; CDC is done outside) ----
    input  wire        start,              // 1-cycle pulse
    input  wire [2:0]  slot_id,            // stable while busy
    input  wire [21:0] total_words,       // ceil(file_size/4), >= 1
    input  wire [1:0]  last_valid,        // valid bytes in last word (0 = 4)
    input  wire        clear_only,        // 1: clear framebuffer, then done
    input  wire        sdram_init_done,
    output reg         ready,              // 1: clear done, stream may flow
    output reg         idle,               // 1: no operation in progress
    output reg         done,               // 1-cycle pulse
    output reg         op_valid,           // valid together with done

    // ---- word stream in (MSB-first bytes) ----
    input  wire [31:0] fifo_data,
    input  wire        fifo_empty,
    output reg         fifo_rd,

    // ---- SDRAM write port (hold wr_req until wr_busy) ----
    output reg         wr_req,
    output reg [24:0]  wr_addr,
    output reg [20:0]  wr_len,
    input  wire        wr_busy,
    output reg [15:0]  wr_data,
    output reg         wr_valid,
    input  wire        wr_ready
);

    // ---------------------------------------------------------- constants
    localparam FB_W         = 800;
    localparam FB_H         = 720;
    localparam WORDS_PER_ROW = 1600;       // 800 px * 2 words
    localparam FB_WORDS     = 1152000;     // 800*720*2
    localparam SLOT_WORDS   = 1152000;

    // ---------------------------------------------------------------- states
    localparam S_IDLE        = 5'd0,
               S_CLEAR_REQ   = 5'd1,
               S_CLEAR_STREAM= 5'd2,
               S_CLEAR_WAIT  = 5'd3,
               S_HDR         = 5'd4,
               S_DIV0        = 5'd5,
               S_DIV0W       = 5'd6,
               S_DIV1W       = 5'd7,
               S_GEOM        = 5'd8,
               S_SKIP        = 5'd9,
               S_ROWINIT     = 5'd10,
               S_ROWINIT2    = 5'd25,
               S_PIXEL       = 5'd11,
               S_FILL        = 5'd12,
               S_PIXELNEXT   = 5'd13,
               S_PAD         = 5'd14,
               S_SKIPROW     = 5'd15,
               S_WROW_REQ    = 5'd16,
               S_WS_READ     = 5'd17,
               S_WS_W0       = 5'd18,
               S_WS_W1       = 5'd19,
               S_WROW_WAIT   = 5'd20,
               S_ROWNEXT     = 5'd21,
               S_DRAIN       = 5'd22,
               S_FINISH      = 5'd23,
               S_FETCH       = 5'd24;

    reg [4:0] state, ret_state;

    // ------------------------------------------------------- latched params
    reg [2:0]  slot_id_q;
    reg [21:0] total_words_q;
    reg [1:0]  last_valid_q;
    reg        clear_only_q;
    reg [24:0] slot_base;

    // ------------------------------------------------------- byte pump
    // 32-bit words arrive MSB-first; bytes are shifted out of `shifter`.
    reg [31:0] shifter;
    reg [2:0]  sh_avail;                  // 0..4 bytes available
    reg [21:0] words_consumed;
    wire [2:0] last_valid_nz = (last_valid_q == 2'd0) ? 3'd4 : {1'b0, last_valid_q};
    wire       no_more_data  = (words_consumed == total_words_q) && (sh_avail == 3'd0);
    wire [7:0] cur_byte      = shifter[31:24];

    // ------------------------------------------------------- header fields
    reg [5:0]  hdr_cnt;
    reg [7:0]  magic0, magic1;
    reg [31:0] bf_off_bits;
    reg [31:0] bi_width;
    reg [31:0] bi_height;
    reg [15:0] bi_planes;
    reg [15:0] bi_bpp;
    reg [31:0] bi_comp;
    wire [31:0] abs_h = bi_height[31] ? (~bi_height + 32'd1) : bi_height;

    // ------------------------------------------------------- geometry
    reg [12:0] img_w, img_h;              // 1..8192
    reg        top_down;
    reg [31:0] stride;                    // source bytes per row (padded)
    reg [31:0] skip_left;
    reg        header_ok;
    reg [25:0] scale;                     // 16.16 fixed point
    reg [25:0] q0, q1;
    reg [9:0]  dst_w, dst_h;              // <= 800 / <= 720, nonzero
    reg [9:0]  x0, y0;                    // letterbox offsets

    // ------------------------------------------------------- decode position
    reg [12:0] row;                       // file row 0..H-1
    reg [12:0] col;                       // source col 0..W-1
    reg [1:0]  px_byte;                   // 0..2 within pixel (B,G,R)
    reg [23:0] px;                        // assembled pixel {R,G,B}
    reg [12:0] src_row;                   // image row (0 = top)
    reg [9:0]  dy0, dy1, dy;              // dest rows for this source row
    reg [9:0]  k;                         // fill cursor into linebuf
    reg [9:0]  i;                         // word-stream cursor 0..799
    reg [20:0] wcount;                    // words accepted (clear)
    reg [31:0] pad_left;
    reg [23:0] px_w;                      // pixel being written (2 words)

    // scale multiplies (13b x 26b). The results used are < 800 / < 720,
    // so bits [25:16] carry the value; the 11-bit sums cannot overflow
    // past 800/720 (see derivation in docs/architecture.md).
    wire [38:0] mul_c0 = col * scale;
    wire [38:0] mul_c1 = (col + 13'd1) * scale;
    wire [38:0] mul_r0 = src_row * scale;
    wire [38:0] mul_r1 = (src_row + 13'd1) * scale;
    wire [10:0] c_dx0 = {1'b0, x0} + mul_c0[25:16];
    wire [10:0] c_dx1 = {1'b0, x0} + mul_c1[25:16];
    wire [10:0] c_dy0 = {1'b0, y0} + mul_r0[25:16];
    wire [10:0] c_dy1 = {1'b0, y0} + mul_r1[25:16];

    // ------------------------------------------------------- line buffer
    // 800 x 24 block RAM, true dual port (write: fill, read: row write).
    reg [23:0] linebuf [0:799];
    reg [9:0]  lb_waddr, lb_raddr;
    reg [23:0] lb_wdata;
    reg        lb_we;
    reg [23:0] lb_q;
    always @(posedge clk) begin
        if (lb_we)
            linebuf[lb_waddr] <= lb_wdata;
        lb_q <= linebuf[lb_raddr];
    end

    // ------------------------------------------------------- divider
    reg [31:0] div_num;
    reg [12:0] div_den;
    reg        div_start;
    wire       div_done;
    wire [31:0] div_q;
    seq_divider div_inst (
        .clk(clk), .reset_n(rst_n),
        .start(div_start),
        .num(div_num), .den({19'b0, div_den}),
        .done(div_done), .q(div_q)
    );

    // temporaries for S_GEOM (blocking)
    reg [25:0] t_scale;
    reg [9:0]  t_dstw, t_dsth;

    // ------------------------------------------------------- main FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            idle      <= 1'b1;
            ready     <= 1'b0;
            done      <= 1'b0;
            op_valid  <= 1'b0;
            wr_req    <= 1'b0;
            wr_valid  <= 1'b0;
            fifo_rd   <= 1'b0;
            div_start <= 1'b0;
            lb_we     <= 1'b0;
        end else begin
            done      <= 1'b0;
            fifo_rd   <= 1'b0;
            div_start <= 1'b0;
            lb_we     <= 1'b0;
            wr_valid  <= 1'b0;

            case (state)

            // -------------------------------------------------- idle
            S_IDLE: begin
                idle <= 1'b1;
                ready <= 1'b0;
                if (start && sdram_init_done) begin
                    slot_id_q    <= slot_id;
                    total_words_q<= total_words;
                    last_valid_q <= last_valid;
                    clear_only_q <= clear_only;
                    slot_base    <= slot_id * 25'd1152000;
                    words_consumed <= 22'd0;
                    sh_avail     <= 3'd0;
                    header_ok    <= 1'b0;
                    idle         <= 1'b0;
                    state        <= S_CLEAR_REQ;
                end
            end

            // ------------------------------------ clear the framebuffer
            S_CLEAR_REQ: begin
                wr_req  <= 1'b1;
                wr_addr <= slot_base;
                wr_len  <= 21'd1152000;
                if (wr_busy) begin
                    wr_req <= 1'b0;
                    wcount <= 21'd0;
                    state  <= S_CLEAR_STREAM;
                end
            end
            S_CLEAR_STREAM: begin
                wr_valid <= 1'b1;
                wr_data  <= 16'd0;
                if (wr_ready) begin
                    if (wcount == 21'd1151999)
                        state <= S_CLEAR_WAIT;
                    wcount <= wcount + 21'd1;
                end
            end
            S_CLEAR_WAIT: begin
                if (!wr_busy) begin
                    ready <= 1'b1;
                    if (clear_only_q) begin
                        state <= S_FINISH;
                    end else begin
                        hdr_cnt <= 6'd0;
                        state   <= S_HDR;
                    end
                end
            end

            // ------------------------------------------ header (54 bytes)
            S_HDR: begin
                if (no_more_data) begin
                    state <= S_FINISH;             // truncated: no header
                end else if (sh_avail != 3'd0) begin
                    case (hdr_cnt)
                        6'd0:  magic0 <= cur_byte;
                        6'd1:  magic1 <= cur_byte;
                        6'd10: bf_off_bits[7:0]   <= cur_byte;
                        6'd11: bf_off_bits[15:8]  <= cur_byte;
                        6'd12: bf_off_bits[23:16] <= cur_byte;
                        6'd13: bf_off_bits[31:24] <= cur_byte;
                        6'd18: bi_width[7:0]      <= cur_byte;
                        6'd19: bi_width[15:8]     <= cur_byte;
                        6'd20: bi_width[23:16]    <= cur_byte;
                        6'd21: bi_width[31:24]    <= cur_byte;
                        6'd22: bi_height[7:0]     <= cur_byte;
                        6'd23: bi_height[15:8]    <= cur_byte;
                        6'd24: bi_height[23:16]   <= cur_byte;
                        6'd25: bi_height[31:24]   <= cur_byte;
                        6'd26: bi_planes[7:0]     <= cur_byte;
                        6'd27: bi_planes[15:8]    <= cur_byte;
                        6'd28: bi_bpp[7:0]        <= cur_byte;
                        6'd29: bi_bpp[15:8]       <= cur_byte;
                        6'd30: bi_comp[7:0]       <= cur_byte;
                        6'd31: bi_comp[15:8]      <= cur_byte;
                        6'd32: bi_comp[23:16]     <= cur_byte;
                        6'd33: bi_comp[31:24]     <= cur_byte;
                    endcase
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                    if (hdr_cnt == 6'd53) begin
                        // ---- validate ----
                        if (magic0 != 8'h42 || magic1 != 8'h4D ||
                            bi_planes != 16'd1 || bi_bpp != 16'd24 ||
                            bi_comp != 32'd0 ||
                            bi_width < 32'd1 || bi_width > 32'd8192 ||
                            abs_h < 32'd1 || abs_h > 32'd8192 ||
                            bf_off_bits < 32'd54 ||
                            bf_off_bits > {total_words_q, 2'b00}) begin
                            state <= S_DRAIN;      // bad header: swallow file
                        end else begin
                            header_ok <= 1'b1;
                            img_w     <= bi_width[12:0];
                            img_h     <= abs_h[12:0];
                            top_down  <= bi_height[31];
                            stride    <= ((bi_width[12:0] * 13'd3 + 2'd3) & ~32'd3);
                            div_num   <= 32'd800 << 16;
                            div_den   <= bi_width[12:0];
                            div_start <= 1'b1;
                            state     <= S_DIV0W;
                        end
                    end else begin
                        hdr_cnt <= hdr_cnt + 6'd1;
                    end
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_HDR;
                    state     <= S_FETCH;
                end
            end

            // ------------------------------- scale = min(800/W, 720/H)
            S_DIV0W: begin
                if (div_done) begin
                    q0        <= div_q[25:0];
                    div_num   <= 32'd720 << 16;
                    div_den   <= img_h;
                    div_start <= 1'b1;
                    state     <= S_DIV1W;
                end
            end
            S_DIV1W: begin
                if (div_done) begin
                    q1    <= div_q[25:0];
                    state <= S_GEOM;
                end
            end
            S_GEOM: begin
                t_scale = (q0 <= q1) ? q0 : q1;
                t_dstw  = (img_w * t_scale) >> 16;
                t_dsth  = (img_h * t_scale) >> 16;
                if (t_dstw == 10'd0 || t_dsth == 10'd0) begin
                    header_ok <= 1'b0;             // degenerate
                    state     <= S_DRAIN;
                end else begin
                    scale <= t_scale;
                    dst_w <= t_dstw;
                    dst_h <= t_dsth;
                    x0    <= (10'd800 - t_dstw) >> 1;
                    y0    <= (10'd720 - t_dsth) >> 1;
                    row   <= 13'd0;
                    if (bf_off_bits == 32'd54) begin
                        state <= S_ROWINIT;
                    end else begin
                        skip_left <= bf_off_bits - 32'd54;
                        state     <= S_SKIP;
                    end
                end
            end

            // --------------------------------- skip to pixel array
            S_SKIP: begin
                if (no_more_data) begin
                    state <= S_FINISH;
                end else if (sh_avail != 3'd0) begin
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                    if (skip_left == 32'd1)
                        state <= S_ROWINIT;
                    skip_left <= skip_left - 32'd1;
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_SKIP;
                    state     <= S_FETCH;
                end
            end

            // --------------------------------- next source row
            S_ROWINIT: begin
                if (row == img_h) begin
                    state <= S_DRAIN;
                end else begin
                    // NOTE: c_dy0/c_dy1 use src_row, which settles next
                    // cycle; the row geometry is latched in S_ROWINIT2.
                    src_row <= top_down ? row : (img_h - 13'd1 - row);
                    col     <= 13'd0;
                    px_byte <= 2'd0;
                    state   <= S_ROWINIT2;
                end
            end
            S_ROWINIT2: begin
                dy0 <= c_dy0[9:0];
                dy1 <= c_dy1[9:0];
                if (c_dy0 == c_dy1) begin
                    // this source row maps to no dest rows: skip it
                    pad_left <= stride;
                    state    <= S_SKIPROW;
                end else begin
                    state <= S_PIXEL;
                end
            end

            // --------------------------------- pixel bytes (B,G,R)
            S_PIXEL: begin
                if (no_more_data) begin
                    state <= S_FINISH;
                end else if (sh_avail != 3'd0) begin
                    case (px_byte)
                        2'd0: px[7:0]   <= cur_byte;
                        2'd1: px[15:8]  <= cur_byte;
                        2'd2: px[23:16] <= cur_byte;
                    endcase
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                    if (px_byte == 2'd2) begin
                        // fill linebuf[c_dx0 .. c_dx1)
                        if (c_dx0 == c_dx1) begin
                            state <= S_PIXELNEXT;  // downscaled away
                        end else begin
                            k     <= c_dx0[9:0];
                            state <= S_FILL;
                        end
                        px_byte <= 2'd0;
                    end else begin
                        px_byte <= px_byte + 2'd1;
                    end
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_PIXEL;
                    state     <= S_FETCH;
                end
            end

            // --------------------------------- fill dest span
            S_FILL: begin
                lb_we    <= 1'b1;
                lb_waddr <= k;
                lb_wdata <= px;
                if (k + 10'd1 == c_dx1) begin
                    state <= S_PIXELNEXT;
                end else begin
                    k <= k + 10'd1;
                end
            end
            S_PIXELNEXT: begin
                if (col + 13'd1 == img_w) begin
                    pad_left <= stride - (img_w * 13'd3);
                    state    <= (stride == img_w * 13'd3) ? S_WROW_REQ : S_PAD;
                    // NOTE: S_WROW_REQ needs dy; set below via dy<=dy0
                    dy       <= dy0;
                end else begin
                    col     <= col + 13'd1;
                    px_byte <= 2'd0;
                    state   <= S_PIXEL;
                end
            end

            // --------------------------------- row padding
            S_PAD: begin
                if (no_more_data) begin
                    state <= S_FINISH;
                end else if (sh_avail != 3'd0) begin
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                    if (pad_left == 32'd1) begin
                        dy    <= dy0;
                        state <= S_WROW_REQ;
                    end
                    pad_left <= pad_left - 32'd1;
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_PAD;
                    state     <= S_FETCH;
                end
            end

            // --------------------------------- skip a downscaled-away row
            S_SKIPROW: begin
                if (no_more_data) begin
                    state <= S_FINISH;
                end else if (sh_avail != 3'd0) begin
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                    if (pad_left == 32'd1)
                        state <= S_ROWNEXT;
                    pad_left <= pad_left - 32'd1;
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_SKIPROW;
                    state     <= S_FETCH;
                end
            end

            // --------------------------------- write dest rows to SDRAM
            S_WROW_REQ: begin
                wr_req  <= 1'b1;
                wr_addr <= slot_base + (dy * 11'd1600);
                wr_len  <= 21'd1600;
                if (wr_busy) begin
                    wr_req <= 1'b0;
                    i      <= 10'd0;
                    state  <= S_WS_READ;
                end
            end
            S_WS_READ: begin
                lb_raddr <= i;
                state    <= S_WS_W0;
            end
            S_WS_W0: begin
                px_w     <= lb_q;
                wr_data  <= {8'h00, lb_q[23:16]};
                wr_valid <= 1'b1;
                if (wr_ready)
                    state <= S_WS_W1;
            end
            S_WS_W1: begin
                wr_data  <= {px_w[15:8], px_w[7:0]};
                wr_valid <= 1'b1;
                if (wr_ready) begin
                    if (i == 10'd799) begin
                        state <= S_WROW_WAIT;
                    end else begin
                        i     <= i + 10'd1;
                        state <= S_WS_READ;
                    end
                end
            end
            S_WROW_WAIT: begin
                if (!wr_busy) begin
                    if (dy + 10'd1 == dy1) begin
                        state <= S_ROWNEXT;
                    end else begin
                        dy    <= dy + 10'd1;
                        state <= S_WROW_REQ;
                    end
                end
            end
            S_ROWNEXT: begin
                row   <= row + 13'd1;
                state <= S_ROWINIT;
            end

            // --------------------------------- swallow trailing bytes
            S_DRAIN: begin
                if (no_more_data) begin
                    state <= S_FINISH;
                end else if (sh_avail != 3'd0) begin
                    shifter  <= {shifter[23:0], 8'd0};
                    sh_avail <= sh_avail - 3'd1;
                end else if (!fifo_empty) begin
                    fifo_rd   <= 1'b1;
                    ret_state <= S_DRAIN;
                    state     <= S_FETCH;
                end
            end

            // --------------------------------- shared FIFO word fetch
            // (1-cycle read latency: fifo_data is valid in this state)
            S_FETCH: begin
                shifter        <= fifo_data;
                words_consumed <= words_consumed + 22'd1;
                sh_avail       <= ((words_consumed + 22'd1) == total_words_q)
                                  ? last_valid_nz : 3'd4;
                state          <= ret_state;
            end

            // -------------------------------------------------- finish
            S_FINISH: begin
                done     <= 1'b1;
                op_valid <= header_ok;
                ready    <= 1'b0;
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// ---------------------------------------------------------------------------
// seq_divider: 32-bit restoring divider, start/done handshake (~34 cycles).
// Denominator of 0 is treated as 1.
module seq_divider (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,
    input  wire [31:0] num,
    input  wire [31:0] den,
    output reg         done,
    output reg  [31:0] q
);
    reg [31:0] n_s;
    reg [31:0] d_s;
    reg [32:0] rem;
    reg [31:0] quo;
    reg [5:0]  bit_;
    reg        busy;

    always @(posedge clk) begin
        if (!reset_n) begin
            busy <= 1'b0; done <= 1'b0; q <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                n_s  <= num;
                d_s  <= den == 32'd0 ? 32'd1 : den;
                rem  <= 33'd0;
                quo  <= 32'd0;
                bit_ <= 6'd32;
            end else if (busy) begin
                if (bit_ == 6'd0) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    q    <= quo;
                end else begin
                    bit_ <= bit_ - 6'd1;
                    if ({rem[31:0], n_s[31]} >= d_s) begin
                        rem <= {rem[31:0], n_s[31]} - d_s;
                        quo <= {quo[30:0], 1'b1};
                    end else begin
                        rem <= {rem[31:0], n_s[31]};
                        quo <= {quo[30:0], 1'b0};
                    end
                    n_s <= {n_s[30:0], 1'b0};
                end
            end
        end
    end
endmodule
