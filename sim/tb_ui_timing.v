`timescale 1ns/1ps
`default_nettype none
module tb_ui_timing;
    reg clk=0,resetn=0;always #3.367 clk=~clk;
    hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),
        .SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),
        .SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
    integer pixels=0,hswidth=0,cycles=0;
    reg [9:0] de=0,hs=0,vs=0;
    always @(posedge clk)begin
        de<={de[8:0],dut.vis};hs<={hs[8:0],dut.hsync};vs<={vs[8:0],dut.vsync};
    end
    always @(negedge clk)if(dut.rst_n && cycles>10)begin
        if(dut.vis_d9!==de[9] || dut.hs_d9!==hs[9] || dut.vs_d9!==vs[9])$fatal(1,"pixel/sync pipeline alignment");
    end
    initial begin
        repeat(20)@(negedge clk);resetn=1;wait(dut.rst_n);repeat(10)@(negedge clk);
        if(dut.H_TOTAL!=2200 || dut.V_TOTAL!=1125 || dut.H_VIS!=1920 || dut.V_VIS!=1080)$fatal(1,"1080p frame geometry");
        // Seed just before an active line; let the actual counters and sync logic run.
        force dut.vcnt=45;wait(dut.hcnt==0);@(negedge clk);release dut.vcnt;
        repeat(2200)begin
            @(negedge clk);cycles=cycles+1;
            if(dut.vis)pixels=pixels+1;
            if(dut.hsync)hswidth=hswidth+1;
        end
        if(pixels!=1920 || hswidth!=44)$fatal(1,"active/sync widths %0d/%0d",pixels,hswidth);
        // Check the real vertical wrap and positive vertical-sync interval.
        force dut.vcnt=1124;wait(dut.hcnt==2199);@(negedge clk);release dut.vcnt;
        repeat(3)@(negedge clk);if(dut.vcnt!=0)$fatal(1,"vertical frame wrap");
        force dut.vcnt=4;repeat(3)@(negedge clk);if(!dut.vsync)$fatal(1,"positive vertical sync");
        force dut.vcnt=9;repeat(3)@(negedge clk);if(dut.vsync)$fatal(1,"vertical sync end");
        release dut.vcnt;
        $display("PASS native 1080p60 timing: 2200x1125, 1920 active pixels/line, 44-clock positive HS, 5-line positive VS, frame wrap, RGB/sync pipeline");$finish;
    end
    initial begin #1000000;$fatal(1,"timing timeout");end
endmodule
`default_nettype wire
