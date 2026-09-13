//
// User core top-level: Analogue Pocket image viewer.
//
// Instantiated by the real top-level: apf_top
//
// What it does:
//   - 8 image data slots (data.json). The Pocket streams a 24-bit BMP into
//     each slot at boot (or on browser reload).
//   - slot_mgr delays the data-slot ACK until the parser has cleared the
//     slot's SDRAM framebuffer, then routes the streamed 32-bit words into
//     the parser's input FIFO.
//   - bmp_parser decodes the BMP (scale-to-fit, letterboxed) into the
//     slot's 800x720 framebuffer in SDRAM.
//   - video_scanout reads the selected slot line-by-line and outputs
//     800x720@60 video.
//   - D-pad left/right switches between the 8 slots.
//
// Clocking:
//   clk_74a  - APF framework clock (bridge, slot_mgr, navigation)
//   clk_mem  - 100 MHz SDRAM controller / parser / scanout read client
//   clk_vid  - 39.6 MHz video pixel clock

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness: big-endian (first file byte in [31:24])
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// debug/status register at 0x10xxxxxx:
//   [7:0]  slot_valid bits, [8] input fifo overflow (sticky),
//   [9] video underrun (sticky)
wire [7:0]  slot_valid;
wire        fifo_overflow;
wire        video_underrun;
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h10xxxxxx: begin
        bridge_rd_data <= {22'd0, video_underrun, fifo_overflow, slot_valid};
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;

// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s;
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1'b1;
    wire            dataslot_requestread_ok = 1'b0;   // we don't serve reads

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack;
    wire            dataslot_requestwrite_ok;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported = 1'b0;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack = 1'b0;
    wire            savestate_start_busy = 1'b0;
    wire            savestate_start_ok = 1'b0;
    wire            savestate_start_err = 1'b0;

    wire            savestate_load;
    wire            savestate_load_ack = 1'b0;
    wire            savestate_load_busy = 1'b0;
    wire            savestate_load_ok = 1'b0;
    wire            savestate_load_err = 1'b0;

    wire            osnotify_inmenu;

// bridge target commands: unused by this core
// synchronous to clk_74a

    wire            target_dataslot_read = 1'b0;
    wire            target_dataslot_write = 1'b0;
    wire            target_dataslot_getfile = 1'b0;
    wire            target_dataslot_openfile = 1'b0;

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    wire    [15:0]  target_dataslot_id = 16'd0;
    wire    [31:0]  target_dataslot_slotoffset = 32'd0;
    wire    [31:0]  target_dataslot_bridgeaddr = 32'd0;
    wire    [31:0]  target_dataslot_length = 32'd0;

    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands

// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////

//
// clocks & resets
//

    wire    clk_vid;            // 39.6 MHz video
    wire    clk_vid_90;
    wire    clk_mem;            // 100 MHz SDRAM controller
    wire    clk_mem_shifted;    // 100 MHz SDRAM chip clock, 340 deg

    wire    pll_core_locked;
    wire    pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

pll_imageviewer mp1 (
    .refclk         ( clk_74a ),
    .rst            ( 1'b0 ),

    .outclk_0       ( clk_vid ),
    .outclk_1       ( clk_vid_90 ),
    .outclk_2       ( clk_mem ),
    .outclk_3       ( clk_mem_shifted ),

    .locked         ( pll_core_locked )
);

// resets for the derived domains: held until the PLL is locked and the
// host has released reset_n
wire reset_ok_74a = reset_n & pll_core_locked_s;
wire mem_rst_n, vid_rst_n;
synch_3 s_mem_rst(reset_ok_74a, mem_rst_n, clk_mem);
synch_3 s_vid_rst(reset_ok_74a, vid_rst_n, clk_vid);

// Infrastructure reset: released on PLL lock, NOT gated on Pocket's reset_n.
// The APF boot sequence holds reset_n LOW through the entire data-slot load
// (0x0011 Reset Exit comes after 0x008F All Complete). The data-loading path
// (slot_mgr, FIFOs, parser, SDRAM) must be operational during this time,
// otherwise the 0x0082 ACK can never fire and the Pocket times out.
wire sys_rst_n_mem;
synch_3 s_sys_rst_mem(pll_core_locked_s, sys_rst_n_mem, clk_mem);

assign dram_clk = clk_mem_shifted;


////////////////////////////////////////////////////////////////////////////////////////

//
// navigation: d-pad left/right switches slots (wraps 0..7)
//

    reg [2:0] display_slot;
    reg       nav_left_p, nav_right_p;
always @(posedge clk_74a or negedge reset_n) begin
    if (!reset_n) begin
        display_slot <= 3'd0;
        nav_left_p   <= 1'b0;
        nav_right_p  <= 1'b0;
    end else begin
        nav_left_p  <= cont1_key[2];
        nav_right_p <= cont1_key[3];
        if (cont1_key[2] && !nav_left_p)
            display_slot <= (display_slot == 3'd0) ? 3'd7 : display_slot - 3'd1;
        else if (cont1_key[3] && !nav_right_p)
            display_slot <= (display_slot == 3'd7) ? 3'd0 : display_slot + 3'd1;
    end
end


////////////////////////////////////////////////////////////////////////////////////////

//
// slot manager: data slots -> parser input FIFO
//

    wire [31:0] fifo_in_wr_data;
    wire        fifo_in_wr_en;
    wire        fifo_in_wr_full;

    wire        sm_ps_start;
    wire [2:0]  sm_ps_slot_id;
    wire [21:0] sm_ps_total_words;
    wire [1:0]  sm_ps_last_valid;
    wire        sm_ps_clear_only;
    wire        sm_ps_ready;
    wire        sm_ps_done;
    wire        sm_ps_op_valid;

slot_mgr slot_mgr_inst (
    .clk                        ( clk_74a ),
    .rst_n                      ( pll_core_locked_s ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .bridge_addr                ( bridge_addr ),
    .bridge_wr                  ( bridge_wr ),
    .bridge_wr_data             ( bridge_wr_data ),

    .fifo_wr_data               ( fifo_in_wr_data ),
    .fifo_wr_en                 ( fifo_in_wr_en ),
    .fifo_wr_full               ( fifo_in_wr_full ),

    .mem_clk                    ( clk_mem ),
    .mem_rst_n                  ( mem_rst_n ),
    .ps_start                   ( sm_ps_start ),
    .ps_slot_id                 ( sm_ps_slot_id ),
    .ps_total_words             ( sm_ps_total_words ),
    .ps_last_valid              ( sm_ps_last_valid ),
    .ps_clear_only              ( sm_ps_clear_only ),
    .ps_ready                   ( sm_ps_ready ),
    .ps_done                    ( sm_ps_done ),
    .ps_op_valid                ( sm_ps_op_valid ),

    .slot_valid                 ( slot_valid ),
    .busy                       (),
    .fifo_overflow              ( fifo_overflow )
);


////////////////////////////////////////////////////////////////////////////////////////

//
// BMP parser: input FIFO -> SDRAM framebuffers
//

    wire [31:0] fifo_in_rd_data;
    wire        fifo_in_rd_empty;
    wire        fifo_in_rd_en;

    wire        p_wr_req;
    wire [24:0] p_wr_addr;
    wire [20:0] p_wr_len;
    wire        p_wr_busy;
    wire [15:0] p_wr_data;
    wire        p_wr_valid;
    wire        p_wr_ready;
    wire        sdram_init_done;

bmp_parser parser_inst (
    .clk               ( clk_mem ),
    .rst_n             ( sys_rst_n_mem ),

    .start             ( sm_ps_start ),
    .slot_id           ( sm_ps_slot_id ),
    .total_words       ( sm_ps_total_words ),
    .last_valid        ( sm_ps_last_valid ),
    .clear_only        ( sm_ps_clear_only ),
    .sdram_init_done   ( sdram_init_done ),
    .ready             ( sm_ps_ready ),
    .idle              (),
    .done              ( sm_ps_done ),
    .op_valid          ( sm_ps_op_valid ),

    .fifo_data         ( fifo_in_rd_data ),
    .fifo_empty        ( fifo_in_rd_empty ),
    .fifo_rd           ( fifo_in_rd_en ),

    .wr_req            ( p_wr_req ),
    .wr_addr           ( p_wr_addr ),
    .wr_len            ( p_wr_len ),
    .wr_busy           ( p_wr_busy ),
    .wr_data           ( p_wr_data ),
    .wr_valid          ( p_wr_valid ),
    .wr_ready          ( p_wr_ready )
);

// parser input FIFO: 16384 x 32 (64 KB)
async_fifo #(
    .DATA_W(32),
    .ADDR_W(15)   // 32K x 32 = 128KB: absorbs host stream during bkgnd clear
) fifo_in_inst (
    .wr_clk   ( clk_74a ),
    .wr_rst_n ( pll_core_locked_s ),
    .wr_data  ( fifo_in_wr_data ),
    .wr_en    ( fifo_in_wr_en ),
    .wr_full  ( fifo_in_wr_full ),
    .wr_level (),

    .rd_clk   ( clk_mem ),
    .rd_rst_n ( sys_rst_n_mem ),
    .rd_data  ( fifo_in_rd_data ),
    .rd_en    ( fifo_in_rd_en ),
    .rd_empty ( fifo_in_rd_empty ),
    .rd_level ()
);


////////////////////////////////////////////////////////////////////////////////////////

//
// SDRAM controller
//

    wire        v_rd_req;
    wire [24:0] v_rd_addr;
    wire [15:0] v_rd_len;
    wire        v_rd_busy;
    wire [15:0] v_rd_data;
    wire        v_rd_valid;
    wire        v_rd_ready;

sdram_ctrl mem_ctrl_inst (
    .clk       ( clk_mem ),
    .rst_n     ( sys_rst_n_mem ),

    .init_done ( sdram_init_done ),

    .wr_req    ( p_wr_req ),
    .wr_addr   ( p_wr_addr ),
    .wr_len    ( p_wr_len ),
    .wr_busy   ( p_wr_busy ),
    .wr_data   ( p_wr_data ),
    .wr_valid  ( p_wr_valid ),
    .wr_ready  ( p_wr_ready ),

    .rd_req    ( v_rd_req ),
    .rd_addr   ( v_rd_addr ),
    .rd_len    ( v_rd_len ),
    .rd_busy   ( v_rd_busy ),
    .rd_data   ( v_rd_data ),
    .rd_valid  ( v_rd_valid ),
    .rd_ready  ( v_rd_ready ),

    .dram_a    ( dram_a ),
    .dram_ba   ( dram_ba ),
    .dram_ras_n( dram_ras_n ),
    .dram_cas_n( dram_cas_n ),
    .dram_we_n ( dram_we_n ),
    .dram_dqm  ( dram_dqm ),
    .dram_cke  ( dram_cke ),
    .dram_dq   ( dram_dq )
);


////////////////////////////////////////////////////////////////////////////////////////

//
// video scanout: SDRAM -> 800x720@60
//

    wire [31:0] pfifo_wr_data;
    wire        pfifo_wr_en;
    wire        pfifo_wr_full;
    wire [12:0] pfifo_wr_level;

    wire [31:0] pfifo_rd_data;
    wire        pfifo_rd_empty;
    wire        pfifo_rd_en;

video_scanout scanout_inst (
    .mem_clk        ( clk_mem ),
    .mem_rst_n      ( mem_rst_n ),

    .rd_req         ( v_rd_req ),
    .rd_addr        ( v_rd_addr ),
    .rd_len         ( v_rd_len ),
    .rd_busy        ( v_rd_busy ),
    .rd_data        ( v_rd_data ),
    .rd_valid       ( v_rd_valid ),
    .rd_ready       ( v_rd_ready ),

    .display_slot   ( display_slot ),
    .slot_valid     ( slot_valid ),
    .sdram_init_done( sdram_init_done ),

    .pfifo_wr_data  ( pfifo_wr_data ),
    .pfifo_wr_en    ( pfifo_wr_en ),
    .pfifo_wr_full  ( pfifo_wr_full ),
    .pfifo_wr_level ( pfifo_wr_level ),

    .vid_clk        ( clk_vid ),
    .vid_rst_n      ( vid_rst_n ),
    .pfifo_rd_data  ( pfifo_rd_data ),
    .pfifo_rd_empty ( pfifo_rd_empty ),
    .pfifo_rd_en    ( pfifo_rd_en ),

    .video_rgb      ( video_rgb ),
    .video_de       ( video_de ),
    .video_vs       ( video_vs ),
    .video_hs       ( video_hs ),
    .video_skip     ( video_skip ),
    .underrun       ( video_underrun )
);

assign video_rgb_clock = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;

// pixel FIFO: 4096 x 32 (16 KB)
async_fifo #(
    .DATA_W(32),
    .ADDR_W(12)
) pfifo_inst (
    .wr_clk   ( clk_mem ),
    .wr_rst_n ( mem_rst_n ),
    .wr_data  ( pfifo_wr_data ),
    .wr_en    ( pfifo_wr_en ),
    .wr_full  ( pfifo_wr_full ),
    .wr_level ( pfifo_wr_level ),

    .rd_clk   ( clk_vid ),
    .rd_rst_n ( vid_rst_n ),
    .rd_data  ( pfifo_rd_data ),
    .rd_en    ( pfifo_rd_en ),
    .rd_empty ( pfifo_rd_empty ),
    .rd_level ()
);


//
// audio i2s silence generator
// see other examples for actual audio generation
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
    reg         audgen_lrck_1;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt;
    reg             audgen_lrck;
    reg             audgen_dac;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;

    end
end


endmodule
