`timescale 1ns/1ps
`default_nettype none
// Run the real scope filter, AGC, line rasterizer and persistence RAM.
// Skip display scanning; decay follows audio sample time at 60Hz.
module tb_liss_view;
    parameter integer BEFORE=0;
    parameter integer INST=0;
    reg clk=0,resetn=0,tog=0,trg=0,clear=0,decay=0;
    always #6.667 clk=~clk;
    reg signed [15:0] sample=0;
    reg [18:0] info=0;
    reg [15:0] audio[0:16383];
    hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.UI_INFO(info),
        .BANDS(256'd0),.BANDS_TICK(1'b0),.COMP_AMP(512'd0),
        .SONG_UI(256'd0),.SONG_UI_TOGGLE(1'b0),
        .SCOPE_SMP(sample),.SCOPE_TOG(tog),.SCOPE_TRG(trg));
    integer f,i,j,lit=0;
    reg [1023:0] input_path,output_path;
    initial begin
        if(!$value$plusargs("IN=%s",input_path))$fatal(1,"missing audio");
        if(!$value$plusargs("OUT=%s",output_path))$fatal(1,"missing output");
        $readmemh(input_path,audio);
        force dut.liss_clr=clear;
        force dut.liss_decay=decay;
        force dut.page_show=0;force dut.fade_lvl=15;
        info=(INST<<2)|(BEFORE?0:((3<<7)|(1<<9)));
        repeat(20)@(negedge clk);resetn=1;wait(dut.rst_n);@(negedge clk);
        clear=1;@(negedge clk);clear=0;repeat(4100)@(negedge clk);
        trg=1;
        for(i=0;i<16384;i=i+1)begin
            sample=audio[i];tog=~tog;repeat(256)@(negedge clk);
            if(i%813==812)begin
                decay=1;@(negedge clk);decay=0;repeat(12300)@(negedge clk);
            end
        end
        repeat(1000)@(negedge clk);
        f=$fopen(output_path,"w");
        for(i=0;i<4096;i=i+1)begin
            if((^dut.u_liss.m[i])===1'bx)$fatal(1,"unknown framebuffer");
            for(j=0;j<4;j=j+1)if(dut.u_liss.m[i][j*4+:4]!=0)lit=lit+1;
            $fdisplay(f,"%04x",dut.u_liss.m[i]);
        end
        $fclose(f);
        if(lit<100)$fatal(1,"blank scope");
        $display("PASS real Lissajous pipeline: instrument=%0d before=%0d lit=%0d",INST,BEFORE,lit);$finish;
    end
endmodule
`default_nettype wire
