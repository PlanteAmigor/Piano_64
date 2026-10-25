create_clock -name CLOCK_50 -period 20.000 -waveform {0.000 10.000} [get_ports {CLOCK_50}]
create_generated_clock -name CLK_SYS -source [get_ports {CLOCK_50}] -divide_by 1 [get_nets {clk_sys}]
set_false_path -from [get_ports {RESET_n}]
set_false_path -from [get_ports {KEY[*]}]

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
