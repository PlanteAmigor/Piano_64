// Menu keys are slow controls: accept both edges only after a stable interval.
// Keep this separate from the latency-sensitive instrument key scanner.
`default_nettype none
module song_menu_keys #(
    parameter integer CLK_HZ=50000000, STABLE_MS=40
)(
    input wire clk, rst_n,
    input wire next_n, confirm_n,
    output wire next_state, confirm_state
);
    localparam integer TICKS=(CLK_HZ/1000)*STABLE_MS;
    localparam integer CW=TICKS<=1 ? 1 : $clog2(TICKS);
    reg [1:0] sync0, sync1, stable;
    assign {confirm_state,next_state}=stable;
    always @(posedge clk) begin
        if(!rst_n) begin sync0<=2'b11;sync1<=2'b11;end
        else begin sync0<={confirm_n,next_n};sync1<=sync0;end
    end
    genvar k;
    generate for(k=0;k<2;k=k+1) begin:g_key
        reg [CW-1:0] count;
        wire pressed=!sync1[k];
        always @(posedge clk) begin
            if(!rst_n) begin count<=0;stable[k]<=0;end
            else if(pressed==stable[k]) count<=0;
            else if(count==TICKS-1) begin stable[k]<=pressed;count<=0;end
            else count<=count+1'b1;
        end
    end endgenerate
endmodule
`default_nettype wire
