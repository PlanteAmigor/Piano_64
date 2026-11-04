`timescale 1ns/1ps
// No page, brightness, counter, or RGB forcing: exercise configuration startup.
module tb_ui_natural_boot;
 reg clk=0,resetn=1;always #3.333333 clk=~clk;
 hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),
  .SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),
  .SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
 task check_lines;
  integer line,pixels,lit;
  begin
   wait(dut.rst_n);@(negedge clk);
   if(dut.page_show!==0 || dut.fade_lvl!==15)$fatal(1,"natural boot page/brightness");
   for(line=0;line<4;line=line+1)begin
    wait(dut.vis_d9);pixels=0;lit=0;
    while(dut.vis_d9)begin
     @(negedge clk);
     if(dut.vis_d9)begin
      if((^dut.rgb_r)===1'bx)$fatal(1,"unknown natural output pixel");
      pixels=pixels+1;if(dut.rgb_r!=0)lit=lit+1;
     end
    end
    // The entry pixel precedes our first sampling edge.
    if(pixels<1919 || pixels>1920 || lit<1000)$fatal(1,"natural boot line width=%0d lit=%0d",pixels,lit);
   end
  end
 endtask
 initial begin
  check_lines;
  @(negedge clk);resetn=0;repeat(4)@(negedge clk);resetn=1;
  check_lines;
  $display("PASS UI natural boot: no externally asserted startup reset, no forced page/brightness/counters/RGB; four nonblack 1080p lines at boot and after external reset");$finish;
 end
 initial begin #3000000;$fatal(1,"natural boot timeout");end
endmodule
