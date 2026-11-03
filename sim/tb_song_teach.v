`timescale 1ns/1ps
`default_nettype none
module tb_song_teach;
    reg clk=0,rst_n=0,start=0,stop=0,teach=1;
    always #10 clk=~clk;
    reg [6:0] kp=0,ks=0;
    reg [63:0] mem[0:5],rd;
    wire [12:0] ra;
    wire playing,ov;
    wire [31:0] pos;
    wire [55:0] notes;
    wire [63:0] vel;
    wire [7:0] trig,gate;
    wire [6:0] expected,matched;
    wire [1:0] countdown;
    wire [15:0] wrong,miss;
    integer triggers=0;
    always @(posedge clk) begin rd<=mem[ra]; if(|trig) triggers=triggers+1; end
    bt_song_player #(.CLK_HZ(50000),.TEACH_ENABLED(1),.START_DELAY_MS(3000)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.stop(stop),.count(16'd6),.duration_ms(32'd1500),.timbre(2'd0),
        .read_addr(ra),.read_data(rd),.playing(playing),.overflow(ov),.position_ms(pos),
        .v_note(notes),.v_trig(trig),.v_gate(gate),.v_vel(vel),.teach_mode(teach),.key_press(kp),.key_state(ks),
        .expected_keys(expected),.matched_keys(matched),.countdown(countdown),.wrong_count(wrong),.missed_count(miss)
    );
    function [63:0] event64;
        input [31:0] t; input [7:0] n; input [15:0] d; input [7:0] v;
        begin event64={v,d,n,t}; end
    endfunction
    task pulse;
        input [6:0] keys;
        begin @(negedge clk);kp=keys;ks=keys;@(negedge clk);kp=0;end
    endtask
    task at_ms;
        input integer t;
        begin wait(pos>=t); repeat(20) @(negedge clk); end
    endtask
    integer i,active_c;
    initial begin
        mem[0]=event64(0,36,1290,100);
        mem[1]=event64(0,48,400,100);
        mem[2]=event64(0,60,400,100);
        mem[3]=event64(0,64,400,100);
        mem[4]=event64(500,61,100,90); // black key, never judged
        mem[5]=event64(1000,62,30,80); // short missed note
        repeat(6) @(negedge clk);rst_n=1;
        @(negedge clk);start=1;@(negedge clk);start=0;
        repeat(100) @(negedge clk);
        if(countdown!=3 || gate!=0) $fatal(1,"prepare countdown");
        wait(dut.elapsed_ms>=2950); pulse(7'b0000001); // early C, three octaves
        at_ms(1);
        if(gate[3:0]!==4'b1111 || vel[7:0]!=200 || vel[15:8]!=200 || vel[23:16]!=200 || vel[31:24]!=100)
            $fatal(1,"on-time chord/early full/fallback half gate=%b vel=%h",gate,vel);
        at_ms(100); pulse(7'b0000101); // late E, retain C held
        at_ms(120);
        if(vel[31:24]!=200 || triggers!=4) $fatal(1,"late match must ramp, never retrigger");
        pulse(7'b1000101); // wrong B cannot sound
        at_ms(300);
        if(triggers!=4 || wrong!=1) $fatal(1,"wrong-key behavior %d/%d",triggers,wrong);
        at_ms(410);
        if(gate[3:0]!==4'b0001) $fatal(1,"C2 must outlive C3/C4/E4 %b",gate);
        at_ms(510);
        if(vel[15:8]!=180 || triggers!=5) $fatal(1,"black key should be full automatic");
        at_ms(1040);
        if(miss!=1 || triggers!=6) $fatal(1,"short fallback note %d/%d",miss,triggers);
        at_ms(1300);
        if(gate!=0 || ov) $fatal(1,"independent duration/overflow");
        @(negedge clk);stop=1;@(negedge clk);stop=0;
        repeat(4) @(negedge clk);
        if(playing || gate!=0) $fatal(1,"stop");
        $display("PASS teaching: countdown, early/late chord, ramp, wrong key, black key, short fallback, independent ends, stop");
        $finish;
    end
    initial begin #20000000; $fatal(1,"timeout"); end
endmodule
`default_nettype wire
