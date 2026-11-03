`timescale 1ns/1ps
`default_nettype none
module tb_tmds_encode;
    reg clk=0,reset=1,den=0;reg [7:0] data=0;reg [1:0] ctrl=0;
    wire [9:0] tmds;
    always #3.367 clk=~clk;
    dvi_tx_tmds_enc dut(.clock(clk),.reset(reset),.den(den),.data(data),.ctrl(ctrl),.tmds(tmds));
    integer rd=0,n,ones,k,checked=0;
    reg [7:0] q;reg flip,q8;reg [9:0] expected=0,pending=0;
    reg [31:0] rng=32'hb1715c3d;
    // Independent DVI algorithm with unbounded integer disparity. Compare the
    // exact symbol sequence and latency, including video/control transitions.
    always @(posedge clk)begin
        if(reset)begin rd=0;pending=10'b1101010100;expected=0;end
        else begin
            expected=pending;
            if(!den)begin
                rd=0;
                case(ctrl)0:pending=10'b1101010100;1:pending=10'b0010101011;
                    2:pending=10'b0101010100;3:pending=10'b1010101011;endcase
            end else begin
                ones=0;for(k=0;k<8;k=k+1)ones=ones+data[k];
                flip=(ones>4 || (ones==4 && !data[0]));q[0]=data[0];
                for(k=1;k<8;k=k+1)q[k]=q[k-1]^data[k]^flip;
                q8=!flip;ones=0;for(k=0;k<8;k=k+1)ones=ones+q[k];
                if(rd==0 || ones==4)begin
                    pending={!q8,q8,q^{8{!q8}}};rd=rd+(q8?2*ones-8:8-2*ones);
                end else if((rd>0 && ones>4)||(rd<0 && ones<4))begin
                    pending={1'b1,q8,~q};rd=rd+2*q8+8-2*ones;
                end else begin
                    pending={1'b0,q8,q};rd=rd-2*(!q8)+2*ones-8;
                end
            end
            #0.1;
            if(tmds!==expected)$fatal(1,"TMDS symbol mismatch cycle%0d got%h expected%h",checked,tmds,expected);
            checked=checked+1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);reset=0;
        for(n=0;n<32768;n=n+1)begin
            @(negedge clk);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            data=n<4096?n[7:0]:rng[7:0];den=n<4096?1:rng[10:8]!=0;ctrl=rng[12:11];
        end
        repeat(4)@(negedge clk);den=0;
        repeat(4)@(negedge clk);
        $display("PASS TMDS: all 256 bytes, 32768 continuous/random video/control symbols, exact two-stage latency and independent integer disparity");$finish;
    end
endmodule
`default_nettype wire
