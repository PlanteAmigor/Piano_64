create_clock -name CLOCK_50 -period 20.000 -waveform {0.000 10.000} [get_ports {CLOCK_50}]
create_generated_clock -name CLK_SYS -source [get_ports {CLOCK_50}] -divide_by 1 [get_nets {scope_clk}]
set_false_path -from [get_ports {RESET_n}]

# Async CDC: CLK_SYS -> CLOCK_50
# u_led (WS2812) runs on raw CLOCK_50; all of its control signals come from
# the clk_sys domain. add_top.v registers them through a 2-FF synchronizer,
# so this crossing is a normal asynchronous CDC and must not be timed as a
# synchronous path.
set_false_path -from [get_clocks {CLK_SYS}] -to [get_clocks {CLOCK_50}]

# External output delay for I2S.
# Was -max 10.000, which reserved half of the 20 ns period for the board and
# left only 10 ns inside, causing AUD_DIN slack = -0.085 ns. PCM5102A needs
# only a few ns of setup, so relax to 8.000 (12 ns internal budget).
set_output_delay -clock CLOCK_50 -max 8.000 [get_ports {AUD_BCK AUD_LRCK AUD_DIN}]
set_output_delay -clock CLOCK_50 -min 0.000  [get_ports {AUD_BCK AUD_LRCK AUD_DIN}]

#==========================================================================
#  DDR3 时钟域（来自 ddr_bringup 的已验证约束）
#    clk400  : memory_clk 400 MHz
#    sysclk  : DDR IP 内部的用户接口时钟 clk_x1（100 MHz）
#  三个域互斥：音频侧 50 MHz 与 DDR 侧 100/400 MHz 完全异步。
#==========================================================================
create_clock -name clk400 -period 2.5 -waveform {0 1.25} [get_nets {u_audio/u_ddr/memory_clk}]
create_clock -name sysclk -period 10 -waveform {0 5} [get_pins {u_audio/u_ddr/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
set_clock_groups -exclusive -group [get_clocks {clk400}] -group [get_clocks {CLOCK_50}] -group [get_clocks {sysclk}]

#==========================================================================
#  SD → DDR 加载器（2026-10-31 加入）
#
#  分两个域：
#    CLOCK_50 (20 ns) : sd_file_list_reader（FAT32 簇链里有组合乘法，
#                       在 100 MHz 下实测 SETUP = −6.175 ns，必须留在 50 MHz）
#    sysclk  (10 ns)  : 拼 256 位 / 写 DDR / 读回校验 / 串口
#  中间是 sd_async_fifo（格雷码异步 FIFO）→ 两域互斥已由上面的
#  set_clock_groups -exclusive 覆盖，这里再显式声明一次以防顺序问题。
#
#  为什么还要补 CLK_SYS ↔ sysclk：
#    ddr_wrap 的 rst_n = por_n & RESET_n，por_n 产生在 CLK_SYS 域，
#    却喂进 DDR IP 的复位。这是纯复位扇出，不该按同步路径检查。
#
#  SD / UART 是慢速外设（SD 12.5 MHz、UART 115200），不需要 IO 时序预算。
#==========================================================================
set_false_path -from [get_clocks {CLOCK_50}] -to [get_clocks {sysclk}]
set_false_path -from [get_clocks {sysclk}]  -to [get_clocks {CLOCK_50}]
set_false_path -from [get_clocks {CLK_SYS}] -to [get_clocks {sysclk}]
set_false_path -from [get_clocks {sysclk}]  -to [get_clocks {CLK_SYS}]
set_false_path -from [get_ports {SD_CLK}]
set_false_path -to   [get_ports {SD_CMD SD_DAT0}]
set_false_path -from [get_ports {UART_TX}]

//==========================================================================
//  HDMI 1080p60 时钟域（合并顶层新增）
//
//  像素时钟来自 u_hdmi 里的 Gowin_PLL_720P，与音频侧 CLK_SYS 完全异步。
//  原来在 hdmi_test.sdc 里这片 PLL 就是顶层，net 名是 clk_p / clk_p5；
//  合并后它下沉到 u_hdmi 内部，所以这里改用【PLL 实例的输出引脚】定位，
//  避免依赖层级 net 名。
//
//  50 MHz -> PCLK = 148.5 MHz (297/100)
//  50 MHz -> SER  = 742.5 MHz (297/20, 5 × PCLK)
//==========================================================================



create_generated_clock -name clk_pix -source [get_ports {CLOCK_50}] -multiply_by 3 -divide_by 1 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_ser -source [get_ports {CLOCK_50}] -multiply_by 15 -divide_by 1 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}]

// BANDS / BANDS_TICK 是 clk_sys -> clk_p 的慢变量跨域（详见 hdmi_spec_top.v），
// 不按同步路径检查
set_false_path -from [get_clocks {CLK_SYS}] -to [get_clocks {clk_pix}]
set_false_path -from [get_clocks {clk_pix}] -to [get_clocks {CLK_SYS}]
set_false_path -from [get_clocks {CLK_SYS}] -to [get_clocks {clk_ser}]
set_false_path -from [get_clocks {clk_ser}] -to [get_clocks {CLK_SYS}]

# Per-clock diagnostics: prevent one failing domain hiding all other paths.
report_timing -setup -from_clock [get_clocks {CLOCK_50}] -to_clock [get_clocks {CLOCK_50}] -max_paths 200
report_timing -setup -from_clock [get_clocks {CLK_SYS}] -to_clock [get_clocks {CLK_SYS}] -max_paths 200
report_timing -setup -from_clock [get_clocks {sysclk}] -to_clock [get_clocks {sysclk}] -max_paths 200
report_timing -setup -from_clock [get_clocks {clk_pix}] -to_clock [get_clocks {clk_pix}] -max_paths 200
