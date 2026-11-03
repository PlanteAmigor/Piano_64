// Original knee curve, pipelined at 50 MHz. Latency is five clocks; audio
// samples remain held for 1024 clocks. The 15-bit delta bounds the multiplier.
`default_nettype none
module audio_soft_limiter(input wire clk,rst_n,input wire signed [31:0] sample,
    output reg signed [15:0] limited);
    reg [31:0] magnitude;
    reg sign1,sign2,sign3,sign4;
    reg [14:0] delta2,delta3;
    reg [29:0] square3;
    reg straight2,straight3;
    reg [14:0] direct2,direct3;
    reg [15:0] result4;
    wire [31:0] knee_delta=magnitude-32'd24000;
    wire [15:0] curve=16'd24000+{1'b0,delta3}-{1'b0,square3[29:15]};
    always @(posedge clk)begin
        if(!rst_n)begin
            magnitude<=0;sign1<=0;sign2<=0;sign3<=0;sign4<=0;
            delta2<=0;delta3<=0;square3<=0;straight2<=1;straight3<=1;
            direct2<=0;direct3<=0;result4<=0;limited<=0;
        end else begin
            magnitude<=sample[31]?-sample:sample;sign1<=sample[31];
            straight2<=magnitude<=24000;direct2<=magnitude[14:0];sign2<=sign1;
            delta2<=magnitude<=24000?15'd0:magnitude>=40384?15'd16384:knee_delta[14:0];
            square3<=delta2*delta2;delta3<=delta2;straight3<=straight2;direct3<=direct2;sign3<=sign2;
            result4<=straight3?{1'b0,direct3}:curve;sign4<=sign3;
            limited<=sign4?-$signed(result4):$signed(result4);
        end
    end
endmodule
`default_nettype wire
