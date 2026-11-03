`timescale 1ns/1ps
module tb_component_bars;
    reg clk=0,rst_n=0,tick=0,clear=0,valid=0;
    reg [6:0] index=0;
    reg [7:0] amplitude=0;
    wire [511:0] bars;
    ui_component_bars #(.FALL_STEP(3)) dut(.*);
    always #5 clk=~clk;
    integer golden[0:63];
    integer pair_first=0,fall_count=0,n,k,peak_value,peaks=0,clears=0,falls=0;
    reg [511:0] previous;
    reg [31:0] rng=32'hc0641080;
    // Independent sequential reference: update a selected bar directly,
    // without any of the DUT's pipelined comparators or enable decoding.
    always @(posedge clk)begin
        for(k=0;k<64;k=k+1)previous[k*8+:8]=golden[k];
        if(!rst_n)begin
            for(k=0;k<64;k=k+1)golden[k]=0;
            previous=0;pair_first=0;fall_count=0;
        end else begin
            if(tick)begin
                fall_count=fall_count+1;
                if(fall_count==3)begin
                    fall_count=0;falls=falls+1;
                    for(k=0;k<64;k=k+1)if(golden[k]>0)golden[k]=golden[k]-1;
                end
            end
            if(clear)begin for(k=0;k<64;k=k+1)golden[k]=0;clears=clears+1;end
            if(valid)begin
                if(!index[0])pair_first=amplitude;
                else begin
                    peak_value=amplitude>pair_first?amplitude:pair_first;
                    // Compare against the value before this edge, as in the
                    // original design when clear/decay and a peak coincide.
                    if(peak_value>previous[index[6:1]*8+:8])golden[index[6:1]]=peak_value;
                    pair_first=0;peaks=peaks+1;
                end
            end
        end
        #1;if(bars!==previous)$fatal(1,"component display mismatch: cycle=%0d",n);
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(n=0;n<10000;n=n+1)begin
            @(negedge clk);
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            tick=rng[0];clear=rng[7:3]==0;valid=rng[2];
            index=rng[14:8];amplitude=rng[23:16];
            if(n==4500)rst_n=0;if(n==4503)rst_n=1;
        end
        @(negedge clk);valid=0;clear=0;tick=0;
        repeat(3)@(negedge clk);
        if(peaks<1000 || clears<100 || falls<100)$fatal(1,"insufficient event coverage");
        $display("PASS component peak display: all 64 bars, 10000 random cycles, paired peaks, decay, clear/reset collisions, exact one-cycle-delayed reference");
        $finish;
    end
endmodule
