// Capture the actual HDMI RGB pipeline, bypassing only vendor PLL/DVI cells.
`timescale 1ns/1ps
`default_nettype none
module tb_song_ui;
    parameter integer SHOT=0;
    reg clk=0,scope_clk=0,resetn=0,toggle=0;
    always #10 scope_clk=~scope_clk;
    always #3.367 clk=~clk;
    reg [383:0] status=0;
    reg [1023:0] roll=0;
    reg [255:0] bands=0;reg [511:0] components=0;
    reg signed [15:0] sample=0;reg scope_tog=0,scope_trg=0;
    integer audio_div=0,audio_n=0,j;
    always @(negedge clk)begin
     if(audio_div==3040)begin audio_div=0;audio_n=audio_n+1;sample=$rtoi(20000*$sin(6.283185307*440*audio_n/48828.125));scope_tog=~scope_tog;end
     else audio_div=audio_div+1;
    end
    wire ack;
    hdmi_ui3_top dut (
        .CLK_SCOPE(scope_clk),.clk(clk),.resetn(resetn),.BANDS(bands),.BANDS_TICK(1'b0),.UI_INFO(19'd2),
        .SONG_UI(status),.SONG_ROLL(roll),.SONG_UI_TOGGLE(toggle),.SONG_UI_ACK(ack),
        .COMP_AMP(components),.SCOPE_SMP(sample),.SCOPE_TOG(scope_tog),.SCOPE_TRG(scope_trg)
    );
    integer f,x=0,y=0;
    reg capture=0;
    reg [1023:0] output_path;
    initial begin
        if(!$value$plusargs("OUT=%s",output_path)) output_path="work/song_checks/ui.ppm";
        f=$fopen(output_path,"wb");if(!f) $fatal(1,"UI output");
        $fwrite(f,"P6\n1920 1080\n255\n");
        repeat(20) @(negedge clk);resetn=1;repeat(30) @(negedge clk);
        for(j=0;j<32;j=j+1)bands[j*8+:8]=(j%8==0?220:40+j*3);
        for(j=0;j<64;j=j+1)components[j*8+:8]=220-j*3;
        status[315:308]=170;status[307]=1;status[306:299]=8'b10100101;
        status[287:256]=30000;status[298:288]=400;
        for(j=0;j<16;j=j+1)roll[j*32+:32]={1'b1,1'b1,j==0,2'(j%4),4'(j%8),11'(256+j*32),11'(320+j*32),1'b0};
        status[31:0]=32'h03020104;status[132:128]=4;status[136:133]=1;status[232]=1;
        case(SHOT)
            1:begin status[139:137]=1;status[140]=1;end
            2:begin status[139:137]=3;status[140]=1;status[143:142]=3;status[150:144]=7'b0000101;status[157:151]=1;end
            3:begin status[139:137]=4;status[165:158]=1;end
            4:begin status[132:128]=0;status[232]=0;end
            5,6:begin end
            7:begin status[139:137]=3;status[140]=0;status[197:166]=12000;end
            8:begin status[139:137]=3;status[140]=1;status[197:166]=12000;status[150:144]=7'b0000101;status[157:151]=1;end
        endcase
        if(SHOT==0 || SHOT==1 || SHOT==3 || SHOT==4)roll=0;
        toggle=1;wait(ack);@(negedge clk);
        if(dut.roll_status!==roll)$fatal(1,"roll mailbox snapshot torn");
        if(dut.song_status!==status) $fatal(1,"mailbox snapshot torn");
        if(SHOT==5)force dut.page_show=0;else if(SHOT==6)force dut.page_show=1;else force dut.page_show=2;
        force dut.fade_lvl=15;
        scope_trg=1;
        // Let the real scope and decimal display settle before the captured frame.
        if(SHOT==5)begin wait(dut.vcnt==1124);wait(dut.vcnt==0);end
        else begin @(negedge clk);force dut.frame_tick=1;@(negedge clk);release dut.frame_tick;repeat(160)@(negedge clk);end
        wait(!dut.vis_d8);wait(dut.vis_d8);capture=1;
    end
    always @(posedge clk) if(capture && dut.vis_d8) begin
        if((^dut.rgb_r)===1'bx) $fatal(1,"unknown UI pixel");
        $fwrite(f,"%c%c%c",dut.rgb_r[23:16],dut.rgb_r[15:8],dut.rgb_r[7:0]);
        if(x<1919) x=x+1;
        else if(y<1079) begin x=0;y=y+1;end
        else begin
            $fclose(f);$display("PASS UI snapshot %0d: mailbox and 1920x1080 RGB pixels",SHOT);$finish;
        end
    end
    initial begin #120000000;$fatal(1,"UI timeout");end
endmodule
`default_nettype wire
