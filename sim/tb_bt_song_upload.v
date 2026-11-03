`timescale 1ns/1ps
`default_nettype none
module tb_bt_song_upload;
 reg clk=0,rst_n=0,rx=1;always #10 clk=~clk;
 wire tx,cmd,cmd_play,save,ss_valid,committed,uploading;
 wire [7:0] ss_data,last_error;wire [15:0] size,accepted;
 reg cmd_reply=0,playing=0,save_done=0,stream_start=0,stream_ready=0;
 reg [7:0] save_error=0;reg [31:0] position=0;
 integer saves=0,commands=0,save_wait=0,reply_wait=0,stream_count=0,seed=64;
 reg [7:0] expected[0:17115],payload[0:257],ack[0:22];integer an=0;
 wire [7:0] ackbyte;wire av,ae;
 bt_song_upload #(.CLK_HZ(1000000),.BAUD(100000),.RX_TIMEOUT_MS(10)) dut(
  .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.source_ready(1'b1),.current_timbre(2'd0),
  .playing(playing),.dropped(1'b0),.position(position),.command_toggle(cmd),.command_play(cmd_play),
  .command_reply(cmd_reply),.command_error(8'd0),.save_start(save),.save_done(save_done),.save_error(save_error),
  .file_size(size),.stream_start(stream_start),.stream_ready(stream_ready),.stream_valid(ss_valid),.stream_data(ss_data),
  .song_timbre(),.song_valid(committed),.uploading(uploading),.accepted_count(accepted),.last_error(last_error));
 bt_uart_rx #(.CLK_HZ(1000000),.BAUD(100000)) monitor(.clk(clk),.rst_n(rst_n),.rx(tx),.data(ackbyte),.valid(av),.framing_error(ae));
 always @(posedge clk)begin
  if(ae)$fatal(1,"ACK UART framing error");
  if(av)begin if(an>=23)$fatal(1,"unexpected extra ACK");ack[an]=ackbyte;an=an+1;end
  save_done<=0;stream_start<=0;
  if(save)begin saves=saves+1;save_wait=1;stream_count=0;stream_start<=1;end
  if(save_wait!=0)begin
   save_wait=save_wait+1;
   if(save_wait>20000 && stream_count==size)begin save_done<=1;save_wait=0;end
  end
  if(ss_valid && stream_ready)begin
   if(ss_data!==expected[stream_count])$fatal(1,"stored stream mismatch byte %d got=%h expected=%h",stream_count,ss_data,expected[stream_count]);
   stream_count=stream_count+1;
  end
  if(cmd!=cmd_reply)begin
   reply_wait=reply_wait+1;
   if(reply_wait==100)begin commands=commands+1;cmd_reply<=cmd;playing<=cmd_play;reply_wait=0;end
  end
 end
 always @(negedge clk)stream_ready=($random(seed)&3)!=0;
 function [15:0] crcbyte(input [15:0] c,input [7:0] b);
  reg [15:0] x;integer k;begin x=c^{b,8'd0};for(k=0;k<8;k=k+1)x=x[15]?(x<<1)^16'h1021:x<<1;crcbyte=x;end
 endfunction
 task uart(input [7:0] b);integer k;
  begin rx=0;repeat(10)@(negedge clk);for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge clk);end rx=1;repeat(10)@(negedge clk);end
 endtask
 task transaction(input [7:0] kind,seq,input integer len,corrupt,status,naccepted);
  reg [15:0] crc,check;reg [7:0] b;integer i;
  begin
   an=0;crc=16'hffff;@(negedge clk);
   for(i=0;i<len+7;i=i+1)begin
    case(i)0:b=8'ha5;1:b=8'h5a;2:b=3;3:b=kind;4:b=seq;5:b=len;6:b=len>>8;default:b=payload[i-7];endcase
    crc=crcbyte(crc,b);uart(b);
   end
   uart(crc[7:0]^(corrupt?8'h01:8'h00));uart(crc[15:8]);
   wait(an==23);repeat(30)@(negedge clk);
   if(ack[0]!=8'ha5 || ack[1]!=8'h5a || ack[3]!=8'h80 || ack[4]!=seq || ack[5]!=14 || ack[7]!=kind || ack[8]!=status || {ack[10],ack[9]}!=naccepted || {ack[17],ack[16]}!=2048)
    $fatal(1,"ACK type=%h seq=%h status=%d/%d accepted=%d/%d",ack[7],ack[4],ack[8],status,{ack[10],ack[9]},naccepted);
   check=16'hffff;for(i=0;i<21;i=i+1)check=crcbyte(check,ack[i]);
   if({ack[22],ack[21]}!==check)$fatal(1,"ACK CRC");
  end
 endtask
 task begin_song(input integer n,input [7:0] seq,flags);integer i;reg [63:0] h;
  begin h={flags,8'd0,32'(n*250),16'(n)};for(i=0;i<8;i=i+1)payload[i]=h[i*8+:8];transaction(1,seq,8,0,0,0);end
 endtask
 task data_chunk(input integer offset,n,input [7:0] seq,input integer badcrc,status,na);
  integer i,j;reg [63:0] e;
  begin payload[0]=offset;payload[1]=offset>>8;
   for(i=0;i<n;i=i+1)begin e={8'd100,16'd200,8'd60,32'((offset+i)*250)};for(j=0;j<8;j=j+1)payload[2+i*8+j]=e[j*8+:8];end
   transaction(2,seq,2+8*n,badcrc,status,na);
  end
 endtask
 integer i;
 initial begin
  $readmemh("work/bt_store/encode_expected.hex",expected);
  repeat(20)@(negedge clk);rst_n=1;
  transaction(8'h12,0,0,0,0,0);transaction(8'h10,1,0,0,3,0);
  begin_song(33,2,0);if(!uploading)$fatal(1,"BEGIN");
  data_chunk(0,32,3,0,0,32);data_chunk(0,32,3,0,0,32); // no duplicate RAM mutation
  data_chunk(32,1,4,1,1,32);data_chunk(32,1,4,0,0,33); // CRC retry
  payload[0]=33;payload[1]=0;transaction(3,5,2,0,0,33);
  if(!committed || uploading || saves!=1 || stream_count!=size)$fatal(1,"END before persistence");
  transaction(3,5,2,0,0,33);if(saves!=1)$fatal(1,"duplicate END wrote another file");
  transaction(8'h10,6,0,0,0,33);if(!playing)$fatal(1,"PLAY");
  transaction(8'h10,6,0,0,0,33);if(commands!=2)$fatal(1,"duplicate PLAY retriggered");
  transaction(8'h11,7,0,0,0,33);if(playing)$fatal(1,"STOP");
  begin_song(1,8,0);data_chunk(1,1,9,0,7,0);if(uploading)$fatal(1,"offset error did not invalidate");
  payload[0]=1;payload[1]=0;transaction(3,10,2,0,3,0);
  begin_song(1,11,0);payload[0]=0;payload[1]=0;for(i=2;i<10;i=i+1)payload[i]=0;
  transaction(2,12,10,0,5,0);if(uploading)$fatal(1,"bad event accepted");
  // A failed SD commit must never produce a committed flag or playable score.
  begin_song(33,13,0);data_chunk(0,32,14,0,0,32);data_chunk(32,1,15,0,0,33);
  save_error=24;payload[0]=33;payload[1]=0;transaction(3,16,2,0,3,33);
  if(committed || uploading || saves!=2)$fatal(1,"failed storage acknowledged as committed");
  transaction(8'h10,17,0,0,3,33);save_error=0;
  // Timed-out DATA can be retried without a partial RAM transaction.
  begin_song(1,18,0);an=0;
  uart(8'ha5);uart(8'h5a);uart(3);uart(2);uart(19);uart(10);uart(0);uart(0);
  wait(an==23);repeat(30)@(negedge clk);
  if(ack[8]!=8 || accepted!=0)$fatal(1,"timeout ACK or partial transaction");
  data_chunk(0,1,19,0,0,1);
  // Ordinary polyphony limit and the explicit legacy drop flag.
  begin_song(9,20,0);payload[0]=0;payload[1]=0;
  for(i=0;i<9;i=i+1)begin
   payload[2+i*8]=0;payload[3+i*8]=0;payload[4+i*8]=0;payload[5+i*8]=0;
   payload[6+i*8]=60;payload[7+i*8]=200;payload[8+i*8]=0;payload[9+i*8]=100;
  end
  transaction(2,21,74,0,9,0);
  begin_song(9,22,1); // BEGIN overwrites payload, restore the event bytes.
  payload[0]=0;payload[1]=0;
  for(i=0;i<9;i=i+1)begin
   payload[2+i*8]=0;payload[3+i*8]=0;payload[4+i*8]=0;payload[5+i*8]=0;
   payload[6+i*8]=60;payload[7+i*8]=200;payload[8+i*8]=0;payload[9+i*8]=100;
  end
  transaction(2,23,74,0,0,9);
  // Mixed score flags accepted, invalid reserved flags rejected.
  begin_song(1,24,128);
  payload[0]=0;payload[1]=0;payload[2]=0;payload[3]=0;payload[4]=0;payload[5]=0;
  payload[6]=195;payload[7]=200;payload[8]=0;payload[9]=228; // flute 67, vel 100
  transaction(2,25,10,0,0,1);
  payload[0]=1;payload[1]=8;payload[2]=0;payload[3]=1;payload[4]=0;payload[5]=0;payload[6]=0;payload[7]=0;
  transaction(1,26,8,0,4,1); // capacity is 2048, independent of the App's former 8192 default
  transaction(8'h44,27,0,0,11,1);
  $display("PASS BT36 real UART v3: ACK CRC/capacity, DATA/END/PLAY retry idempotency, CRC recovery, SD-gated commit/failure, PLAY/STOP mailbox, timeout retry, polyphony/drop flag, mixed event validation, capacity/unknown command rejection");$finish;
 end
 initial begin #100000000;$fatal(1,"BT timeout state=%d ack=%d savewait=%d bytes=%d",dut.state,an,save_wait,stream_count);end
endmodule
`default_nettype wire
