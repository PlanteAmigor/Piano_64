#------------------------------------------------------------------
#  piano64 —— 64 路加法分量钢琴 + 7 键直弹
#------------------------------------------------------------------
set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

add_file src/add_top.v
add_file src/add_engine.v
add_file src/add_voice.v
add_file src/mix_sum.v
add_file src/add_param_rom.v
add_file src/add_sine_lut.v
add_file src/key_scan.v
add_file src/note_alloc.v
add_file src/pcm5102a_tx.v
add_file src/ws2812_keyind.v

add_file src/pll50.v
add_file src/pll_init.v
add_file src/gowin_pll/gowin_pll.v
add_file src/gowin_pll/gowin_pll_mod.v

add_file src/piano64.cst
add_file src/piano64.sdc

set_option -top_module add_top
set_option -output_base_name piano64
set_option -use_cpu_as_gpio  1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1

run all
