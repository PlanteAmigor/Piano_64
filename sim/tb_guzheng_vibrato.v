`timescale 1ns/1ps
`default_nettype none
module tb_guzheng_vibrato;
    reg clk=0,rst_n=0,trig=0,vib=0;
    always #10 clk=~clk;
    reg [9:0] cnt=0;
    always @(posedge clk) if(!rst_n)cnt<=0;else cnt<=cnt+1'b1;
    wire tick=(cnt==0);
    wire signed [15:0] wet,dry;
    add_engine8 #(.NVOICE(1),.USE_DDR(0),.ROM_AW(14),.ROM_DEPTH(11264),.MIX_SHIFT(0)) modulated (
        .clk(clk),.rst_n(rst_n),.clk100(clk),.rst100_n(rst_n),
        .app_rdy(1'b0),.app_rd_data_valid(1'b0),.app_rd_data(256'd0),
        .v_note(7'd62),.v_trig(trig),.v_gate(1'b1),.v_vel(8'd160),
        .bend_q14(16'd16384),.vib_en(vib),.art_en(1'b0),.stop_hold(1'b0),
        .sustain(1'b0),.timbre(1'b1),.sample_tick(tick),.sample_l(wet)
    );
    add_engine8 #(.NVOICE(1),.USE_DDR(0),.ROM_AW(14),.ROM_DEPTH(11264),.MIX_SHIFT(0)) reference (
        .clk(clk),.rst_n(rst_n),.clk100(clk),.rst100_n(rst_n),
        .app_rdy(1'b0),.app_rd_data_valid(1'b0),.app_rd_data(256'd0),
        .v_note(7'd62),.v_trig(trig),.v_gate(1'b1),.v_vel(8'd160),
        .bend_q14(16'd16384),.vib_en(1'b0),.art_en(1'b0),.stop_hold(1'b0),
        .sustain(1'b0),.timbre(1'b1),.sample_tick(tick),.sample_l(dry)
    );
    integer n=0,changed=0,lo=65535,hi=0;
    initial begin
        repeat(8)@(negedge clk);rst_n=1;repeat(2048)@(negedge clk);
        trig=1;@(negedge clk);trig=0;
        wait(modulated.g_voice[0].u_v.ready);repeat(4096)@(negedge clk);vib=1;
        while(n<11000)begin
            @(negedge clk);
            if(tick)begin
                n=n+1;if(wet!=dry)changed=changed+1;
                if(modulated.bend_gz<lo)lo=modulated.bend_gz;
                if(modulated.bend_gz>hi)hi=modulated.bend_gz;
            end
            if(modulated.g_voice[0].u_v.p==0 && modulated.g_voice[0].u_v.s==1 &&
               modulated.bend_gz!=16384 && modulated.g_voice[0].c_d0!=0 &&
               modulated.g_voice[0].u_v.inc_b==modulated.g_voice[0].c_d0)
               $fatal(1,"vibrato did not reach oscillator increments");
        end
        if(lo<15860||lo>15900||hi<16800||hi>16910||changed<9000)$fatal(1,"inaudible modal modulation range %d..%d changed=%d",lo,hi,changed);
        vib=0;repeat(5)@(negedge clk);
        if(modulated.bend_gz!=16384)$fatal(1,"vibrato return detuned");
        $display("PASS guzheng real modal PCM: 5Hz bend %0d..%0d reaches oscillator, %0d/11000 samples differ from dry, neutral after gesture",lo,hi,changed);$finish;
    end
    initial begin #300000000;$fatal(1,"guzheng timeout");end
endmodule
`default_nettype wire
