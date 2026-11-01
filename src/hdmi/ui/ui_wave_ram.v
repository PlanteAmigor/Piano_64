//==========================================================================
//  ui_wave_ram —— 波形环形缓冲 1024 × 16bit
//
//  写口：每个 sample_tick 写一个样点，地址自增
//  读口：扫描时按像素取（还能取到「下一个」样点用来画竖线）
//  单时钟（像素时钟域），读写同域，双口 BSRAM。
//==========================================================================
`default_nettype none

module ui_wave_ram (
    input  wire        clk,

    // 写口（样点）
    input  wire        we,
    input  wire [9:0]  waddr,
    input  wire signed [15:0] wdata,

    // 读口（扫描）
    input  wire [9:0]  raddr,
    output reg  signed [15:0] rdata
);
    reg signed [15:0] m [0:1023];

    always @(posedge clk) begin
        if (we) m[waddr] <= wdata;
    end

    always @(posedge clk) begin
        rdata <= m[raddr];
    end
endmodule

`default_nettype wire
