// Two pixel stages: synchronous byte lookup, then running-disparity selection.
// Lookup includes both transition minimization and byte balance. This removes
// two population counts and a serial XOR chain from the 148.5 MHz feedback path.
`default_nettype none
module dvi_tx_tmds_enc(
    input wire clock,reset,den,
    input wire [7:0] data,
    input wire [1:0] ctrl,
    output reg [9:0] tmds
);
    reg [17:0] encode_rom[0:255];
    initial $readmemb("src/hdmi/ir4/tmds_encode.mem",encode_rom);
    reg [17:0] encoded;
    reg den_q;
    reg [1:0] ctrl_q;
    always @(posedge clock)encoded<=encode_rom[data];
    wire [8:0] qm=encoded[8:0];
    // Count disparity in half units: reachable running sums are -4..4.
    // Both possible deltas are precomputed in the same 18-bit lookup word.
    wire signed [3:0] inverse_delta=encoded[12:9],direct_delta=encoded[16:13];
    reg signed [3:0] disparity;
    wire neutral=(disparity==0 || encoded[17]);
    wire invert=neutral ? !qm[8] : (disparity[3]==direct_delta[3]);
    wire signed [3:0] delta=invert?inverse_delta:direct_delta;
    wire signed [3:0] next_disparity=disparity+delta;
    always @(posedge clock)begin
        if(reset)begin den_q<=0;ctrl_q<=0;tmds<=0;disparity<=0;end
        else begin
            den_q<=den;ctrl_q<=ctrl;
            if(!den_q)begin
                disparity<=0;
                case(ctrl_q)
                    0:tmds<=10'b1101010100;
                    1:tmds<=10'b0010101011;
                    2:tmds<=10'b0101010100;
                    3:tmds<=10'b1010101011;
                endcase
            end else begin
                tmds<={invert,qm[8],qm[7:0]^{8{invert}}};
                disparity<=next_disparity;
            end
        end
    end
endmodule
`default_nettype wire
