#------------------------------------------------------------------
#  piano64_top —— 音频引擎 + HDMI 32 段频谱（单比特流）
#
#  与 build.tcl 的区别：
#    build.tcl       顶 = add_top     只有音频（频谱逻辑在但没人消费）
#    build_full.tcl  顶 = piano64_top  音频 + 1080p 频谱显示
#
#  ★ 约束文件必须用【拼接过】的 piano64_hdmi.cst / piano64_hdmi.sdc，
#    因为 gw_sh 只认最后一个 .cst/.sdc。
#------------------------------------------------------------------
set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

#══════════════════════════════════════════════════════════════════
#  音频引擎（与 build.tcl 完全相同的文件列表）
#══════════════════════════════════════════════════════════════════
add_file src/add_top.v
add_file src/audio_soft_limiter.v
add_file src/ui_component_bars.v
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
# ── 赛题「测试模式」：8 路纯正弦，KEY.0 进出 ──
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
add_file src/sd_ddr_loader.v
add_file src/song/bt_frame_rx.v
add_file src/song/bt_song_player.v
add_file src/song/song_fifo.v
add_file src/song/song_loader.v
add_file src/bt/bt_uart_rx.v
add_file src/bt/bt_uart_tx.v
add_file src/bt/bt_song_upload.v
add_file src/song/song_file_encode.v
add_file src/sd/sd_sector_rw.sv
add_file src/sd/fat32_song_store.v
add_file src/sd/song_sd_save.v
add_file src/song/song_system.v
add_file src/song/song_menu_keys.v

#══════════════════════════════════════════════════════════════════
#  HDMI 1080p 频谱显示（复用 ir4 已验证的 DVI 栈）
#══════════════════════════════════════════════════════════════════
add_file src/hdmi/hdmi_ui3_top.v
add_file src/hdmi/ui/ui_liss_ram.v
add_file src/hdmi/ui/ui_scope_points.v
add_file src/hdmi/ir4/dvi_tx_tmds_enc.v
add_file src/hdmi/ir4/dvi_tx_tmds_phy.v
add_file src/hdmi/ir4/dvi_tx_clk_drv.v
add_file src/hdmi/ir4/dvi_tx_top.v
add_file src/hdmi/ir4/gowin_pll_720p.v

#══════════════════════════════════════════════════════════════════
#  合并顶层
#══════════════════════════════════════════════════════════════════
add_file src/piano64_top.v

# ── DDR3 1 GiB（仓层）──
add_file src/ddr/ddr_wrap.v
add_file src/ddr/ddr_ui_pipeline.v
add_file src/ddr/ddr3_memory_interface.v
add_file src/ddr/gowin_pll.v
add_file src/ddr/gowin_pll_mod.v
add_file src/ddr/pll_init.v

# ── DDR 用户口 4 路仲裁（alexforencich/verilog-axi，MIT）──
add_file src/ddr/priority_encoder.v
add_file src/ddr/arbiter.v
add_file src/ddr/ddr_arb.v

# ── 效果器 ──
add_file src/fx/fx_chorus.v
add_file src/fx/fx_delay.v
add_file src/fx/fx_reverb.v

# ── 六路光敏前端（TDM 发射 + AD7606 双串行 + 亮暗差分 + 串口上报）──
add_file src/optical/ir_tdm_ctrl.v
add_file src/optical/ad7606_serial.v
add_file src/optical/ir_diff_filter.v
add_file src/optical/report6.v
add_file src/optical/opt_feat.v
add_file src/optical/opt_pos.v
add_file src/optical/position_control.v
add_file src/optical/report_feat.v

# ★ 只用拼接后的约束文件（= piano64.cst + TMDS 四对差分）
add_file src/piano64_hdmi.cst
add_file src/piano64_hdmi.sdc

set_option -top_module piano64_top
set_option -output_base_name piano64_full
set_option -use_cpu_as_gpio  1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -verilog_std sysv2017
# Layout/routing algorithms; validate global setup and hold after every build.
set_option -place_option 3
set_option -route_option 2
set_option -replicate_resources 1
set_option -route_maxfan 16

run all
