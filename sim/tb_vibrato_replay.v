`timescale 1ns/1ps
`default_nettype none
module tb_vibrato_replay;
    reg clk=0,rst_n=0,frame=0;
    always #10 clk=~clk;
    reg signed [23:0] raw=0,dc=0,ac=0,env=0;
    reg [15:0] hp=0;
    wire vib,trem,art,stop,hand;
    position_control dut(.clk(clk),.rst_n(rst_n),.frame_valid(frame),
        .x_q8(16'd1894),.x_valid(1'b1),.rho_raw(raw),.rho_dc(dc),.rho_ac(ac),
        .ac_env(env),.half_period(hp),.vib_en(vib),.trem_en(trem),
        .art_pulse(art),.stop_hold(stop),.hand_on(hand));
    reg [159:0] records[0:2494]; // five real feature captures, 499 frames each
    initial $readmemh("sim/data/vibrato_records.hex",records);
    integer i,set,count;
    task one_frame;
        begin @(negedge clk);frame=1;@(negedge clk);frame=0;repeat(3)@(negedge clk);end
    endtask
    initial begin
        for(set=0;set<5;set=set+1) begin
            rst_n=0;repeat(3)@(negedge clk);rst_n=1;count=0;
            for(i=0;i<499;i=i+1)begin
                raw=records[set*499+i][159:128];dc=records[set*499+i][127:96];
                ac=records[set*499+i][95:64];env=records[set*499+i][63:32];hp=records[set*499+i][15:0];
                one_frame;if(vib)count=count+1;
            end
            $display("replay set=%d enabled=%d/499",set,count);
            if(set==2 && count<100)$fatal(1,"recorded vibrato gesture was rejected");
            if((set==0||set==1)&&count!=0)$fatal(1,"slow height/still false vibrato");
        end
        raw=9491;dc=9491;ac=0;env=0;repeat(80)one_frame;
        if(vib)$fatal(1,"gesture did not release");
        // A single excursion with stale in-range period must not retrigger.
        hp=10;env=900;ac=1000;repeat(8)one_frame;ac=-1000;repeat(8)one_frame;
        ac=0;env=0;repeat(25)one_frame;if(vib)$fatal(1,"stale period armed gesture");
        $display("PASS recorded gesture replay: intended vibrato detected; still/slow height rejected; stops and stale period safe");$finish;
    end
endmodule
`default_nettype wire
