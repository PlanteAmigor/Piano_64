`timescale 1ns/1ps
module tb_hdmi_debug_uart;
 reg clk=0,rst=0;always #10 clk=~clk;
 wire tx;wire[1:0]mode;
 hdmi_debug_uart dut(.clk(clk),.resetn(rst),.info(96'h123456789abcdef001234567),.mode(mode),.tx(tx));
 reg[215:0]expected={"D123456789ABCDEF001234567",8'h0d,8'h0a};
 reg[7:0]data;integer i,b;
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(i=0;i<27;i=i+1)begin
   @(negedge tx);#13020;
   for(b=0;b<8;b=b+1)begin data[b]=tx;#8680;end
   if(tx!==1'b1)$fatal(1,"diagnostic UART stop bit");
   if(data!==expected[215-i*8-:8])$fatal(1,"diagnostic UART byte %0d got%h",i,data);
  end
  $display("PASS diagnostic UART: independent 115200 8N1 pin receiver, complete 96-bit status with all hex digits and CRLF");$finish;
 end
 initial begin #50000000;$fatal(1,"diagnostic UART timeout");end
endmodule
