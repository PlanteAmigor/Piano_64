`timescale 1ns/1ps
`default_nettype none
module tb_liss_resolution;
    parameter integer BITS=8,PB=4;
    localparam integer AW=2*BITS-(PB==2?3:2);
    reg clk=0,rst=0,plot=0,decay=0,clear=0;always #5 clk=~clk;
    reg [7:0] x=0,y=0;
    reg [AW-1:0] addr=0;
    wire [15:0] data;wire cleared,busy;
    ui_liss_ram #(.COORD_BITS(BITS),.PIXEL_BITS(PB)) dut(.clk(clk),.rst_n(rst),.plot(plot),.plot_x(x),.plot_y(y),
        .clr_en(clear),.clr_done(cleared),.decay_req(decay),.decay_step(PB==2?4'd1:4'd3),.ink_step(4'd15),
        .decay_busy(busy),.raddr(addr),.rdata(data));
    task dot(input [7:0] a,b);begin @(negedge clk);x=a;y=b;plot=1;@(negedge clk);plot=0;repeat(40)@(negedge clk);end endtask
    initial begin
        repeat(4)@(negedge clk);rst=1;clear=1;@(negedge clk);clear=0;wait(cleared);repeat(4)@(negedge clk);
        dot(0,0);dot(255,255);
        addr=0;repeat(3)@(negedge clk);if(data!==(PB==2?16'h0003:16'h000f))$fatal(1,"first point %h",data);
        addr={AW{1'b1}};repeat(3)@(negedge clk);if(data!==(PB==2?16'hc000:16'hf000))$fatal(1,"last point %h",data);
        decay=1;@(negedge clk);decay=0;wait(busy);wait(!busy);repeat(4)@(negedge clk);
        if(data!==(PB==2?16'h8000:16'hc000))$fatal(1,"native decay %h",data);
        addr=0;repeat(3)@(negedge clk);if(data!==(PB==2?16'h0002:16'h000c))$fatal(1,"decay origin");
        $display("PASS Lissajous native %0dx%0d: clear, coordinate boundaries, discontinuity, synchronous read, persistence decay",1<<BITS,1<<BITS);$finish;
    end
    initial begin #2000000;$fatal(1,"Lissajous timeout");end
endmodule
`default_nettype wire
