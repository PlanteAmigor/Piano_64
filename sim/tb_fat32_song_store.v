`timescale 1ns/1ps
`default_nettype none
module tb_fat32_song_store;
 parameter integer COUNT=140,INJECT=0,EXPECT_ERROR=0;
 reg clk=0,rst_n=0,start=0;always #10 clk=~clk;
 wire busy,done,stream_start,stream_valid,stream_ready;
 wire [7:0] error,saved_id,stream_data,wdata;
 wire [15:0] file_size;
 wire [10:0] event_addr;reg [63:0] event_data;
 reg [63:0] events[0:2047];
 wire req,wr;wire [31:0] sector;
 reg ready=1,io_done=0,rvalid=0;reg [7:0] io_error=0,rdata=0;
 reg [8:0] raddr=0,waddr=0;
 reg [7:0] block[0:511];
 integer fd,trace,rc,i,n=0,phase=0,delay=0,write_count=0,seed=64;
 reg write_q=0;reg [31:0] sector_q=0;
 fat32_song_store dut(.clk(clk),.rst_n(rst_n),.start(start),.file_size(file_size),
  .busy(busy),.done(done),.error(error),.saved_id(saved_id),.stream_start(stream_start),
  .stream_valid(stream_valid),.stream_data(stream_data),.stream_ready(stream_ready),
  .io_request(req),.io_write(wr),.io_sector(sector),.io_ready(ready),.io_done(io_done),.io_error(io_error),
  .rvalid(rvalid),.raddr(raddr),.rdata(rdata),.waddr(waddr),.wdata(wdata));
 song_file_encode enc(.clk(clk),.rst_n(rst_n),.start(stream_start),.count(16'(COUNT)),
  .duration_ms(32'(COUNT*250)),.timbre(2'd0),.flags(8'd0),.read_addr(event_addr),.read_data(event_data),
  .valid(stream_valid),.ready(stream_ready),.data(stream_data),.done(),.file_size(file_size));
 always @(posedge clk)event_data<=events[event_addr];
 always @(posedge clk)begin
  rvalid<=0;io_done<=0;
  case(phase)
   0:if(req && ready)begin
    ready<=0;write_q<=wr;sector_q<=sector;io_error<=0;n=0;waddr<=0;delay=0;
    if(!wr)begin
     rc=$fseek(fd,sector*512,0);rc=$fread(block,fd,0,512);
     if(rc!=512)$fatal(1,"read beyond image sector=%d",sector);
     phase=1;
    end else phase=2;
   end
   1:if(($random(seed)&3)!=0)begin
    rvalid<=1;raddr<=n;rdata<=block[n];
    if(n==511)begin phase=4;delay=0;end else n=n+1;
   end
   2:if(delay==3)begin
    block[n]=wdata;delay=0;
    if(n==511)phase=3;else begin n=n+1;waddr<=n;end
   end else delay=delay+1;
   3:begin
    if(INJECT==1 && write_count==0)io_error<=4;
    else begin
     if(INJECT==2 && write_count==0)block[127]=block[127]^8'h40;
     rc=$fseek(fd,sector_q*512,0);
     for(i=0;i<512;i=i+1)$fwrite(fd,"%c",block[i]);
     $fflush(fd);$fdisplay(trace,"%0d",sector_q);write_count=write_count+1;
    end
    phase=4;delay=0;
   end
   4:if(delay==8)begin io_done<=1;phase=5;end else delay=delay+1;
   5:begin ready<=1;phase=0;end
  endcase
 end
 initial begin
  fd=$fopen("work/bt_store/fat.img","r+b");if(!fd)$fatal(1,"image open");
  trace=$fopen("work/bt_store/fat_write_trace.txt","w");
  $readmemh("work/bt_store/encode_events.hex",events);
  repeat(10)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(error!=EXPECT_ERROR)$fatal(1,"store result %d expected=%d state=%d count=%d",error,EXPECT_ERROR,dut.state,dut.allocated_count);
  $fclose(fd);$fclose(trace);
  $display("PASS FAT32 store: result=%0d id=%h events=%0d verified sector writes=%0d",error,saved_id,COUNT,write_count);$finish;
 end
 initial begin #100000000;$fatal(1,"store timeout state=%d purpose=%d sector=%d alloc=%d needed=%d",dut.state,dut.purpose,sector,dut.allocated_count,dut.total_needed);end
endmodule
`default_nettype wire
