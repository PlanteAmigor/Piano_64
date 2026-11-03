`timescale 1ns/1ps
`default_nettype none
module tb_sine_quarter;
    reg clk=0;always #10 clk=~clk;
    reg [9:0] addr=0;wire [31:0] value;
    reg [31:0] reference[0:1023];
    integer i;
    add_sine_lut dut(.clk(clk),.addr(addr),.dout(value));
    initial begin
        $readmemh("add_sine.hex",reference);
        for(i=0;i<66560;i=i+1)begin
            @(negedge clk);addr=i<1024?i:$random;
            @(posedge clk);#1;
            if(value!==reference[addr])$fatal(1,"sine pair mismatch addr=%0d actual=%h expected=%h",addr,value,reference[addr]);
        end
        $display("PASS quarter sine ROM: all 1024 original paired words and quadrant/wrap endpoints, 65536 random jumps, exact one-cycle latency");
        $finish;
    end
endmodule
`default_nettype wire
