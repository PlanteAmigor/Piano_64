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
//  资源：1024×32 = 32768 bit → 2 个 BSRAM
//==========================================================================
`default_nettype none

module add_sine_lut #(
    parameter AW    = 10,
    parameter DEPTH = 1024
)(
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output reg  [31:0]   dout
);
    reg [31:0] mem [0:DEPTH-1];

    initial $readmemh("add_sine.hex", mem);

    always @(posedge clk) dout <= mem[addr];

endmodule

`default_nettype wire
