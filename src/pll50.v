//==========================================================================
//  pll50 —— 50 MHz 进 → 50 MHz 出，作用只是把时钟放到【全局时钟网】
//
//  为什么需要它：
//    CLOCK_50 = V22 是 EMCCLK（配置专用脚），不是 GCLK 引脚，综合器只能用
//    普通布线驱动 → 实测时钟偏斜 ≈ 3 ns，20 ns 周期被吃掉 15%，
//    全设计 25 条 setup 违例（灯带那条 slack 只有 +0.275 ns → 随机乱闪）。
//    试过 CLOCK_LOC 全局时钟分配约束（SUG935 A.8），V22 物理上到不了 PCLK 网。
//    过一级 PLL 才能上全局网。
//
//  PLL 由 Gowin IDE 的 IP Core Generator 生成（教育版工具不接受手写 PLLG 例化，
//  会报 unknown module）。生成物在 src/gowin_pll/：
//      Gowin_PLL      顶层，端口 clkin / init_clk / clkout0
//      Gowin_PLL_MOD  实际 PLLG 原语
//      PLL_INIT       动态环路校准状态机（GW5AST 需要）
//  配置（gowin_pll.ipc）: ClkinClockFrequency=50, Clkout0ExpectedFrequency=50
//                        ClkfbInternal=true, VCO=400 MHz
//
//  init_clk 接同一路 50 MHz（PLL_INIT 用它做校准计时）。
//  生成的 IP 没引出 lock，所以 lock 恒 1，上电靠 por_cnt 兜住。
//
//  ★ 仿真时 `define SIM_PLL 绕过（iverilog 不认 PLLG 原语）
//==========================================================================
`default_nettype none

module pll50 (
    input  wire clk_in,
    output wire clk_out,
    output wire lock
);

`ifdef SIM_PLL
    assign clk_out = clk_in;
    assign lock    = 1'b1;
`else
    Gowin_PLL u_pll (
        .clkin   (clk_in),
        .init_clk(clk_in),
        .clkout0 (clk_out)
    );
    assign lock = 1'b1;
`endif

endmodule

`default_nettype wire
