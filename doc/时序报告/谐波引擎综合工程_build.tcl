set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C

add_file harm_synth.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/add_engine_harm.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/harm_rom.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/mix_sum.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/pll50.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/pll_init.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/gowin_pll/gowin_pll.v
add_file /mnt/project/InstruementSound/piano64_handoff/piano64/src/gowin_pll/gowin_pll_mod.v
add_file harm_synth.cst
add_file harm_synth.sdc

set_option -top_module harm_synth
set_option -output_base_name harm_synth
set_option -use_cpu_as_gpio  1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1

set_option -place_option 2
set_option -route_option 1

run all
