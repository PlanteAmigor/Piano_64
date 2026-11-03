`timescale 1ns/1ps
module tb_reverb_pipeline;
    reg clk=0,rst=0,tick=0,en=1;always #10 clk=~clk;
    reg signed [15:0] l=0,r=0;wire signed [15:0] ol,orr;
    reg [64:0] samples[0:119999];integer i,n;
    fx_reverb dut(.clk(clk),.rst_n(rst),.tick(tick),.enable(en),.in_l(l),.in_r(r),.out_l(ol),.out_r(orr));
    initial begin
        $readmemh("work/reverb_pipeline/samples.hex",samples);
        for(i=0;i<12288;i=i+1)dut.cmem[i]=0;
        for(i=0;i<1792;i=i+1)begin dut.amem_l[i]=0;dut.amem_r[i]=0;end
        repeat(5)@(negedge clk);rst=1;
        for(n=0;n<120000;n=n+1)begin
            {en,l,r}=samples[n][64:32];tick=1;@(negedge clk);tick=0;
            repeat(127)@(negedge clk);
            if(dut.st!==0 || {ol,orr}!==samples[n][31:0])
                $fatal(1,"sample %0d state%0d got %h %h expected %h",n,dut.st,ol,orr,samples[n][31:0]);
        end
        $display("PASS reverb pipeline: 120000 stereo samples exact against independent modulo-address/saturating oracle; full-scale DC, sign reversal, random input, bypass transitions, 50000-sample silence tail; completes within 128 cycles");$finish;
    end
    initial begin #400000000;$fatal(1,"reverb pipeline timeout");end
endmodule
