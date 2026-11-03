// Exclusive SD ownership, native sector host and verified FAT32 append.
// The reader is reset before grant; both clocks are low during each handover.
`default_nettype none
module song_sd_save #(parameter integer CLK_HZ=50000000,SIMULATE=0)(
 input wire clk,rst_n,start,input wire [15:0] file_size,
 output reg request,input wire grant,catalog_ready,catalog_error,
 output wire sdclk,inout wire sdcmd,sddat0,
 output wire stream_start,input wire stream_valid,input wire [7:0] stream_data,output wire stream_ready,
 output reg busy,done,output reg [7:0] error,saved_id
);
 reg [2:0] state;reg host_run,store_start;reg [31:0] timer;reg [5:0] quiet;
 wire ready,io_done,rvalid,io_req,io_write,store_done;wire [31:0] sector;
 wire [7:0] io_error,rdata,wdata,store_error,store_id;wire [8:0] raddr,waddr;
 wire host_reset=rst_n && host_run && grant;
 sd_sector_rw #(.CLK_HZ(CLK_HZ),.SIMULATE(SIMULATE)) u_host(
  .clk(clk),.rst_n(host_reset),.sdclk(sdclk),.sdcmd(sdcmd),.sddat0(sddat0),
  .request(io_req),.write_sector(io_write),.sector(sector),.ready(ready),.done(io_done),.error(io_error),
  .waddr(waddr),.wdata(wdata),.rvalid(rvalid),.raddr(raddr),.rdata(rdata));
 fat32_song_store #(.CLK_HZ(CLK_HZ)) u_store(.clk(clk),.rst_n(host_reset),.start(store_start),.file_size(file_size),
  .busy(),.done(store_done),.error(store_error),.saved_id(store_id),
  .stream_start(stream_start),.stream_valid(stream_valid),.stream_data(stream_data),.stream_ready(stream_ready),
  .io_request(io_req),.io_write(io_write),.io_sector(sector),.io_ready(ready),.io_done(io_done),.io_error(io_error),
  .rvalid(rvalid),.raddr(raddr),.rdata(rdata),.waddr(waddr),.wdata(wdata));
 always @(posedge clk)begin
  if(!rst_n)begin state<=0;host_run<=0;store_start<=0;request<=0;busy<=0;done<=0;error<=0;saved_id<=0;timer<=0;quiet<=0;end
  else begin
   store_start<=0;done<=0;
   if(busy)timer<=timer+1'b1;
   case(state)
    0:if(start)begin request<=1;busy<=1;error<=0;timer<=0;state<=1;end
    1:if(grant)begin host_run<=1;state<=2;end
    2:if(ready)begin store_start<=1;state<=3;end
      else if(io_done && io_error!=0)begin error<=24;quiet<=0;state<=4;end
    3:if(store_done)begin error<=store_error;saved_id<=store_id;quiet<=0;state<=4;end
    4:if(host_run)begin
        if(!sdclk)begin host_run<=0;quiet<=0;end
       end else if(quiet==31 && !sdclk)begin request<=0;state<=5;end else quiet<=quiet+1'b1;
    5:if(!grant && catalog_ready)begin
       if(error==0 && catalog_error)error<=27;
       busy<=0;done<=1;state<=0;
      end
   endcase
   // Include acquisition, initialization, data, metadata and catalog refresh
   // in the phone's 5-second ACK budget. No write is retried on a timeout.
   if(busy && timer>=(CLK_HZ/1000)*4200 && state<4)begin error<=26;quiet<=0;state<=4;end
   if(busy && timer>=(CLK_HZ/1000)*4700 && state==5)begin error<=26;busy<=0;done<=1;state<=0;end
  end
 end
endmodule
`default_nettype wire
