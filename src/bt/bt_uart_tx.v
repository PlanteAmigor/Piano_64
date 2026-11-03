`default_nettype none
module bt_uart_tx #(parameter integer CLK_HZ=50000000, BAUD=115200)(
    input wire clk, rst_n, input wire [7:0] data, input wire send,
    output reg tx, output reg busy
);
    localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(DIV<=2) ? 1 : $clog2(DIV);
    reg [CW-1:0] timer;
    reg [9:0] shift;
    reg [3:0] left_bits;
    always @(posedge clk) begin
        if (!rst_n) begin tx<=1; busy<=0; timer<=0; shift<=10'h3ff; left_bits<=0; end
        else if (!busy) begin
            tx<=1;
            if (send) begin
                shift<={1'b1,data,1'b0}; tx<=0; busy<=1;
                timer<=DIV-1; left_bits<=10;
            end
        end else if (timer!=0) timer<=timer-1'b1;
        else begin
            timer<=DIV-1;
            if (left_bits==1) begin busy<=0; tx<=1; end
            else begin shift<={1'b1,shift[9:1]}; tx<=shift[1]; left_bits<=left_bits-1'b1; end
        end
    end
endmodule
`default_nettype wire
