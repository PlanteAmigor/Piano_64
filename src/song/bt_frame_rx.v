// Payload is retained until consume. No song RAM writes occur before CRC passes.
`default_nettype none
module bt_frame_rx #(parameter integer CLK_HZ=50000000, TIMEOUT_MS=2000)(
    input wire clk, rst_n, input wire [7:0] byte_data,
    input wire byte_valid, byte_error, consume,
    input wire [8:0] payload_addr, output wire [7:0] payload_data,
    output reg valid, output reg [7:0] error_code, frame_type, seq,
    output reg [15:0] length, frame_crc
);
    reg [7:0] payload[0:257];
    assign payload_data=payload[payload_addr];
    reg [3:0] state;
    reg [8:0] index;
    reg [15:0] crc;
    reg [7:0] crc_low, version;
    reg [31:0] timeout_count;
    function [15:0] crc_byte;
        input [15:0] c; input [7:0] b;
        reg [15:0] x; integer k;
        begin x=c^{b,8'd0}; for(k=0;k<8;k=k+1) x=x[15] ? (x<<1)^16'h1021 : x<<1; crc_byte=x; end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=0; valid<=0; error_code<=0; frame_type<=0; seq<=0;
            length<=0; frame_crc<=0; crc<=16'hffff; crc_low<=0;
            index<=0; timeout_count<=0; version<=0;
        end else if(valid) begin
            if(consume) begin valid<=0; state<=0; timeout_count<=0; end
        end else if(byte_error || (state!=0 && timeout_count>= (CLK_HZ/1000)*TIMEOUT_MS-1)) begin
            state<=0; timeout_count<=0;
            // A partial header has no trustworthy sequence/type: silently resync.
            // Once the full header exists, report the aborted frame explicitly.
            if(state>=7) begin valid<=1; error_code<=8; frame_crc<=0; end
        end else begin
            if(state!=0) timeout_count<=timeout_count+1'b1;
            if(byte_valid) begin
                timeout_count<=0;
                case(state)
                    0: if(byte_data==8'ha5) begin state<=1; crc<=crc_byte(16'hffff,byte_data); end
                    1: if(byte_data==8'h5a) begin state<=2; crc<=crc_byte(crc,byte_data); end
                       else if(byte_data!=8'ha5) state<=0;
                    2: begin version<=byte_data; crc<=crc_byte(crc,byte_data); state<=3; end
                    3: begin frame_type<=byte_data; crc<=crc_byte(crc,byte_data); state<=4; end
                    4: begin seq<=byte_data; crc<=crc_byte(crc,byte_data); state<=5; end
                    5: begin length[7:0]<=byte_data; crc<=crc_byte(crc,byte_data); state<=6; end
                    6: begin
                        length[15:8]<=byte_data; crc<=crc_byte(crc,byte_data); index<=0;
                        if({byte_data,length[7:0]}>258) begin valid<=1; error_code<=2; frame_crc<=0; end
                        else state<=({byte_data,length[7:0]}==0) ? 8 : 7;
                    end
                    7: begin
                        payload[index]<=byte_data; crc<=crc_byte(crc,byte_data);
                        if(index==length-1) state<=8; else index<=index+1'b1;
                    end
                    8: begin crc_low<=byte_data; state<=9; end
                    9: begin
                        frame_crc<={byte_data,crc_low}; valid<=1;
                        error_code<=({byte_data,crc_low}!=crc) ? 1 : (version!=3 ? 10 : 0);
                    end
                    default: state<=0;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
