//==========================================================================
//  add_sine_lut —— 加法分量的正弦表（配对存放，一次同步读给出插值两端）
//
//  1024 项，每项 32bit = { sin(i+1), sin(i) }   （i=1023 时 i+1 回绕到 0）
//  sin(i) = round(32767·sin(2π·i/1024))，16bit 有符号
//
//  ── 相位怎么切 ────────────────────────────────────────────────────
//    phase[31:0] 表示 0..2π 的一圈
//      phase[31:22] = 表地址 i      (10bit → 1024 点)
//      phase[21:12] = 插值系数 frac (10bit → frac/1024)
//
//  ── 为什么必须插值 ────────────────────────────────────────────────
//    1024 点正弦 + 线性插值的最大误差 ≈ π²/(2N²) = 4.7e-6（−106 dB）
//    不插值的话相位截断会变成一层宽带杂音（在 i2s_twinkle 上实测过：
//    不插值 SNR 48 dB，插值后 92 dB）。
//
//  四分之一周期以256个相邻点配对字存储；奇数象限反向读取并交换
//  插值两端，负半周逐端取负。保留原1024个配对字和一拍读延迟，
//  包括90°/180°/270°和1023→0边界，不改变采样点或插值精度。
//  资源目标：256×32 = 8192 bit → 1 个 BSRAM / 独立读口。
//==========================================================================
`default_nettype none

module add_sine_lut #(
    parameter AW    = 10,
    parameter DEPTH = 1024
)(
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output wire [31:0]   dout
);
    generate if(AW==10 && DEPTH==1024)begin:g_quarter
        reg [31:0] mem[0:255];
        initial $readmemh("add_sine_quarter.hex",mem);
        wire [7:0] quarter_addr=addr[8]?~addr[7:0]:addr[7:0];
        reg [31:0] pair_q;
        reg swap_q,negative_q;
        always @(posedge clk)begin
            pair_q<=mem[quarter_addr];swap_q<=addr[8];negative_q<=addr[9];
        end
        wire [15:0] lo=swap_q?pair_q[31:16]:pair_q[15:0];
        wire [15:0] hi=swap_q?pair_q[15:0]:pair_q[31:16];
        assign dout={negative_q?(16'd0-hi):hi,negative_q?(16'd0-lo):lo};
    end else begin:g_full
        reg [31:0] mem[0:DEPTH-1];
        reg [31:0] data_q;
        initial $readmemh("add_sine.hex",mem);
        always @(posedge clk)data_q<=mem[addr];
        assign dout=data_q;
    end endgenerate

endmodule

`default_nettype wire
