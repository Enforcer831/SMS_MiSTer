//============================================================================
//  SMS replica
// 
//  Port to MiSTer
//  Copyright (C) 2017,2018 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [44:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	input         TAPE_IN,

	// SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR
);

`define USE_SP64

`ifdef USE_SP64
localparam MAX_SPPL = 63;
localparam SP64     = 1'b1;
`else
localparam MAX_SPPL = 7;
localparam SP64     = 1'b0;
`endif

assign VGA_F1 = 0;

assign {UART_RTS, UART_TXD, UART_DTR} = 0;

assign {SD_SCK, SD_MOSI, SD_CS} = '1;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign LED_USER  = ioctl_download | bk_state;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = status[9] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[9] ? 8'd9  : 8'd3;

`include "build_id.v"
parameter CONF_STR1 = {
	"SMS;;",
	"-;",
	"FS,SMS;",
	"FS,GG;",
	"-;",
};
parameter CONF_STR2 = {
	"AB,Save Slot,1,2,3,4;"
};
parameter CONF_STR3 = {
	"6,Load state;"
};
parameter CONF_STR4 = {
	"7,Save state;",
	"-;",
	"O9,Aspect ratio,4:3,16:9;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O2,TV System,NTSC,PAL;",
	"OD,Border,No,Yes;",
`ifdef USE_SP64
	"O8,Sprites per line,Std(8),All(64);",
`endif
	"OC,FM sound,Enable,Disable;",
	"-;",
	"O1,Swap joysticks,No,Yes;",
	"OE,Multitap,Disabled,Port1;",
	"-;",
	"R0,Reset;",
	"J1,Fire 1,Fire 2,Pause;",
	"V,v",`BUILD_DATE
};


////////////////////   CLOCKS   ///////////////////

wire locked;
wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(SDRAM_CLK),
	.locked(locked)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download | bk_loading;

//////////////////   HPS I/O   ///////////////////
wire  [6:0] joy[4], joy_0, joy_1;
wire  [1:0] buttons;
wire [31:0] status;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

reg  [31:0] sd_lba;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din;
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

wire        forced_scandoubler;

hps_io #(.STRLEN(($size(CONF_STR1)>>3) + ($size(CONF_STR2)>>3) + ($size(CONF_STR3)>>3) + ($size(CONF_STR4)>>3) + 3), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str({CONF_STR1,bk_ena ? "O" : "+",CONF_STR2,bk_ena ? "R" : "+",CONF_STR3,bk_ena ? "R" : "+",CONF_STR4}),

	.joystick_0(joy_0),
	.joystick_1(joy_1),
	.joystick_2(joy[2]),
	.joystick_3(joy[3]),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),
	.new_vmode(pal),

	.ps2_kbd_led_use(0),
	.ps2_kbd_led_status(0),

	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),

	.sd_conf(0),
	.ioctl_wait(ioctl_wait),
	
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

wire [21:0] ram_addr;
wire  [7:0] ram_dout;
wire        ram_rd;

