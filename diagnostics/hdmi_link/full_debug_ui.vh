// Diagnostic snapshot only. These taps are never used by normal UI logic.
reg [1:0] dbg_m0=0,dbg_m1=0;
reg [9:0] dbg_pixels=0;
reg [7:0] dbg_frames=0,dbg_por=0;
reg dbg_vis_seen=0,dbg_rgb_seen=0;
reg [11:0] dbg_x=0,dbg_y=0;
always @(posedge clk_p)begin
 dbg_m0<=DEBUG_MODE;dbg_m1<=dbg_m0;dbg_pixels<=dbg_pixels+1'b1;
 if(!rst_n)begin dbg_frames<=0;dbg_vis_seen<=0;dbg_rgb_seen<=0;end
 else begin
  if(frame_tick)dbg_frames<=dbg_frames+1'b1;
  if(vis_d9)dbg_vis_seen<=1;
  if(vis_d9 && rgb_r!=0)dbg_rgb_seen<=1;
 end
 if(!resetn || !pll_lock)dbg_por<=0;else if(dbg_por!=255)dbg_por<=dbg_por+1'b1;
 if(dbg_por!=255)begin dbg_x<=0;dbg_y<=0;end
 else if(dbg_x==2199)begin dbg_x<=0;dbg_y<=dbg_y==1124?0:dbg_y+1'b1;end
 else dbg_x<=dbg_x+1'b1;
end
assign DEBUG[0]=pll_lock;assign DEBUG[1]=rst_n;assign DEBUG[9:2]=local_rst_n;
assign DEBUG[13:10]=por;assign DEBUG[17:14]=fade_lvl;assign DEBUG[19:18]=page_show;
assign DEBUG[20]=fading_out;assign DEBUG[21]=dbg_vis_seen;assign DEBUG[22]=dbg_rgb_seen;
assign DEBUG[23]=vis_d9;assign DEBUG[35:24]=hcnt;assign DEBUG[47:36]=vcnt;
assign DEBUG[55:48]=dbg_frames;assign DEBUG[65:56]=dbg_pixels;
assign DEBUG[89:66]=rgb_r;assign DEBUG[91:90]=dbg_m1;assign DEBUG[95:92]=0;
wire dbg_independent=dbg_m1==2;
wire dbg_de=dbg_independent?(dbg_x<1920 && dbg_y<1080):vis_d9;
wire dbg_hs=dbg_independent?(dbg_x>=2008 && dbg_x<2052):hs_d9;
wire dbg_vs=dbg_independent?(dbg_y>=1084 && dbg_y<1089):vs_d9;
wire [23:0] dbg_bars=dbg_x<240?24'hffffff:dbg_x<480?24'hffff00:dbg_x<720?24'h00ffff:
 dbg_x<960?24'h00ff00:dbg_x<1200?24'hff00ff:dbg_x<1440?24'hff0000:dbg_x<1680?24'h0000ff:24'h000000;
wire [23:0] dbg_rgb=dbg_independent?dbg_bars:dbg_m1==1?24'h40a0ff:rgb_r;
wire dbg_reset=dbg_independent?(dbg_por!=255):dvi_reset;
