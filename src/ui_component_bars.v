// Peak-hold display for pairs of modal components. Peak calculation and each
// bar's comparison are separate cycles; no 64:1 feedback read mux is needed.
`default_nettype none
module ui_component_bars #(parameter integer FALL_STEP=94)(
    input wire clk,rst_n,tick,clear,
    input wire [6:0] index,
    input wire [7:0] amplitude,
    input wire valid,
    output wire [511:0] bars
);
    localparam integer FW=FALL_STEP<2?1:$clog2(FALL_STEP);
    reg [7:0] first,peak;
    reg [5:0] peak_index;
    reg peak_valid,tick_q,clear_q;
    reg [FW-1:0] fall_div;
    reg [7:0] value[0:63];
    always @(posedge clk)begin
        if(!rst_n)begin first<=0;peak<=0;peak_index<=0;peak_valid<=0;tick_q<=0;clear_q<=0;end
        else begin
            tick_q<=tick;clear_q<=clear;peak_valid<=valid && index[0];
            if(valid)begin
                if(!index[0])first<=amplitude;
                else begin peak<=amplitude>first?amplitude:first;peak_index<=index[6:1];first<=0;end
            end
        end
    end
    integer i;
    always @(posedge clk)begin
        if(!rst_n)begin fall_div<=0;for(i=0;i<64;i=i+1)value[i]<=0;end
        else begin
            if(tick_q)begin
                if(fall_div==FALL_STEP-1)begin
                    fall_div<=0;
                    for(i=0;i<64;i=i+1)if(value[i]!=0)value[i]<=value[i]-1'b1;
                end else fall_div<=fall_div+1'b1;
            end
            if(clear_q)for(i=0;i<64;i=i+1)value[i]<=0;
            for(i=0;i<64;i=i+1)
                if(peak_valid && peak_index==i && peak>value[i])value[i]<=peak;
        end
    end
    genvar b;
    generate for(b=0;b<64;b=b+1)begin:g_bar
        assign bars[b*8+:8]=value[b];
    end endgenerate
endmodule
`default_nettype wire
