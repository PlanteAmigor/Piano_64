`timescale 1ns/1ps
`include "src/hdmi/ui_video_mode.vh"
`default_nettype none
module tb_ui_timing;
    reg clk=0,resetn=0;always #3.367 clk=~clk;
    hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),
        .SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),
        .SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
`ifdef UI_VIDEO_720P
    localparam HT=1650,VT=750,HV=1280,VV=720,HS=40,VS=5,VF=5,VSTART=30;
`else
    localparam HT=2200,VT=1125,HV=1920,VV=1080,HS=44,VS=5,VF=4,VSTART=45;
`endif
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
        if(dut.H_TOTAL!=HT || dut.V_TOTAL!=VT || dut.H_VIS!=HV || dut.V_VIS!=VV)$fatal(1,"selected video frame geometry");
        // Seed just before an active line; let the actual counters and sync logic run.
        force dut.vcnt=VSTART;wait(dut.hcnt==0);@(negedge clk);release dut.vcnt;
        repeat(HT)begin
            @(negedge clk);cycles=cycles+1;
            if(dut.vis)begin
`ifdef UI_VIDEO_720P
                if(dut.px!==12'(pixels+pixels/2) || dut.py!==12'd0)$fatal(1,"720p logical coordinate alignment x=%0d got %0d,%0d",pixels,dut.px,dut.py);
`endif
                pixels=pixels+1;
            end
            if(dut.hsync)hswidth=hswidth+1;
        end
        if(pixels!=HV || hswidth!=HS)$fatal(1,"active/sync widths %0d/%0d",pixels,hswidth);
        // Check the real vertical wrap and positive vertical-sync interval.
        force dut.vcnt=VT-1;wait(dut.hcnt==HT-1);@(negedge clk);release dut.vcnt;
        repeat(3)@(negedge clk);if(dut.vcnt!=0)$fatal(1,"vertical frame wrap");
        force dut.vcnt=VF;repeat(3)@(negedge clk);if(!dut.vsync)$fatal(1,"positive vertical sync");
        force dut.vcnt=VF+VS;repeat(3)@(negedge clk);if(dut.vsync)$fatal(1,"vertical sync end");
        release dut.vcnt;
        $display("PASS native %0dx%0d 60Hz timing: %0dx%0d total, HS=%0d VS=%0d, logical coordinates, frame wrap, RGB/sync pipeline",HV,VV,HT,VT,HS,VS);$finish;
    end
    initial begin #1000000;$fatal(1,"timing timeout");end
endmodule
`default_nettype wire
