`default_nettype none
module bt_uart_rx #(parameter integer CLK_HZ=50000000, BAUD=115200)(
    input wire clk, rst_n, rx, output reg [7:0] data,
    output reg valid, output reg framing_error
);
    localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(DIV<=2) ? 1 : $clog2(DIV);
    reg [1:0] sync_rx;
    reg [CW-1:0] timer;
    reg [3:0] bit_no;
    reg busy;
    always @(posedge clk) begin
        if (!rst_n) begin
            sync_rx<=3; timer<=0; bit_no<=0; busy<=0;
            valid<=0; framing_error<=0; data<=0;
        end else begin
            sync_rx<={sync_rx[0],rx}; valid<=0; framing_error<=0;
            if (!busy) begin
                if (!sync_rx[1]) begin busy<=1; timer<=DIV/2-1; bit_no<=0; end
            end else if (timer!=0) timer<=timer-1'b1;
            else begin
                timer<=DIV-1;
                if (bit_no==0) begin
                    if (sync_rx[1]) busy<=0; else bit_no<=1;
                end else if (bit_no<=8) begin
                    data[bit_no-1]<=sync_rx[1]; bit_no<=bit_no+1'b1;
                end else begin
                    busy<=0;
                    if (sync_rx[1]) valid<=1; else framing_error<=1;
                end
            end
        end
    end
endmodule
`default_nettype wire
