// Canonical v3 BEGIN/DATA/END file stream from validated synchronous event RAM.
// Ready/valid stalls preserve every byte. CRC advances one bit per clock,
// avoiding a long eight-bit CRC chain in the 50 MHz storage path.
`default_nettype none
module song_file_encode(
 input wire clk,rst_n,start,
 input wire [15:0] count,input wire [31:0] duration_ms,
 input wire [1:0] timbre,input wire [7:0] flags,
 output reg [10:0] read_addr,input wire [63:0] read_data,
 output wire valid,input wire ready,output reg [7:0] data,
 output reg done,output wire [15:0] file_size
);
 localparam IDLE=0,WAIT0=1,WAIT1=2,CAPTURE=3,SEND=4,CRC=5;
 reg [2:0] state;
 reg [7:0] kind,seq;
 reg [8:0] pos,length;
 reg [15:0] offset,crc,crc_work;
 reg [5:0] chunk;
 reg [2:0] crc_left;
 reg [63:0] word_q;
 wire [8:0] payload_pos=pos-9'd7;
 wire [8:0] event_pos=payload_pos-9'd2;
 wire [63:0] begin_word={flags,6'd0,timbre,duration_ms,count};
 wire [15:0] frame_count=(count+16'd31)>>5;
 assign file_size=16'd28+(count<<3)+(frame_count<<3)+(frame_count<<1)+frame_count;
 assign valid=state==SEND;
 wire [15:0] crc_next=crc_work[15]?(crc_work<<1)^16'h1021:crc_work<<1;
 always @(*)begin
  case(pos)
   0:data=8'ha5;1:data=8'h5a;2:data=3;3:data=kind;4:data=seq;
   5:data=length[7:0];6:data={7'd0,length[8]};
   default:begin
    if(pos==length+7)data=crc[7:0];
    else if(pos==length+8)data=crc[15:8];
    else if(kind==1)data=begin_word[payload_pos[2:0]*8+:8];
    else if(kind==3)data=payload_pos[0]?count[15:8]:count[7:0];
    else if(payload_pos<2)data=payload_pos[0]?offset[15:8]:offset[7:0];
    else data=word_q[event_pos[2:0]*8+:8];
   end
  endcase
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;kind<=1;seq<=0;pos<=0;length<=8;offset<=0;chunk<=0;
   crc<=16'hffff;crc_work<=0;crc_left<=0;word_q<=0;read_addr<=0;done<=0;
  end else begin
   done<=0;
   case(state)
    IDLE:if(start)begin kind<=1;seq<=0;pos<=0;length<=8;offset<=0;crc<=16'hffff;state<=SEND;end
    WAIT0:state<=WAIT1;
    WAIT1:state<=CAPTURE;
    CAPTURE:begin word_q<=read_data;state<=SEND;end
    SEND:if(ready)begin
     pos<=pos+1'b1;
     if(pos<length+7)begin
      crc_work<=crc^{data,8'd0};crc_left<=7;state<=CRC;
      if(kind==2 && pos>=9 && event_pos[2:0]==7 && pos<length+6)read_addr<=read_addr+1'b1;
     end else if(pos==length+8)begin
      crc<=16'hffff;pos<=0;seq<=seq+1'b1;
      if(kind==1)begin
       kind<=2;offset<=0;chunk<=count>32?32:count[5:0];
       length<=2+((count>32?9'd32:{3'd0,count[5:0]})<<3);read_addr<=0;state<=WAIT0;
      end else if(kind==2 && offset+chunk<count)begin
       offset<=offset+chunk;chunk<=count-offset-chunk>32?32:count-offset-chunk;
       length<=2+((count-offset-chunk>32?9'd32:count-offset-chunk)<<3);
       read_addr<=offset+chunk;state<=WAIT0;
      end else if(kind==2)begin kind<=3;length<=2;state<=SEND;end
      else begin state<=IDLE;done<=1;end
     end
    end
    CRC:begin
     crc_work<=crc_next;
     if(crc_left==0)begin
      crc<=crc_next;
      if(kind==2 && pos>=17 && (pos-9'd9)%8==0 && pos<length+7)state<=WAIT0;
      else state<=SEND;
     end else crc_left<=crc_left-1'b1;
    end
   endcase
  end
 end
endmodule
`default_nettype wire
