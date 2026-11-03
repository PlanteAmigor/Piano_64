`timescale 1ns/1ps
`default_nettype none
module tb_song_overlap;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [6:0] kp=0,ks=0;
    reg [63:0] rd;
    wire [12:0] ra;
    wire [63:0] vel;
    wire [31:0] pos;
    always @(posedge clk) rd<=ra==0 ? {8'd100,16'd300,8'd60,32'd0} : {8'd100,16'd300,8'd72,32'd100};
    bt_song_player #(.CLK_HZ(50000),.TEACH_ENABLED(1),.START_DELAY_MS(0)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.stop(1'b0),.count(16'd2),.duration_ms(32'd450),.timbre(2'd0),
        .read_addr(ra),.read_data(rd),.position_ms(pos),.v_vel(vel),
        .teach_mode(1'b1),.key_press(kp),.key_state(ks)
    );
    initial begin
        repeat(5) @(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
        wait(pos==125);@(negedge clk);kp=1;ks=1;@(negedge clk);kp=0;
        wait(pos==145);
        if(vel[7:0]!=100 || vel[15:8]!=200 || dut.hit[1:0]!=2'b10)
            $fatal(1,"late press must match latest onset group only %h",vel);
        $display("PASS overlapping teaching windows: one late press matches latest onset, older fallback continues");$finish;
    end
    initial begin #1000000;$fatal(1,"overlap timeout");end
endmodule
`default_nettype wire
