`timescale 1ns/1ps
module tb_ui_equivalence;
 reg clk=0;always #5 clk=~clk;
 hdmi_ui3_top dut(.clk(clk),.CLK_SCOPE(clk),.resetn(1'b1),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),.SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),.SCOPE_SMP(16'd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
 hdmi_ui3_top_reference reference(.clk(clk),.CLK_SCOPE(clk),.resetn(1'b1),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),.SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),.SCOPE_SMP(16'd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
 reg [8:0] flags;reg [3:0] fade;
 reg high;reg [23:0] bg,lc,nc,tc;
 reg [11:0] h=0,v=0;
 integer i,j,cycles=0;
 function integer edge_y(input integer n);
  case(n) 0:edge_y=0;1:edge_y=255;2:edge_y=256;3:edge_y=879;4:edge_y=880;default:edge_y=4095;endcase
 endfunction
 function integer edge_x(input integer n);
  case(n) 0:edge_x=0;1:edge_x=767;2:edge_x=768;3:edge_x=783;4:edge_x=784;5:edge_x=879;6:edge_x=880;7:edge_x=895;8:edge_x=896;9:edge_x=1791;10:edge_x=1792;default:edge_x=4095;endcase
 endfunction
 // Reapply forces every stimulus cycle; no reliance on simulator force RHS reevaluation.
 task cycle(input integer x,input integer y,input integer overlay,input integer level);
  begin
   @(negedge clk);
   if(cycles>4)begin
    if(dut.rgb!==reference.rgb || dut.rgb_r!==reference.rgb_r)$fatal(1,"palette/fade cycle alignment %d",cycles);
    if(dut.lane_in0!==reference.lane_in0 || dut.roll_area1!==reference.roll_area1)$fatal(1,"roll window cycle alignment %d",cycles);
   end
   flags=overlay;fade=level;high=$random;bg=$random;lc=$random;nc=$random;tc=$random;
   h=x+280;v=y+45;
   force dut.hcnt=h;force reference.hcnt=h;force dut.vcnt=v;force reference.vcnt=v;
   force dut.background3=bg;force reference.background3=bg;
   force dut.liss_color5=lc;force reference.liss_color5=lc;
   force dut.note_color5=nc;force reference.note_color5=nc;
   force dut.text_color5=tc;force reference.text_color5=tc;
   force dut.spectrum5=flags[0];force reference.spectrum5=flags[0];
   force dut.component5=flags[1];force reference.component5=flags[1];
   force dut.liss5=flags[2];force reference.liss5=flags[2];
   force dut.note_auto5=flags[3];force reference.note_auto5=flags[3];
   force dut.note_lead5=flags[4];force reference.note_lead5=flags[4];
   force dut.note_hit5=flags[5];force reference.note_hit5=flags[5];
   force dut.note_edge5=flags[6];force reference.note_edge5=flags[6];
   force dut.judgment5=flags[7];force reference.judgment5=flags[7];
   force dut.text5=flags[8];force reference.text5=flags[8];
   force dut.spectrum_high5=high;force reference.spectrum_high5=high;
   force dut.fade_lvl=fade;force reference.fade_lvl=fade;
   cycles=cycles+1;
  end
 endtask
 initial begin
  for(j=0;j<16;j=j+1)for(i=0;i<512;i=i+1)cycle($random,$random,i,j);
  for(j=0;j<6;j=j+1)for(i=0;i<4096;i=i+1)cycle(i,edge_y(j),i%512,i%16);
  for(j=0;j<12;j=j+1)for(i=0;i<4096;i=i+1)cycle(edge_x(j),i,i%512,i%16);
  for(i=0;i<5;i=i+1)cycle(0,0,0,15);
  $display("PASS real UI equivalence: %0d cycles, all512 overlay priorities at all16 fade levels, random palettes, complete12-bit axes at window boundaries, RGB/fade/window register latency identical",cycles);$finish;
 end
 initial begin #2000000;$fatal(1,"UI equivalence timeout");end
endmodule
