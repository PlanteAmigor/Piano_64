// Diagnostic only: raw status samples are approximate across the clock domains.
module hdmi_debug_uart(input clk,input resetn,input [95:0] info,output [1:0] mode,output tx);
 reg [95:0] s0=0,s1=0,msg=0;
 reg [20:0] timer=0;reg [6:0] beats=0;reg [3:0] por=0;
 wire rst=por==15;assign mode=beats[6:5];
 always @(posedge clk)begin
  if(!resetn)por<=0;else if(por!=15)por<=por+1'b1;
  s0<=info;s1<=s0;
  timer<=timer+1'b1;if(timer==0)beats<=beats+1'b1;
 end
 reg [4:0] index=0;reg [1:0] state=0;reg send=0;wire busy;reg [7:0] data=0;
 uart_tx uart(.clk(clk),.rst_n(rst),.dbyte(data),.send(send),.busy(busy),.txd(tx));
 wire [3:0] digit=msg[95:92];
 always @(posedge clk)begin
  send<=0;
  if(!rst)begin state<=0;index<=0;msg<=0;end
  else case(state)
   0:if(timer==1)begin msg<=s1;index<=0;state<=1;end
   1:if(!busy)begin
    if(index==0)data<=8'h44;
    else if(index<=24)begin data<=digit<10?48+digit:55+digit;msg<={msg[91:0],4'd0};end
    else data<=index==25?8'h0d:8'h0a;
    send<=1;state<=2;
   end
   2:if(busy)state<=3;
   3:if(!busy)begin if(index==26)state<=0;else begin index<=index+1'b1;state<=1;end end
  endcase
 end
endmodule
