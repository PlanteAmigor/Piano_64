`timescale 1ns/1ps
`default_nettype none
module tb_song_repeat;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [6:0] kp=0,ks=0;
    reg [63:0] mem[0:3],rd;
    wire [12:0] ra;
    wire [7:0] trig,gate;
    wire [63:0] vel;
    wire [31:0] pos;
    integer n=0;
    always @(posedge clk) rd<=mem[ra];
    bt_song_player #(.CLK_HZ(50000),.TEACH_ENABLED(1),.START_DELAY_MS(300)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.stop(1'b0),.count(16'd4),.duration_ms(32'd400),.timbre(2'd0),
        .read_addr(ra),.read_data(rd),.position_ms(pos),.v_trig(trig),.v_gate(gate),.v_vel(vel),
        .teach_mode(1'b1),.key_press(kp),.key_state(ks)
    );
    always @(negedge clk) if(|trig) begin
        if(n==2 ? vel[7:0]!=100 : (n==1 ? vel[15:8]!=200 : vel[7:0]!=200))
            $fatal(1,"same press reused for a different onset, event=%d velocity=%h",n,vel);
        n=n+1;
    end
    initial begin
        mem[0]={8'd100,16'd70,8'd60,32'd0};mem[1]={8'd100,16'd70,8'd72,32'd0};
        mem[2]={8'd100,16'd70,8'd60,32'd100};mem[3]={8'd100,16'd70,8'd60,32'd200};
        repeat(5) @(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
        wait(dut.elapsed_ms==250);@(negedge clk);kp=1;ks=1;@(negedge clk);kp=0;
        wait(pos==175);@(negedge clk);ks=0;@(negedge clk);kp=1;ks=1;@(negedge clk);kp=0;
        wait(pos==300);if(n!=4) $fatal(1,"missing repeat events");
        $display("PASS teaching onset groups: octave chord shares press; repeated note needs a new press");$finish;
    end
    initial begin #1000000;$fatal(1,"repeat timeout");end
endmodule
`default_nettype wire
