#!/usr/bin/env python3
"""Select a reproducible 60 Hz video mode, updating RTL and SDC together."""
from pathlib import Path
import argparse
import re
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser();ap.add_argument('mode',choices=['720p','1080p']);args=ap.parse_args()
    low=args.mode=='720p'
    header=ROOT/'src/hdmi/ui_video_mode.vh'
    header.write_text('// Selected by tools/set_video_mode.py; timing constraints must match.\n'
                      '`ifndef UI_VIDEO_MODE_VH\n`define UI_VIDEO_MODE_VH\n'+
                      ('`define UI_VIDEO_720P\n' if low else '// Native 1080p60.\n')+'`endif\n')
    path=ROOT/'src/piano64_hdmi.sdc';s=path.read_text()
    for pin,div in [('CLKOUT0',10 if low else 5),('CLKOUT1',2 if low else 1)]:
        pattern=r'(-multiply_by 27 -divide_by )\d+( \[get_pins \{u_hdmi/u_pll/u_pixel/PLL_inst/'+pin+r'\}\])'
        s,n=re.subn(pattern,lambda m:m[1]+str(div)+m[2],s);assert n==1
    path.write_text(s)
    print(f'Selected {args.mode}60: RTL and pixel/serializer timing constraints updated; rebuild before programming.')
if __name__=='__main__':main()
