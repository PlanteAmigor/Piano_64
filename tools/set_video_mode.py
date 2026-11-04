#!/usr/bin/env python3
"""Select a reproducible video mode, updating RTL and SDC together."""
from pathlib import Path
import argparse
import re
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser();ap.add_argument('mode',choices=['720p','1080p','1080p-single','1080p30-single']);args=ap.parse_args()
    low=args.mode=='720p'
    single=args.mode in ['1080p-single','1080p30-single']
    half=args.mode=='1080p30-single'
    header=ROOT/'src/hdmi/ui_video_mode.vh'
    header.write_text('// Selected by tools/set_video_mode.py; timing constraints must match.\n'
                      '`ifndef UI_VIDEO_MODE_VH\n`define UI_VIDEO_MODE_VH\n'+
                      ('`define UI_VIDEO_720P\n' if low else ('`define UI_VIDEO_1080P_SINGLE\n'+('`define UI_VIDEO_1080P_HALF\n' if half else '') if single else '// Native 1080p60.\n'))+'`endif\n')
    path=ROOT/'src/piano64_hdmi.sdc';s=path.read_text()
    lines=s.splitlines()
    lines=[line for line in lines if not any(line.startswith('create_generated_clock -name '+name) for name in ['clk_hdmi_ref','clk_pix','clk_ser'])]
    clocks=(
        'create_generated_clock -name clk_pix -source [get_ports {CLOCK_50}] -multiply_by 3 -divide_by 2 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT0}]\n'
        'create_generated_clock -name clk_ser -source [get_ports {CLOCK_50}] -multiply_by 15 -divide_by 2 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}]'
    ) if low else (
        'create_generated_clock -name clk_hdmi_ref -source [get_ports {CLOCK_50}] -multiply_by 11 -divide_by 20 [get_pins {u_hdmi/u_pll/u_ref/PLL_inst/CLKOUT0}]\n'
        'create_generated_clock -name clk_ser -source [get_pins {u_hdmi/u_pll/u_ref/PLL_inst/CLKOUT0}] -multiply_by 27 -divide_by 1 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}]\n'
        'create_generated_clock -name clk_pix -source [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}] -divide_by 5 [get_pins {u_hdmi/u_pll/u_pixel_div/CLKOUT}]'
    )
    if single:
        div=2 if half else 1
        clocks=(f'create_generated_clock -name clk_pix -source [get_ports {{CLOCK_50}}] -multiply_by 3 -divide_by {div} [get_pins {{u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT0}}]\n'
                f'create_generated_clock -name clk_ser -source [get_ports {{CLOCK_50}}] -multiply_by 15 -divide_by {div} [get_pins {{u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}}]')
    anchor=next(i for i,line in enumerate(lines) if line.startswith('// BANDS / BANDS_TICK'))
    lines.insert(anchor,clocks+'\n');s='\n'.join(lines)+'\n'
    path.write_text(s)
    print(f'Selected {args.mode}: RTL and pixel/serializer timing constraints updated; rebuild before programming.')
if __name__=='__main__':main()
