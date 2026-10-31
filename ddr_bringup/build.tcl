#------------------------------------------------------------------
#  ddr_bringup —— DDR3 读写自测（第 1 步：证明 DDR 能正确读写）
#
#  构建：
#      export TMPDIR=/mnt/project/InstruementSound/.tmp
#      export LD_LIBRARY_PATH=/mnt/project/ov-cli/Gowin/IDE/lib
#      export QT_QPA_PLATFORM=xcb
#      /mnt/project/ov-cli/Gowin/IDE/bin/gw_sh build.tcl
#
#  注意：`ip/ddr3_memory_interface.v` 是 Gowin 加密网表，
#        综合器会自动解密，不需要 IP Core Generator。
#        CPU/MSPI/SSPI 保持默认 false（与官方 DDR3 例程一致，
#        因为 DDR 占用了大量专用脚）。
#------------------------------------------------------------------
set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

# ---- DDR3 控制器（官方生成的加密网表，不要改）
add_file ip/ddr3_memory_interface.v
add_file ip/gowin_pll.v
add_file ip/gowin_pll_mod.v
add_file ip/pll_init.v

# ---- 我们自己的逻辑
add_file src/uart_tx.v
add_file src/ddr_selftest.v
add_file src/top.v

# ---- 引脚与时序（从官方 DDR3 例程原样复制）
add_file constr/ddr3_1v4_hs.cst
add_file constr/ddr3_1v4_hs.sdc

set_option -top_module top
set_option -output_base_name ddr_test

run all
