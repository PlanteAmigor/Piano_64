//==========================================================================
//  hdmi_test.sdc —— HDMI 点亮测试（1280×720@60）时序约束
//
//  ★ 板子的 CLOCK_50 = V22 是 EMCCLK（配置专用脚），不是 GCLK 引脚，
//    只能用普通布线驱动，时钟偏斜实测 ≈ 3 ns。
//    不显式 create_clock 会大面积报域内 HOLD 负值。
//
//  ⚠️ SDC 不支持反斜杠续行，每条命令必须写在一行。
//==========================================================================

create_clock -name clk_50 -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]

// PCLK = 50 x 15 / 10 = 75 MHz
create_generated_clock -name clk_pix -source [get_ports {clk}] -multiply_by 3 -divide_by 2 [get_nets {clk_p}]

// SER  = 50 x 15 / 2  = 375 MHz（= 5 x PCLK）
create_generated_clock -name clk_ser -source [get_ports {clk}] -multiply_by 15 -divide_by 2 [get_nets {clk_p5}]

set_false_path -from [get_ports {resetn}]
