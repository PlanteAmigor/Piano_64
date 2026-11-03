`timescale 1ns/1ps
module tb_soft_limiter;
    reg clk=0,rst_n=0;always #10 clk=~clk;
    reg signed [31:0] sample=0;wire signed [15:0] limited;
    audio_soft_limiter dut(.clk(clk),.rst_n(rst_n),.sample(sample),.limited(limited));
    reg signed [15:0] expected[0:4];integer n,j,checks=0;
    reg [31:0] rng=32'h76532049;
    function signed [15:0] reference;
        input signed [31:0] s;
        reg [63:0] ax,d,y;
        begin
            ax=s<0?-$signed({s[31],s}):s;
            if(ax<=24000)y=ax;
            else begin d=ax-24000;if(d>16384)d=16384;y=24000+d-((d*d)>>15);end
            if(y>32767)y=32767;
            reference=s<0?-$signed(y[15:0]):$signed(y[15:0]);
        end
    endfunction
    always @(posedge clk)begin
        if(!rst_n)for(j=0;j<5;j=j+1)expected[j]=0;
        else begin
            for(j=4;j>0;j=j-1)expected[j]=expected[j-1];
            expected[0]=reference(sample);
            #1;if(limited!==expected[4])$fatal(1,"curve mismatch sample%0d got%0d expected%0d",sample,limited,expected[4]);
            checks=checks+1;
        end
    end
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        // Exhaust all possible 16-bit samples at every original instrument gain.
        for(n=-32768;n<32768;n=n+1)begin
            @(negedge clk);sample=n*2;
            @(negedge clk);sample=n*8;
            @(negedge clk);sample=n*16;
        end
        for(n=0;n<4096;n=n+1)begin
            @(negedge clk);rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};sample=rng;
        end
        @(negedge clk);sample=32'sh80000000;
        @(negedge clk);sample=32'sh7fffffff;
        repeat(7)@(negedge clk);
        $display("PASS audio limiter: 196608 exhaustive gain-scaled samples, random full-width extremes, exact original knee curve and pipeline latency");$finish;
    end
endmodule
