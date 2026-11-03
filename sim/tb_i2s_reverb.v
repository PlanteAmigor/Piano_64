`timescale 1ns/1ps
`default_nettype none
// Check the bits seen by the DAC, using actual reverb output during I2S transfer.
module tb_i2s_reverb;
 reg clk=0,rst_n=0;always #10 clk=~clk;
 reg signed [15:0] in_l=0,in_r=0;
 wire signed [15:0] wet_l,wet_r;
 wire tick,bck,lrck,din;
 fx_reverb fx(.clk(clk),.rst_n(rst_n),.tick(tick),.enable(1'b1),
  .in_l(in_l),.in_r(in_r),.out_l(wet_l),.out_r(wet_r));
 pcm5102a_tx tx(.clk(clk),.rst_n(rst_n),.sample_l(wet_l),.sample_r(wet_r),
  .sample_tick(tick),.bck(bck),.lrck(lrck),.din(din));
 integer i,n=0,frames=0,errors=0,checked=0,midword_changes=0,wet_active=0;
 reg signed[15:0] expect_l=0,expect_r=0,prev_wet=0;
 reg expected_valid=0;
 // Testbench initialization models FPGA power-up contents only; no forced output.
 initial begin
  for(i=0;i<12288;i=i+1)fx.cmem[i]=0;
  for(i=0;i<1792;i=i+1)begin fx.amem_l[i]=0;fx.amem_r[i]=0;end
  repeat(8)@(negedge clk);rst_n=1;
  repeat(3000)begin
   @(posedge tick);@(negedge clk);
   in_l=(n%2)?-30000:30000;
   in_r=(n%3)?-12000:25000;
   n=n+1;
  end
  repeat(1100)@(negedge clk);
  $display("I2S checked=%0d torn_words=%0d live_updates=%0d wet_samples=%0d",checked,errors,midword_changes,wet_active);
  if(checked<5980||midword_changes<1000||wet_active<100)$fatal(1,"insufficient real reverb activity");
  if(errors)$fatal(1,"DAC received words assembled from different audio samples");
  $display("PASS I2S reverb: complete stereo frames remain intact while actual reverb updates mid-word");$finish;
 end
 // At the left frame boundary, both channels must belong to the same snapshot.
 always@(posedge clk)if(rst_n)begin
  if(tx.bck_fall && tx.slot==63)begin
   expect_l<=wet_l;expect_r<=wet_r;expected_valid<=1;frames<=frames+1;
  end
  if(wet_l!=prev_wet && tx.slot>=1 && tx.slot<=16)midword_changes<=midword_changes+1;
  prev_wet<=wet_l;
  if(fx.st==9 && fx.ap_l!=0)wet_active<=wet_active+1;
 end
 // Independent pin receiver: LRCK transition occupies the one-bit I2S delay.
 reg prev_lrck=0,active=0;
 reg [15:0] word=0;
 integer bit_count=0;
 always@(posedge bck)begin
  if(!rst_n)begin prev_lrck=lrck;active=0;bit_count=0;end
  else if(lrck!=prev_lrck)begin
   prev_lrck=lrck;bit_count=0;word=0;
   if(!lrck && expected_valid)active=1;
  end else if(active && bit_count<16)begin
   word={word[14:0],din};bit_count=bit_count+1;
   if(bit_count==16)begin
    checked=checked+1;
    if(word!==(lrck?expect_r:expect_l))begin
     if(errors<5)$display("torn frame=%0d channel=%0d expected=%0d got=%0d",frames,lrck,$signed(lrck?expect_r:expect_l),$signed(word));
     errors=errors+1;
    end
   end
  end
 end
 // Both channel slots retain one delay bit and 15 zero padding bits.
 always @(posedge bck) if(rst_n && expected_valid) begin
  if((tx.slot[4:0]==0 || tx.slot[4:0]>16) && din!==1'b0)
   $fatal(1,"I2S padding or delay bit corrupt");
 end
 integer tick_cycles=0;
 reg saw_tick=0;
 always @(posedge clk) if(!rst_n)begin tick_cycles<=0;saw_tick<=0;end
 else begin
  tick_cycles<=tick_cycles+1;
  if(tick)begin
   if(saw_tick && tick_cycles!=1023)$fatal(1,"sample cadence changed");
   tick_cycles<=0;saw_tick<=1;
  end
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
