`timescale 1ns/1ps
`default_nettype none
module tb_modal_multi;
    reg clk=0,clk100=0,rst=0,tick=0;
    always #10 clk=~clk;
    always #5 clk100=~clk100;
    reg [1:0] trig=0,kind=2'b10,expression=2'b10;
    reg global_timbre=0;
    reg [7:0] image[0:1127967];
    initial $readmemh("work/song_checks/image_bytes.hex",image);
    wire en;wire [28:0] addr;
    reg pending=0,valid=0;reg [28:0] saved;reg [255:0] data;integer delay=0,j;
    always @(posedge clk100)begin
        valid<=0;
        if(en && !pending)begin saved<=addr;pending<=1;delay<=3;end
        else if(pending && delay!=0)delay<=delay-1;
        else if(pending)begin
            for(j=0;j<32;j=j+1)data[j*8+:8]<=image[(saved<<2)+j];
            valid<=1;pending<=0;
        end
    end
    add_engine8 #(.NVOICE(2),.MULTI_TIMBRE(1),.USE_DDR(1)) dut(
        .clk(clk),.clk100(clk100),.rst_n(rst),.rst100_n(rst),.app_rdy(!pending),.app_en(en),.app_addr(addr),
        .app_rd_data_valid(valid),.app_rd_data(data),.v_note({7'd64,7'd60}),.v_trig(trig),.v_gate(2'b11),
        .v_vel(16'h8080),.voice_timbre(kind),.voice_expression(expression),.normalize_guzheng(1'b1),
        .timbre(global_timbre),.sample_tick(tick),.bend_q14(16'd18000),.vib_en(1'b0),
        .art_en(1'b0),.stop_hold(1'b0),.sustain(1'b0));
    integer count0=0,count1=0,k,byte_addr;
    reg [95:0] want;
    task check(input integer voice,input integer a,input [95:0] value);
        begin
            byte_addr=((voice==0?1+39*64:5633+26*64)*32)+a*16;
            for(k=0;k<12;k=k+1)want[k*8+:8]=image[byte_addr+k];
            if(value!==want)$fatal(1,"mixed parameter corruption voice%0d part%0d",voice,a);
        end
    endtask
    always @(negedge clk100)begin
        if(dut.g_voice[0].dma_we)begin check(0,dut.g_voice[0].dma_waddr,dut.g_voice[0].dma_wdata);count0=count0+1;end
        if(dut.g_voice[1].dma_we)begin check(1,dut.g_voice[1].dma_waddr,dut.g_voice[1].dma_wdata);count1=count1+1;end
    end
    initial begin
        repeat(8)@(negedge clk);rst=1;trig=3;@(negedge clk);trig=0;
        // Live metadata/global timbre can change during DMA; captured tables must not.
        kind=0;global_timbre=1;
        wait(count0==128 && count1==128);repeat(30)@(negedge clk);
        if(dut.g_voice[0].u_v.bend_q14!=16384 || dut.g_voice[1].u_v.bend_q14!=18000)
            $fatal(1,"only guzheng lead receives gesture");
        expression=0;repeat(4)@(negedge clk);
        if(dut.g_voice[1].u_v.bend_q14!=16384)$fatal(1,"automatic accompaniment receives gesture");
        $display("PASS mixed modal DMA: simultaneous piano/guzheng, all 256 P64 cache records match, timbre captured during transfer, lead-only expression");$finish;
    end
    initial begin #1000000;$fatal(1,"mixed modal timeout %0d/%0d",count0,count1);end
endmodule
`default_nettype wire
