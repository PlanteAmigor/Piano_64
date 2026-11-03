`timescale 1ns/1ps
`default_nettype none
module tb_scope_points;
    reg clk=0,rst=0,toggle=0,trigger=0;always #10 clk=~clk;
    reg signed [15:0] sample=0;
    wire [7:0] x,y;wire point;
    ui_scope_points dut(.clk(clk),.rst_n(rst),.flt_sel(2'd1),.SCOPE_SMP(sample),.SCOPE_TOG(toggle),
        .SCOPE_TRG(trigger),.px_pt(x),.py_pt(y),.point_toggle(point));
    reg last=0;integer count=0,min_x=255,max_x=0,min_y=255,max_y=0,i;
    always @(negedge clk)begin
        last<=point;
        if(rst && point!=last)begin
            count=count+1;
            if((^{x,y})===1'bx || x<32 || x>224 || y<32 || y>224)$fatal(1,"invalid scope point");
            if(x<min_x)min_x=x;if(x>max_x)max_x=x;if(y<min_y)min_y=y;if(y>max_y)max_y=y;
        end
    end
    initial begin
        repeat(10)@(negedge clk);rst=1;
        for(i=0;i<1200;i=i+1)begin
            if(i==300)trigger=1;
            sample=$rtoi(12000*$sin(6.283185307*440*i/48828.125));toggle=~toggle;
            repeat(1024)@(negedge clk);
            if(i==310 && dut.settle_ok)$fatal(1,"note-on settlement");
            if(i==850 && !dut.settle_ok)$fatal(1,"scope never resumes");
        end
        if(count<600 || max_x-min_x<170 || max_y-min_y<170)$fatal(1,"scope AGC/point publication count%0d span%0d/%0d",count,max_x-min_x,max_y-min_y);
        $display("PASS 50MHz scope: real sample rate, DC/filter/AGC, full coordinate span, note-on settlement/resume, completed coordinate publication");$finish;
    end
    initial begin #30000000;$fatal(1,"scope timeout");end
endmodule
`default_nettype wire
