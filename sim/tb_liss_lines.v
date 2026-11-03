`timescale 1ns/1ps
module tb_liss_lines;
    parameter integer BITS=8,PB=2;
    localparam integer AW=2*BITS-(PB==2?3:2),WORDS=1<<AW;
    reg clk=0,rst=0,plot=0,clear=0;always #3.367 clk=~clk;
    reg [7:0] x=0,y=0;reg [AW-1:0] addr=0;
    wire [15:0] data;wire cleared;
    reg [15:0] points[0:15],expected[0:WORDS-1];
    reg [1023:0] filename;
    ui_liss_ram #(.COORD_BITS(BITS),.PIXEL_BITS(PB)) dut(.clk(clk),.rst_n(rst),.plot(plot),.plot_x(x),.plot_y(y),
        .clr_en(clear),.clr_done(cleared),.decay_req(1'b0),.decay_step(4'd1),.ink_step(4'd15),.raddr(addr),.rdata(data));
    integer i;
    initial begin
        $readmemh("work/song_checks/liss_points.hex",points);
        $sformat(filename,"work/song_checks/liss_expected_%0d_%0d.hex",BITS,PB);$readmemh(filename,expected);
        repeat(5)@(negedge clk);rst=1;clear=1;@(negedge clk);clear=0;wait(cleared);@(negedge clk);
        for(i=0;i<16;i=i+1)begin
            {x,y}=points[i];plot=1;@(negedge clk);plot=0;
            wait(dut.st!=0);wait(dut.st==0 && !dut.pend);@(negedge clk);
        end
        for(i=0;i<WORDS;i=i+1)begin
            addr=i;repeat(2)@(negedge clk);
            if(data!==expected[i])$fatal(1,"Bresenham grid mismatch bits%0d pb%0d word%0d got%h expected%h",BITS,PB,i,data,expected[i]);
        end
        $display("PASS pipelined plot: %0dx%0d/%0d-bit, all octants, axis/diagonal/shallow lines, maximum span, pen breaks, exact full RAM against independent integer rasterizer",1<<BITS,1<<BITS,PB);$finish;
    end
    initial begin #1000000;$fatal(1,"line timeout");end
endmodule
