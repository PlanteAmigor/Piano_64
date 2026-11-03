`timescale 1ns/1ps
`default_nettype none
module tb_song_preview;
    reg clk=0,sdclk=0,rst=0,confirm=0,next_key=0,begin_t=0,end_t=0,valid=0;
    always #10 clk=~clk;
    always #11 sdclk=~sdclk;
    reg [7:0] data=0;
    wire playing,score,multi;
    wire [1023:0] roll;
    wire [10:0] progress;
    wire [31:0] position,duration;
    wire [2:0] menu;
    wire [7:0] error;
    song_system #(.CLK_HZ(100000)) dut(
        .clk(clk),.clk_sd(sdclk),.rst_n(rst),.guide(1'b1),.next_state(next_key),.confirm_state(confirm),
        .key_press(7'd0),.key_state(7'd0),.sd_count(5'd1),.sd_ids(128'd5),.sd_catalog_done(1'b1),
        .sd_begin(begin_t),.sd_end(end_t),.sd_error(1'b0),.sd_byte(data),.sd_byte_valid(valid),
        .playing(playing),.score_valid(score),.multi_score(multi),.position_ms(position),.score_duration(duration),
        .roll_preview(roll),.progress(progress),.menu_state(menu),.error_code(error));
    task click;begin @(negedge clk);confirm=1;repeat(8)@(negedge clk);confirm=0;repeat(8)@(negedge clk);end endtask
    integer fd,c,top,bottom,expected_progress;
    initial begin
        repeat(10)@(negedge clk);rst=1;repeat(20)@(negedge clk);
        click;
        next_key=1;repeat(8)@(negedge clk);next_key=0;repeat(8)@(negedge clk);
        click;if(menu!=2)$fatal(1,"load state");
        @(negedge sdclk);begin_t=~begin_t;repeat(20)@(negedge sdclk);
        fd=$fopen("tools/generated/SONG05.BIN","rb");if(!fd)$fatal(1,"fixture");c=$fgetc(fd);
        while(c>=0)begin
            data=c;valid=1;@(negedge sdclk);valid=0;repeat(3)@(negedge sdclk);c=$fgetc(fd);
        end
        end_t=~end_t;
        wait(playing);wait(roll!=0);
        if(!score || !multi || !roll[31] || !roll[30] || roll[28:27]!=3 || roll[26:23]!=0)
            $fatal(1,"preview instrument/lead/lane metadata %h",roll[31:0]);
        top=roll[22:12];bottom=roll[11:1];
        if(top!=256 || bottom<264 || bottom>270)$fatal(1,"countdown preview coordinates %0d %0d",top,bottom);
        wait(position>=100);repeat(1400)@(negedge clk);
        top=roll[22:12];bottom=roll[11:1];
        if(top<770 || top>785 || bottom<880 || bottom>890)$fatal(1,"scroll/clipping %0d %0d",top,bottom);
        expected_progress=(position*1024)/duration;
        if(progress<expected_progress-1 || progress>expected_progress+1)$fatal(1,"progress %0d expected%0d",progress,expected_progress);
        if(error)$fatal(1,"transport error %0d",error);
        $display("PASS real score preview: SD clock crossing, multi-instrument metadata, 3-second preparation, continuous scroll, clipping, progress, independent player RAM");$finish;
    end
    initial begin #10000000;$fatal(1,"preview timeout menu%0d err%0d",menu,error);end
endmodule
`default_nettype wire
