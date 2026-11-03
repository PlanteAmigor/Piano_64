`timescale 1ns/1ps
`default_nettype none
module tb_sd_remaining;
    reg c50=0,c100=0,rst_n=0,valid=0,armed=0;
    always #10 c50=~c50;
    always #5 c100=~c100;
    sd_ddr_loader dut(.clk50(c50),.clk100(c100),.arst_n(rst_n),.calib_done(1'b0),
        .dbg_pll(1'b0),.dbg_por_n(1'b0),.dbg_reset_n(1'b0),.sd_dat0(1'b1),
        .app_rdy(1'b0),.wr_data_rdy(1'b0),.app_rd_data_valid(valid),.app_rd_data(256'd0),
        .song_request(1'b0),.song_request_index(4'd0));
    reg [31:0] expected=0,expected_received=0;
    integer checks=0,i,j;
    always @(posedge c100)if(armed)begin
        if(dut.rdv)begin
            expected_received=expected_received+1;
            if(expected!=0)expected=expected-1;
        end
        #1;
        if(dut.rem_r!==expected)$fatal(1,"remaining counter actual=%h expected=%h",dut.rem_r,expected);
        if(dut.rcnt!==expected_received)$fatal(1,"response count actual=%h expected=%h",dut.rcnt,expected_received);
        checks=checks+1;
    end
    task seed(input [31:0] value);
        begin
            @(negedge c100);dut.rem_r=value;expected=value;dut.rcnt=~value;expected_received=~value;
            for(j=0;j<20;j=j+1)begin @(negedge c100);valid=j<5 || ($random&1);end
        end
    endtask
    initial begin
        repeat(5)@(negedge c100);rst_n=1;repeat(5)@(negedge c100);
        // Isolate read-response accounting from the boot/report state machine.
        // The actual rd_v/rdv input pipeline and counter update still run.
        force dut.st=4'hF;
        armed=1;
        seed(0);seed(1);seed(2);seed(32'hff);seed(32'h100);seed(32'h101);
        seed(32'hffff);seed(32'h10000);seed(32'h10001);
        seed(32'hffffff);seed(32'h1000000);seed(32'h1000001);seed(32'hffffffff);
        for(i=0;i<2048;i=i+1)seed($random);
        @(negedge c100);armed=0;
        $display("PASS SD response counter: %0d cycles, zero saturation, all byte carry/borrow boundaries, 2048 random seeds, consecutive/gapped read responses",checks);
        $finish;
    end
endmodule
`default_nettype wire
