`timescale 1ns/1ps
`default_nettype none
module tb_song_window;
    parameter integer OFFSET=150;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [6:0] kp=0,ks=0;
    reg [63:0] rd;
    wire [63:0] vel;
    wire [31:0] pos;
    always @(posedge clk) rd<={8'd100,16'd500,8'd60,32'd500};
    bt_song_player #(.CLK_HZ(50000),.TEACH_ENABLED(1),.START_DELAY_MS(0)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.stop(1'b0),.count(16'd1),.duration_ms(32'd1100),.timbre(2'd0),
        .read_data(rd),.position_ms(pos),.v_vel(vel),.teach_mode(1'b1),.key_press(kp),.key_state(ks)
    );
    initial begin
        repeat(5) @(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
        // Capture at the last clock of the boundary millisecond: processing
        // crosses the ms rollover but must judge the captured timestamp.
        wait(dut.elapsed_ms==500+OFFSET && dut.divider==49);
        @(negedge clk);kp=1;ks=1;@(negedge clk);kp=0;
        wait(pos==800);
        if((OFFSET>=-150 && OFFSET<=150) ? vel[7:0]!=200 : vel[7:0]!=100)
            $fatal(1,"inclusive window offset=%d captured=%d vel=%d",OFFSET,dut.last_press[0],vel[7:0]);
        $display("PASS teaching inclusive window: offset=%0d ms, captured at ms rollover",OFFSET);$finish;
    end
    initial begin #2000000;$fatal(1,"window timeout");end
endmodule
`default_nettype wire
