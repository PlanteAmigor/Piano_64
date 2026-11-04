`timescale 1ns/1ps
// Entire production UI + PLL + encoder + serializer, without page/RGB forcing.
module tb_ui_serial_boot;
 reg clk=0,resetn=1;always #10 clk=~clk;
 hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),
  .SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),
  .SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
 function automatic is_ctrl(input [9:0] v);
  is_ctrl=v==10'b1101010100 || v==10'b0010101011 || v==10'b0101010100 || v==10'b1010101011;
 endfunction
 function automatic [7:0] decode(input [9:0] v);
  reg [7:0] q,b;integer j;
  begin q=v[7:0]^{8{v[9]}};b[0]=q[0];for(j=1;j<8;j=j+1)b[j]=v[8]?(q[j]^q[j-1]):~(q[j]^q[j-1]);decode=b;end
 endfunction
 reg [9:0] s0=0,s1=0,s2=0;reg aligned=0,active=0,reset_done=0,request_reset=0;
 integer bits=0,pixels=0,lit=0,lines=0;
 always @(dut.clk_p5)begin : rx
  #0.05;
  if(!dut.rst_n || !resetn)begin aligned=0;active=0;bits=0;pixels=0;lit=0;lines=0;end
  else if(!request_reset || reset_done)begin
   if(dut.tmds_d_n_0!==~dut.tmds_d_p_0 || dut.tmds_clk_n_0!==~dut.tmds_clk_p_0)$fatal(1,"UI lane polarity");
   s0={dut.tmds_d_p_0[0],s0[9:1]};s1={dut.tmds_d_p_0[1],s1[9:1]};s2={dut.tmds_d_p_0[2],s2[9:1]};
   if(!aligned)begin if(is_ctrl(s0) && s1==10'b1101010100 && s2==10'b1101010100)begin aligned=1;bits=0;end end
   else begin
    bits=bits+1;
    if(bits==10)begin
     bits=0;
     if(is_ctrl(s0))begin
      if(s1!=10'b1101010100 || s2!=10'b1101010100)$fatal(1,"UI control alignment");
      if(active)begin
       if(pixels!=1920 || lit<1000)$fatal(1,"UI serial width/nonblack %0d/%0d",pixels,lit);
       active=0;pixels=0;lit=0;lines=lines+1;
       if(lines==4)begin
        if(!reset_done)request_reset=1;
        else begin $display("PASS complete UI serial natural boot: real production PLL/DPB/TMDS/OSER10 models, four 1920-pixel nonblack UI lines at power-up and after external reset; no forced clocks, page, fade, counters or RGB");$finish;end
       end
      end
     end else begin
      if(is_ctrl(s1) || is_ctrl(s2))$fatal(1,"UI data alignment");
      active=1;pixels=pixels+1;
      if({decode(s2),decode(s1),decode(s0)}!=0)lit=lit+1;
     end
    end
   end
  end
 end
 initial begin wait(request_reset);@(negedge clk);resetn=0;#500;resetn=1;reset_done=1;end
 initial begin #3000000;$fatal(1,"UI serial natural boot timeout");end
endmodule
