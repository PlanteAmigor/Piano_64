// Capture the actual HDMI RGB pipeline, bypassing only vendor PLL/DVI cells.
`timescale 1ns/1ps
`default_nettype none
module tb_song_ui;
    parameter integer SHOT=0;
    reg clk=0,resetn=0,toggle=0;
    always #6.667 clk=~clk;
    reg [255:0] status=0;
    wire ack;
    hdmi_ui3_top dut (
        .clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd2),
        .SONG_UI(status),.SONG_UI_TOGGLE(toggle),.SONG_UI_ACK(ack),
        .COMP_AMP(512'd0),.SCOPE_SMP(16'd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0)
    );
    integer f,x=0,y=0;
    reg capture=0;
    reg [1023:0] output_path;
    initial begin
        if(!$value$plusargs("OUT=%s",output_path)) output_path="work/song_checks/ui.ppm";
        f=$fopen(output_path,"wb");if(!f) $fatal(1,"UI output");
        $fwrite(f,"P6\n1280 720\n255\n");
        repeat(20) @(negedge clk);resetn=1;repeat(30) @(negedge clk);
        status[31:0]=32'h03020104;status[132:128]=4;status[136:133]=1;status[232]=1;
        case(SHOT)
            1:begin status[139:137]=1;status[140]=1;end
            2:begin status[139:137]=3;status[140]=1;status[143:142]=3;status[150:144]=7'b0000101;status[157:151]=1;end
            3:begin status[139:137]=4;status[165:158]=1;end
            4:begin status[132:128]=0;status[232]=0;end
        endcase
        toggle=1;wait(ack);@(negedge clk);
        if(dut.song_status!==status) $fatal(1,"mailbox snapshot torn");
        force dut.page_show=2;
        force dut.fade_lvl=15;
        wait(!dut.vis_d3);wait(dut.vis_d3);capture=1;
    end
    always @(posedge clk) if(capture && dut.vis_d3) begin
        if((^dut.rgb_r)===1'bx) $fatal(1,"unknown UI pixel");
        $fwrite(f,"%c%c%c",dut.rgb_r[23:16],dut.rgb_r[15:8],dut.rgb_r[7:0]);
        if(x<1279) x=x+1;
        else if(y<719) begin x=0;y=y+1;end
        else begin
            $fclose(f);$display("PASS UI snapshot %0d: mailbox and 1280x720 RGB pixels",SHOT);$finish;
        end
    end
    initial begin #40000000;$fatal(1,"UI timeout");end
endmodule
`default_nettype wire
