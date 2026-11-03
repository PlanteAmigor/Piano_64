#------------------------------------------------------------------
#  piano64 —— 64 路加法分量钢琴 + 7 键直弹
#------------------------------------------------------------------
set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

add_file src/add_top.v
add_file src/audio_soft_limiter.v
# ★ 128 分量引擎（当前使用）。旧的 64 分量版本 add_voice.v / add_engine.v
#   保留在仓库里作为参考与回退方案，但不参与本次综合。
add_file src/add_engine8.v
add_file src/add_engine_harm.v
add_file src/harm_buf.v
add_file src/add_voice8.v
add_file src/param_cache.v
add_file src/param_dma.v
add_file src/ddr_param_dma.v
add_file src/suona_dma.v
add_file src/mix_sum.v
add_file src/add_param_rom.v
add_file src/add_sine_lut.v
add_file src/key_scan.v
add_file src/key_dual.v
add_file src/note_alloc.v
add_file src/pcm5102a_tx.v
add_file src/ws2812_keyind.v
# ── 赛题「测试模式」：8 路纯正弦（C3..C10），KEY.0 进出 ──
add_file src/test_sine8.v
# ── 32 段常数-Q 频谱（ROM 表 spec_*.hex 由 tools/gen_spec_cqt.py 生成）──
add_file src/spec_cqt.v

add_file src/pll50.v
add_file src/pll_init.v
add_file src/gowin_pll/gowin_pll.v
add_file src/gowin_pll/gowin_pll_mod.v

# ── SD 卡 FAT32 读卡栈（来自 sd_bringup，已上板验证）──
add_file src/sd/sd_file_list_reader.v
add_file src/sd/sd_reader.sv
add_file src/sd/sdcmd_ctrl.sv
add_file src/sd/uart_tx.v
add_file src/sd/sd_async_fifo.v
# ── SD → DDR3 加载器 ──
add_file src/sd_ddr_loader.v
add_file src/song/bt_frame_rx.v
add_file src/song/bt_song_player.v
add_file src/song/song_fifo.v
add_file src/song/song_loader.v
add_file src/song/song_system.v
add_file src/song/song_menu_keys.v

add_file src/piano64.cst
add_file src/piano64.sdc

# ── DDR3 1 GiB（仓层）──
add_file src/ddr/ddr_wrap.v
add_file src/ddr/ddr_ui_pipeline.v
add_file src/ddr/ddr3_memory_interface.v
add_file src/ddr/gowin_pll.v
add_file src/ddr/gowin_pll_mod.v
add_file src/ddr/pll_init.v
# ★★ 绝对不要再 add_file src/ddr/ddr3_1v4_hs.cst ★★
#   gw_sh 只把【最后一个 .cst】当物理约束文件，前面加的全部被静默忽略。
#   两个 cst 同时 add 的结果是 piano64.cst 失效 → CLOCK_50 被自动放到
#   Y11（不是晶振脚）→ 全设计无时钟 → 没声 + 灯带不亮。
#   DDR 引脚已合并进 src/piano64.cst，那个文件仅作备份留档。

set_option -top_module add_top
set_option -output_base_name piano64
set_option -use_cpu_as_gpio  1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
# ★ 官方 sd_file_list_reader.v 用了 output [7:0] list_name[0:51] 这种
#   非压缩数组端口，Verilog-2001 不认，必须开 SystemVerilog
set_option -verilog_std sysv2017

run all
