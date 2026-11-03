`timescale 1ns/1ps
`default_nettype none
module tb_harm_rom_compact;
    reg clk=0;always #10 clk=~clk;
    reg [13:0] addr=0;
    wire [31:0] value;
    reg [31:0] reference[0:16383];
    harm_buf dut(.clk(clk),.rst_n(1'b1),.wclk(clk),.wrst_n(1'b1),
        .abc_a(11'd0),.pi_a(11'd0),.pe_a(16'd0),.po_a(16'd0),
        .ee_a(16'd0),.eo_a(16'd0),.ph_a(15'd0),.u_a(addr),.u_d(value),.sn_a(10'd0),.inf_a(8'd0),
        .ab_we(1'b0),.bc_we(1'b0),.pi_we(1'b0),.ee_we(1'b0),.eo_we(1'b0),.pe_we(1'b0),.po_we(1'b0),.ph_we(1'b0),
        .ab_a(6'd0),.bc_a(6'd0),.pi_a_w(6'd0),.ee_a_w(13'd0),.eo_a_w(13'd0),
        .pe_a_w(12'd0),.po_a_w(12'd0),.ph_a_w(10'd0),
        .ab_wd(32'd0),.bc_wd(32'd0),.pi_wd(16'd0),.ee_wd(8'd0),.eo_wd(8'd0),
        .pe_wd(16'd0),.po_wd(16'd0),.ph_wd(32'd0));
    integer i;
    initial begin
        $readmemh("harm_u.hex",reference);
        for(i=0;i<49152;i=i+1)begin
            @(negedge clk);addr=i<16384?i:$random;
            @(posedge clk);#1;
            if(value!==reference[addr])$fatal(1,"curve mismatch addr=%0d actual=%h expected=%h",addr,value,reference[addr]);
        end
        $display("PASS banked harmonic ROM: all 16384 addresses plus 32768 random jumps, exact original 32-bit values and one-cycle latency");
        $finish;
    end
endmodule
`default_nettype wire
