`timescale 1ns/1ps
module tb_link;
 reg clk=0,rst=0;always #10 clk=~clk;
 wire cp,cn,tx;wire[2:0] dp,dn;
 hdmi_link_probe #(.WINDOW(5000)) dut(.CLOCK_50(clk),.RESET_n(rst),.UART_TX(tx),
  .tmds_clk_p_0(cp),.tmds_clk_n_0(cn),.tmds_d_p_0(dp),.tmds_d_n_0(dn));
 initial begin #1000;rst=1;wait(request_reset);@(negedge clk);rst=0;#500;rst=1;reset_tested=1;end
`ifdef PROBE_720P
 localparam HA=1280,HT=1650,HW=40;
 real want_pixel=13.333333,want_serial=2.666667;
`else
 localparam HA=1920,HT=2200,HW=44;
 real want_pixel=6.734007,want_serial=1.346801;
`endif
 function automatic is_ctrl(input [9:0] v);
  is_ctrl=(v==10'b1101010100 || v==10'b0010101011 || v==10'b0101010100 || v==10'b1010101011);
 endfunction
 function automatic [7:0] decode(input [9:0] v);
  reg[7:0] q,b;integer j;
  begin q=v[7:0]^{8{v[9]}};b[0]=q[0];for(j=1;j<8;j=j+1)b[j]=v[8]?(q[j]^q[j-1]):~(q[j]^q[j-1]);decode=b;end
 endfunction
 function automatic [23:0] palette(input integer ix);
  begin
   if(ix<HA/8)palette=24'hffffff;else if(ix<HA/4)palette=24'hffff00;
   else if(ix<HA*3/8)palette=24'h00ffff;else if(ix<HA/2)palette=24'h00ff00;
   else if(ix<HA*5/8)palette=24'hff00ff;else if(ix<HA*3/4)palette=24'hff0000;
   else if(ix<HA*7/8)palette=24'h0000ff;else palette=0;
  end
 endfunction
 reg[9:0] s0=0,s1=0,s2=0;
 reg aligned=0,active=0,had_line=0,freq_checked=0,reset_tested=0,request_reset=0;
 integer bits=0,visible=0,blank=0,hs_count=0,lines=0,words=0;
 reg[23:0] rgb;
 always @(dut.serial_clk)begin : serial_sample
  #0.05;
  if(rst && !dut.video_reset && (!request_reset || reset_tested))begin
   if(dn!==~dp || cn!==~cp)$fatal(1,"differential polarity invalid");
   s0={dp[0],s0[9:1]};s1={dp[1],s1[9:1]};s2={dp[2],s2[9:1]};
   if(!aligned)begin
    if(s0==10'b1101010100 && s1==10'b1101010100 && s2==10'b1101010100)begin aligned=1;bits=0;end
   end else begin
    bits=bits+1;
    if(bits==10)begin
     bits=0;words=words+1;
     if(is_ctrl(s0))begin
      if(s1!=10'b1101010100 || s2!=10'b1101010100)$fatal(1,"control symbols not aligned across channels");
      if(active)begin
       if(visible!=HA)$fatal(1,"visible width %0d expected %0d",visible,HA);
       active=0;had_line=1;lines=lines+1;blank=0;hs_count=0;
      end
      blank=blank+1;
      if(s0==10'b0010101011 || s0==10'b1010101011)hs_count=hs_count+1;
     end else begin
      if(is_ctrl(s1) || is_ctrl(s2))$fatal(1,"data symbols not aligned across channels");
      if(!active)begin
       if(had_line && (blank!=HT-HA || hs_count!=HW))$fatal(1,"blank/sync width %0d/%0d expected %0d/%0d",blank,hs_count,HT-HA,HW);
       if(lines>=4)begin
        if(!freq_checked)$fatal(1,"frequency check missing");
        if(!reset_tested)begin
         request_reset=1;aligned=0;active=0;had_line=0;bits=0;visible=0;blank=0;hs_count=0;lines=0;
         disable serial_sample;
        end else begin
         $display("PASS independent serial TMDS receiver: %0d active pixels, %0d total pixels, %0d HS pixels; four complete colorbar lines at boot and after external reset, RGB order, lane polarity, native PLL/OSER10/CLKDIV models",HA,HT,HW);$finish;
        end
       end
       active=1;visible=0;
      end
      rgb={decode(s2),decode(s1),decode(s0)};
      if(rgb!==palette(visible))begin
       $display("DBG x%0d y%0d por%0d de%b input%h encoded%h disp%h tmds%h shift%h/%h/%h",dut.x,dut.y,dut.video_por,dut.de,dut.rgb,dut.video.gen_enc[0].dvi_tx_tmds_enc_inst.encoded,dut.video.gen_enc[0].dvi_tx_tmds_enc_inst.disparity,dut.video.tmds_enc,s0,s1,s2);
       $fatal(1,"RGB mismatch at pixel%0d got%h expected%h",visible,rgb,palette(visible));end
      visible=visible+1;
     end
    end
   end
  end
 end
 realtime p0,s0t;real pp,sp;
 initial begin
  wait(dut.lock);repeat(300)@(posedge dut.pixel);
  fork
   begin @(posedge dut.pixel);p0=$realtime;repeat(100)@(posedge dut.pixel);pp=($realtime-p0)/100;end
   begin @(posedge dut.serial_clk);s0t=$realtime;repeat(500)@(posedge dut.serial_clk);sp=($realtime-s0t)/500;end
  join
  if(pp<want_pixel-0.02 || pp>want_pixel+0.02 || sp<want_serial-0.004 || sp>want_serial+0.004)$fatal(1,"clock periods wrong %f %f",pp,sp);
  freq_checked=1;
 end
 initial begin #1000000;$fatal(1,"no valid complete HDMI lines");end
endmodule
