`timescale 1ns/1ps
`default_nettype none
module tb_song_multi;
    reg clk=0,rst=0,start=0,stop=0;
    always #10 clk=~clk;
    reg [63:0] mem[0:5],rd;
    wire [12:0] addr;
    wire [7:0] trig,gate,lead;
    wire [15:0] instruments;
    wire [55:0] notes;
    wire [63:0] velocity;
    wire playing,overflow;
    wire [31:0] position;
    wire [1:0] timbre;
    wire [6:0] expected,matched;
    wire [15:0] missed,wrong;
    reg [6:0] press=0,keys=0;
    integer triggers=0;
    always @(posedge clk)begin rd<=mem[addr];for(integer k=0;k<8;k=k+1)if(trig[k])triggers=triggers+1;end
    bt_song_player #(.CLK_HZ(50000),.TEACH_ENABLED(1),.MULTI_ENABLED(1),.START_DELAY_MS(300)) dut(
        .clk(clk),.rst_n(rst),.start(start),.stop(stop),.count(16'd6),.duration_ms(32'd1000),.timbre(2'd3),
        .multi_mode(1'b1),.teach_mode(1'b1),.read_addr(addr),.read_data(rd),.playing(playing),.overflow(overflow),
        .v_note(notes),.v_trig(trig),.v_gate(gate),.v_vel(velocity),.v_timbre(instruments),.v_lead(lead),
        .position_ms(position),.lead_timbre(timbre),.key_press(press),.key_state(keys),
        .expected_keys(expected),.matched_keys(matched),.wrong_count(wrong),.missed_count(missed));
    function [63:0] event64;
        input [31:0] t;input [6:0] n;input [14:0] d;input [6:0] v;input [1:0] instrument;input melody;
        begin event64={instrument[0],v,!melody,d,instrument[1],n,t};end
    endfunction
    task at_ms(input integer t);begin wait(position>=t);repeat(25)@(negedge clk);end endtask
    initial begin
        mem[0]=event64(0,72,250,100,3,1); // flute lead, slot7
        mem[1]=event64(0,48,650,60,0,0);  // piano accompaniment, slot0
        mem[2]=event64(0,64,650,70,1,0);  // guzheng accompaniment, slot1
        mem[3]=event64(300,74,250,90,2,1);// suona lead changes automatically
        mem[4]=event64(700,76,250,80,1,1);// guzheng lead, modal slot0
        mem[5]=event64(700,60,250,60,0,0);
        repeat(6)@(negedge clk);rst=1;start=1;@(negedge clk);start=0;
        at_ms(1);
        if(gate!==8'h83 || lead!==8'h80 || instruments[15:14]!=3 || instruments[3:2]!=1 || timbre!=3)
            $fatal(1,"mixed dispatch gate=%h lead=%h instruments=%h",gate,lead,instruments);
        if(velocity[63:56]!=100 || velocity[7:0]!=120 || velocity[15:8]!=140 || expected!=1)
            $fatal(1,"lead half; accompaniment full/unjudged %h %b",velocity,expected);
        at_ms(50);press=1;keys=1;@(negedge clk);press=0;
        at_ms(70);if(velocity[63:56]!=200 || triggers!=3 || matched!=1)$fatal(1,"late restore without retrigger");
        keys=0;at_ms(80);if(gate[7] || gate[1:0]!=3)$fatal(1,"release lead must preserve accompaniment");
        at_ms(310);if(timbre!=2 || instruments[15:14]!=2 || velocity[63:56]!=90 || expected!=2)$fatal(1,"suona switch");
        at_ms(710);if(timbre!=1 || instruments[1:0]!=1 || lead[0]!=1 || velocity[7:0]!=80 || expected!=4)$fatal(1,"guzheng switch");
        at_ms(960);if(missed!=2 || wrong || overflow || gate!=0 || triggers!=6)$fatal(1,"only lead misses counted %d %d",missed,wrong);
        wait(!playing);$display("PASS mixed teaching: three concurrent instruments, automatic lead timbre/octave, full automatic accompaniment, fallback/restoration, independent release, lead-only judgment");$finish;
    end
    initial begin #5000000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
