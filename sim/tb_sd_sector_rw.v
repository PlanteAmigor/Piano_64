`timescale 1ns/1ps
`default_nettype none
module tb_sd_sector_rw;
 reg clk=0,rst_n=0,request=0,write_mode=0,reject=0;
 always #10 clk=~clk;
 wire sdclk,ready,done,rvalid;tri1 cmd;tri1 [3:0] dat;
 reg [31:0] sector=0;wire [7:0] error,rdata;wire [8:0] raddr,waddr;
 reg [7:0] wdata;
 reg [7:0] tx_buffer[0:511];reg [7:0] disk[0:4095];
 wire rdreq,wrvalid;wire [39:0] rdaddr;reg [15:0] rddata;
 wire [31:0] wrsector;wire [8:0] wraddr;wire [7:0] wrbyte;
 integer i,count=0,writes=0;reg expect_new=0;
 sd_sector_rw #(.SIMULATE(1)) dut(.clk(clk),.rst_n(rst_n),.sdclk(sdclk),.sdcmd(cmd),.sddat0(dat[0]),
  .request(request),.write_sector(write_mode),.sector(sector),.ready(ready),.done(done),.error(error),
  .waddr(waddr),.wdata(wdata),.rvalid(rvalid),.raddr(raddr),.rdata(rdata));
 always @(posedge clk)begin
  wdata<=tx_buffer[waddr];
  if(rvalid)begin
   if(rdata!==(expect_new?tx_buffer[raddr]:disk[sector*512+raddr]))$fatal(1,"read mismatch %d %h",raddr,rdata);
   count=count+1;
  end
 end
 sd_fake_rw card(.rstn_async(rst_n),.sdclk(sdclk),.sdcmd(cmd),.sddat(dat),
  .rdreq(rdreq),.rdaddr(rdaddr),.rddata(rddata),.reject_write(reject),
  .wrvalid(wrvalid),.wrsector(wrsector),.wraddr(wraddr),.wrbyte(wrbyte));
 always @(posedge sdclk)begin
  if(rdreq)rddata<={disk[rdaddr*2+1],disk[rdaddr*2]};
  if(wrvalid)begin disk[wrsector*512+wraddr]<=wrbyte;writes=writes+1;end
 end
 task operation(input wr,input [31:0] lba);
 begin
  wait(ready);@(negedge clk);sector=lba;write_mode=wr;request=1;
  @(negedge clk);request=0;wait(done);@(negedge clk);
 end endtask
 initial begin
  for(i=0;i<4096;i=i+1)disk[i]=(i*31)^8'h96;
  for(i=0;i<512;i=i+1)tx_buffer[i]=(i*19)^(i>>3)^8'h53;
  repeat(20)@(negedge clk);rst_n=1;
  operation(0,3);if(error || count!=512)$fatal(1,"initial read %d %d",error,count);
  operation(1,3);if(error || writes!=512)$fatal(1,"write %d %d",error,writes);
  for(i=0;i<512;i=i+1)if(disk[1536+i]!==tx_buffer[i])$fatal(1,"stored mismatch byte %d",i);
  count=0;expect_new=1;operation(0,3);if(error || count!=512)$fatal(1,"readback %d %d",error,count);
  reject=1;operation(1,4);if(error!=4 || writes!=512)$fatal(1,"write CRC rejection %d %d",error,writes);
  $display("PASS native SD sector: real CMD/DAT, full 512-byte write CRC/status/busy/CMD13, exact readback, rejected write leaves disk intact");$finish;
 end
 initial begin #100000000;$fatal(1,"timeout cmdstate=%d phase=%d count=%d model=%d",dut.state,dut.phase,dut.bit_count,card.wphase);end
endmodule
`default_nettype wire