sdram ram
(
	.*,

	.init(~locked),
	.clk(clk_sys),
	.clkref(ce_cpu),

	.waddr(romwr_a),
	.din(ioctl_dout),
	.we(rom_wr),
	.we_ack(sd_wrack),

	.raddr(ioctl_addr[9] ? (ram_addr - 10'd512) & cart_mask512 : ram_addr & cart_mask),
	.dout(ram_dout),
	.rd(ram_rd),
	.rd_rdy()
);

reg  rom_wr = 0;
wire sd_wrack;
reg  [23:0] romwr_a;

always @(posedge clk_sys) begin
	reg old_download, old_reset;

	old_download <= ioctl_download;
	old_reset <= reset;

	if(~old_reset && reset) ioctl_wait <= 0;
	if(~old_download && ioctl_download) romwr_a <= 0;
	else begin
		if(ioctl_wr) begin
			ioctl_wait <= 1;
			rom_wr <= ~rom_wr;
		end else if(ioctl_wait && (rom_wr == sd_wrack)) begin
			ioctl_wait <= 0;
			romwr_a <= romwr_a + 1'd1;
		end
	end
end

assign AUDIO_S = 1;
assign AUDIO_MIX = 1;

reg  dbr = 0;
always @(posedge clk_sys) begin
	if(ioctl_download || bk_loading) dbr <= 1;
end

reg gg = 0;
reg [21:0] cart_mask, cart_mask512;
always @(posedge clk_sys) begin
	if(ioctl_wr) begin
		cart_mask <= cart_mask | ioctl_addr[21:0];
		cart_mask512 <= cart_mask512 | (ioctl_addr[21:0] - 10'd512);
		if(!ioctl_addr) cart_mask <= 0;
		if(ioctl_addr == 512) cart_mask512 <= 0;
		gg <= ioctl_index[4:0] == 2;
	end;
end

wire [12:0] ram_a;
wire        ram_we;
wire  [7:0] ram_d;
wire  [7:0] ram_q;

wire [14:0] nvram_a;
wire        nvram_we;
wire  [7:0] nvram_d;
wire  [7:0] nvram_q;

system #(MAX_SPPL) system
(
	.clk_sys(clk_sys),
	.ce_cpu(ce_cpu),
	.ce_vdp(ce_vdp),
	.ce_pix(ce_pix),
	.ce_sp(ce_sp),
	.gg(gg),

	.RESET_n(~reset),

	.rom_rd(ram_rd),
	.rom_a(ram_addr),
	.rom_do(ram_dout),

	.j1_up(joya[3]),
	.j1_down(joya[2]),
	.j1_left(joya[1]),
	.j1_right(joya[0]),
	.j1_tl(joya[4]),
	.j1_tr(joya[5]),
	.j1_th(joya_th),
	.j2_up(joyb[3]),
	.j2_down(joyb[2]),
	.j2_left(joyb[1]),
	.j2_right(joyb[0]),
	.j2_tl(joyb[4]),
	.j2_tr(joyb[5]),
	.pause(joya[6]&joyb[6]),

	.x(x),
	.y(y),
	.color(color),
	.mask_column(mask_column),

	.fm_ena(~status[12]),
	.audioL(audio_l),
	.audioR(audio_r),

	.dbr(dbr),
	.sp64(status[8] & SP64),

	.ram_a(ram_a),
	.ram_we(ram_we),
	.ram_d(ram_d),
	.ram_q(ram_q),

	.nvram_a(nvram_a),
	.nvram_we(nvram_we),
	.nvram_d(nvram_d),
	.nvram_q(nvram_q)
);

assign joy[0] = status[1] ? joy_1 : joy_0;
assign joy[1] = status[1] ? joy_0 : joy_1;

wire [6:0] joya = ~joy[jcnt];
wire [6:0] joyb = status[14] ? 7'h7F : ~joy[1];

wire      joya_th;
reg [1:0] jcnt = 0;
always @(posedge clk_sys) begin
	reg old_th;
	reg [15:0] tmr;

	if(ce_cpu) begin
		if(tmr > 57000) jcnt <= 0;
		else if(joya_th) tmr <= tmr + 1'd1;

		old_th <= joya_th;
		if(old_th & ~joya_th) begin
			tmr <= 0;
			//first clock doesn't count as capacitor has not discharged yet
			if(tmr < 57000) jcnt <= jcnt + 1'd1;
		end
	end

	if(reset | ~status[14]) jcnt <= 0;
end

spram #(.widthad_a(13)) ram_inst
(
	.clock     (clk_sys),
	.address   (ram_a),
	.wren      (ram_we),
	.data      (ram_d),
	.q         (ram_q)
);

wire [15:0] audio_l, audio_r; 

compressor compressor
(
	clk_sys,
	audio_l[15:4], audio_r[15:4],
	AUDIO_L,       AUDIO_R
); 

wire [8:0] x;
wire [8:0] y;
wire [11:0] color;
wire mask_column;
wire pal = status[2];

video video
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.pal(pal),
	.gg(gg),
	.border(status[13]),
	.mask_column(mask_column),

	.x(x),
	.y(y),

	.hsync(HSync),
	.vsync(VSync),
	.hblank(HBlank),
	.vblank(VBlank)
);

reg ce_cpu;
reg ce_vdp;
reg ce_pix;
reg ce_sp;
always @(negedge clk_sys) begin
	reg [4:0] clkd;

	ce_sp <= clkd[0];
	ce_vdp <= 0;//div5
	ce_pix <= 0;//div10
	ce_cpu <= 0;//div15
	clkd <= clkd + 1'd1;
	if (clkd==29) begin
		clkd <= 0;
		ce_vdp <= 1;
		ce_pix <= 1;
		ce_cpu <= 1;
	end else if (clkd==24) begin
		ce_vdp <= 1;
	end else if (clkd==19) begin
		ce_vdp <= 1;
		ce_pix <= 1;
	end else if (clkd==14) begin
		ce_vdp <= 1;
		ce_cpu <= 1;
	end else if (clkd==9) begin
		ce_vdp <= 1;
		ce_pix <= 1;
	end else if (clkd==4) begin
		ce_vdp <= 1;
	end
end

wire HSync, VSync;
wire HBlank, VBlank;

wire [2:0] scale = status[5:3];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;

assign CLK_VIDEO = clk_sys;
assign VGA_SL = sl[1:0];

video_mixer #(.HALF_DEPTH(1), .LINE_LENGTH(300)) video_mixer
(
	.*,
	.clk_sys(CLK_VIDEO),
	.ce_pix_out(CE_PIXEL),
	.ce_pix(ce_pix),
	
	.scanlines(0),
	.scandoubler(scale || forced_scandoubler),
	.hq2x(scale==1),
	.mono(0),

	.R({2{color[3:0]}}),
	.G({2{color[7:4]}}),
	.B({2{color[11:8]}})
);


/////////////////////////  STATE SAVE/LOAD  /////////////////////////////
dpram #(.widthad_a(15)) nvram_inst
(
	.clock_a     (clk_sys),
	.address_a   (nvram_a),
	.wren_a      (nvram_we),
	.data_a      (nvram_d),
	.q_a         (nvram_q),
	.clock_b     (clk_sys),
	.address_b   ({sd_lba[5:0],sd_buff_addr}),
	.wren_b      (sd_buff_wr & sd_ack),
	.data_b      (sd_buff_dout),
	.q_b         (sd_buff_din)
);

wire downloading = ioctl_download;
reg bk_ena = 0;
always @(posedge clk_sys) begin
	reg old_downloading = 0;
	
	old_downloading <= downloading;
	if(~old_downloading & downloading) bk_ena <= 0;
	
	//Save file always mounted in the end of downloading state.
	if(downloading && img_mounted && img_size && !img_readonly) bk_ena <= 1;
end

wire bk_load    = status[6];
wire bk_save    = status[7];
reg  bk_loading = 0;
reg  bk_state   = 0;

always @(posedge clk_sys) begin
	reg old_load = 0, old_save = 0, old_ack;

	old_load <= bk_load & bk_ena;
	old_save <= bk_save & bk_ena;
	old_ack  <= sd_ack;
	
	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;
	
	if(!bk_state) begin
		if((~old_load & bk_load) | (~old_save & bk_save)) begin
			bk_state <= 1;
			bk_loading <= bk_load;
			sd_lba <= {status[11:10],6'd0};
			sd_rd <=  bk_load;
			sd_wr <= ~bk_load;
		end
	end else begin
		if(old_ack & ~sd_ack) begin
			if(&sd_lba[5:0]) begin
				bk_loading <= 0;
				bk_state <= 0;
			end else begin
				sd_lba <= sd_lba + 1'd1;
				sd_rd  <=  bk_loading;
				sd_wr  <= ~bk_loading;
			end
		end
	end
end

endmodule


