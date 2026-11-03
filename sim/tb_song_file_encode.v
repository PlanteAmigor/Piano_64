`timescale 1ns/1ps
`default_nettype none
module tb_song_file_encode;
 parameter integer COUNT=1,FLAGS=0;
 reg clk=0,rst_n=0,start=0,ready=0;
 always #10 clk=~clk;
 wire [10:0] addr;reg [63:0] word_q;
 reg [63:0] events[0:2047];reg [7:0] expected[0:17115];
 wire valid,done;wire [7:0] data;wire [15:0] size;
 integer i,n=0,seed=64;
 song_file_encode dut(.clk(clk),.rst_n(rst_n),.start(start),.count(16'(COUNT)),
  .duration_ms(32'(COUNT*250)),.timbre(2'd0),.flags(8'(FLAGS)),.read_addr(addr),.read_data(word_q),
  .valid(valid),.ready(ready),.data(data),.done(done),.file_size(size));
 always @(posedge clk)word_q<=events[addr];
 always @(negedge clk)ready<=($random(seed)&7)!=0;
 always @(posedge clk)if(valid && ready)begin
  if(data!==expected[n])$fatal(1,"encoded byte %d actual=%h expected=%h state=%d pos=%d",n,data,expected[n],dut.state,dut.pos);
  n=n+1;
 end
 initial begin
  $readmemh("work/bt_store/encode_events.hex",events);
  $readmemh("work/bt_store/encode_expected.hex",expected);
  repeat(10)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);if(n!=size)$fatal(1,"file size %d %d",n,size);
  $display("PASS v3 file encoder: %0d events, flags %h, %0d exact bytes, synchronous event RAM and random downstream stalls",COUNT,FLAGS,n);$finish;
 end
 initial begin #100000000;$fatal(1,"encoder timeout");end
endmodule
`default_nettype wire
