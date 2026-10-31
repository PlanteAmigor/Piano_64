#------------------------------------------------------------------
#  hdmi_test —— 1280x720@60 HDMI 点亮测试
#    HDMI 链路完全复用队友已跑通的 ir4 源码（src/hdmi/ir4/）
#------------------------------------------------------------------
set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

add_file src/hdmi/hdmi_test_top.v

# -- 来自 ir4（本板已跑通）的 DVI 发送栈 --
add_file src/hdmi/ir4/dvi_tx_tmds_enc.v
add_file src/hdmi/ir4/dvi_tx_tmds_phy.v
add_file src/hdmi/ir4/dvi_tx_clk_drv.v
add_file src/hdmi/ir4/dvi_tx_top.v
add_file src/hdmi/ir4/gowin_pll_720p.v

add_file src/hdmi/hdmi_test.cst
add_file src/hdmi/hdmi_test.sdc

set_option -top_module hdmi_test_top
set_option -output_base_name hdmi_test
set_option -use_cpu_as_gpio  1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -verilog_std sysv2017
set_option -place_option 1
set_option -route_option 1

run all
