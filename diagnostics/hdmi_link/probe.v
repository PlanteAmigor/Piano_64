`timescale 1ns/1ps
// Standalone HDMI link diagnostic. No SD, DDR, audio or UI dependencies.
// UART uses the independent 50MHz input, so failed video clocks stay visible.
module hdmi_link_probe #(parameter WINDOW=5000000)(
 input CLOCK_50,input RESET_n,output UART_TX,
 output tmds_clk_n_0,output tmds_clk_p_0,
 output [2:0] tmds_d_n_0,output [2:0] tmds_d_p_0);
 wire pixel,serial_clk,reference_clk,reference_lock,video_lock;
 probe_clocks clocks(.clkin(CLOCK_50),.pixel(pixel),.serial_clk(serial_clk),
  .reference_clk(reference_clk),.reference_lock(reference_lock),.video_lock(video_lock));
 wire lock=reference_lock && video_lock;
 reg [7:0] video_por=0;
 always @(posedge pixel or negedge RESET_n)begin
  if(!RESET_n)video_por<=0;
  else if(!lock)video_por<=0;
  else if(video_por!=255)video_por<=video_por+1'b1;
 end
 wire video_reset=video_por!=255;
`ifdef PROBE_900P
 // Local cvt -r 1600 900 60: CVT-RB 59.82Hz, +HS/-VS, 97.5MHz.
 localparam HA=1600,HT=1760,HS0=1648,HS1=1680,VA=900,VT=926,VS0=903,VS1=908;
`else
`ifdef PROBE_720P
 localparam HA=1280,HT=1650,HS0=1390,HS1=1430,VA=720,VT=750,VS0=725,VS1=730;
`else
 localparam HA=1920,HT=2200,HS0=2008,HS1=2052,VA=1080,VT=1125,VS0=1084,VS1=1089;
`endif
`endif
 reg [11:0] x=0;reg [10:0] y=0;
 always @(posedge pixel)begin
  if(video_reset)begin x<=0;y<=0;end
  else if(x==HT-1)begin x<=0;if(y==VT-1)y<=0;else y<=y+1'b1;end
  else x<=x+1'b1;
 end
 wire de=x<HA && y<VA;
 wire hs=x>=HS0 && x<HS1;
`ifdef PROBE_900P
 wire vs=!(y>=VS0 && y<VS1);
`else
 wire vs=y>=VS0 && y<VS1;
`endif
 wire [23:0] rgb=x<HA/8?24'hffffff:x<HA/4?24'hffff00:
  x<HA*3/8?24'h00ffff:x<HA/2?24'h00ff00:x<HA*5/8?24'hff00ff:
  x<HA*3/4?24'hff0000:x<HA*7/8?24'h0000ff:24'h000000;
 dvi_tx_top video(.pixel_clock(pixel),.ddr_bit_clock(serial_clk),.reset(video_reset),
  .den(de),.hsync(hs),.vsync(vs),.pixel_data(rgb),
  .tmds_clk({tmds_clk_p_0,tmds_clk_n_0}),
  .tmds_d0({tmds_d_p_0[0],tmds_d_n_0[0]}),
  .tmds_d1({tmds_d_p_0[1],tmds_d_n_0[1]}),
  .tmds_d2({tmds_d_p_0[2],tmds_d_n_0[2]}));
    reg [9:0] ref_count=0,pixel_count=0;
    always @(posedge reference_clk)ref_count<=ref_count+1'b1;
    always @(posedge pixel)pixel_count<=pixel_count+1'b1;
    reg [2:0] rs=0,ps=0;reg [1:0] locks0=0,locks1=0;
    reg [15:0] ref_edges=0,pixel_edges=0;
    reg [15:0] ref_value=0,pixel_value=0;
    reg [1:0] lock_value=0;
    reg [22:0] timer=0;reg [3:0] por=0;
    wire rst=por==15;
    always @(posedge CLOCK_50)begin
        if(!RESET_n)por<=0;else if(por!=15)por<=por+1'b1;
        rs<={rs[1:0],ref_count[9]};ps<={ps[1:0],pixel_count[9]};
        locks0<={reference_lock,video_lock};locks1<=locks0;
        if(!rst)begin timer<=0;ref_edges<=0;pixel_edges<=0;ref_value<=0;pixel_value<=0;lock_value<=0;end
        else if(timer==WINDOW-1)begin
            timer<=0;ref_value<=ref_edges;pixel_value<=pixel_edges;lock_value<=locks1;ref_edges<=0;pixel_edges<=0;
        end else begin
            timer<=timer+1'b1;
            if(rs[2]^rs[1])ref_edges<=ref_edges+1'b1;
            if(ps[2]^ps[1])pixel_edges<=pixel_edges+1'b1;
        end
    end
    function [7:0] hex;
        input [3:0] value;
        begin hex=value<10?8'd48+value:8'd55+value;end
    endfunction
    reg [3:0] index=0;reg [1:0] state=0;
    reg [7:0] data=0;reg send=0;wire busy;
    reg [33:0] message=0;
    uart_tx uart(.clk(CLOCK_50),.rst_n(rst),.dbyte(data),.send(send),.busy(busy),.txd(UART_TX));
    always @(posedge CLOCK_50)begin
        send<=0;
        if(!rst)begin index<=0;state<=0;message<=0;end
        else case(state)
            0:if(timer==1)begin message<={lock_value,ref_value,pixel_value};index<=0;state<=1;end
            1:if(!busy)begin
                case(index)
                    0:data<=8'h4c;
                    1:data<=hex({2'd0,message[33:32]});
                    2:data<=8'h20;
                    3:data<=hex(message[31:28]);4:data<=hex(message[27:24]);5:data<=hex(message[23:20]);6:data<=hex(message[19:16]);
                    7:data<=8'h20;
                    8:data<=hex(message[15:12]);9:data<=hex(message[11:8]);10:data<=hex(message[7:4]);11:data<=hex(message[3:0]);
                    12:data<=8'h0d;default:data<=8'h0a;
                endcase
                send<=1;state<=2;
            end
            2:if(busy)state<=3;
            3:if(!busy)begin if(index==13)state<=0;else begin index<=index+1'b1;state<=1;end end
        endcase
    end
endmodule
