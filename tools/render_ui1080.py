#!/usr/bin/env python3
"""Capture all nine states from the actual 1080p RTL pixel pipeline."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import os
import re
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['sim/tb_song_ui.v','src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v']
ASSETS=['src/hdmi/ui/ui1080_font.hex','src/hdmi/ui/ui1080_tiles.hex','src/hdmi/ui/ui1080_assets.json','src/hdmi/ui/ui1080_decimal.vh','src/hdmi/ui_video_mode.vh']
def fingerprints():return {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in SOURCES+ASSETS}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'work/ui1080/screens_final')
    ap.add_argument('--jobs',type=int,choices=range(1,14),default=4)
    ap.add_argument('--verilator',type=Path,help='Optional Verilator executable for faster compilation and rendering')
    ap.add_argument('--bt',action='store_true',help='Also capture receiving/saving/saved/error states')
    ap.add_argument('--vendor-ram',action='store_true',help='Use the installed Gowin DPB model for every screenshot')
    ap.add_argument('--prim-sim',type=Path,default=Path('/mnt/project/ov-cli/Gowin/IDE/simlib/gw5a/prim_sim.v'))
    args=ap.parse_args()
    low='`define UI_VIDEO_720P' in (ROOT/'src/hdmi/ui_video_mode.vh').read_text()
    size=(1280,720) if low else (1920,1080)
    def output_pixel(x,y):
        return ((2*x+2)//3,(2*y+2)//3) if low else (x,y)
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);before=fingerprints()
    frozen=out/'inputs';frozen.mkdir(exist_ok=True)
    for relative in SOURCES+ASSETS:
        target=frozen/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/relative,target)
    assert {p:hashlib.sha256((frozen/p).read_bytes()).hexdigest() for p in SOURCES+ASSETS}==before
    compile_sources=list(SOURCES);defines=['-DSIM_UI3']
    if args.vendor_ram:
        library=args.prim_sim.read_text();models=[]
        for name in ['DPB','GSR']:
            match=re.search(r'^module '+name+r' \(.*?^endmodule',library,re.M|re.S)
            assert match,'Missing vendor primitive '+name
            models.append(match[0])
        generated=frozen/'sim/vendor_dpb.v'
        generated.write_text('`timescale 1ns/1ps\n'+'\n'.join(models)+'\n')
        compile_sources.append('sim/vendor_dpb.v');defines.append('-DUI_VENDOR_RAM_SIM')
        (out/'vendor.json').write_text(json.dumps({'library':str(args.prim_sim),'library_sha256':hashlib.sha256(args.prim_sim.read_bytes()).hexdigest(),'extracted_model_sha256':hashlib.sha256(generated.read_bytes()).hexdigest()},indent=2)+'\n')
    verilated=None
    if args.verilator:
        tool=args.verilator.resolve();env=os.environ.copy()
        bundled=tool.parent.parent/'share/verilator'
        if bundled.exists():env['VERILATOR_ROOT']=str(bundled)
        target=out/'verilated'
        with (out/'compile.log').open('w') as f:
            subprocess.run([str(tool),'--binary','--timing','-Wno-fatal','--top-module','tb_song_ui',
                *defines,'--Mdir',str(target),'-j','8',*compile_sources],cwd=frozen,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
        verilated=target/'Vtb_song_ui'
    def capture(shot):
        exe=out/f'ui{shot}.vvp';ppm=out/f'ui{shot}.ppm'
        with (out/f'ui{shot}.log').open('w') as f:
            if verilated:
                subprocess.run([str(verilated),f'+SHOT={shot}',f'+OUT={ppm}'],cwd=frozen,stdout=f,stderr=subprocess.STDOUT,check=True)
            else:
                subprocess.run(['iverilog','-g2012',*defines,'-s','tb_song_ui',f'-Ptb_song_ui.SHOT={shot}','-o',str(exe),*compile_sources],cwd=frozen,stdout=f,stderr=subprocess.STDOUT,check=True)
                subprocess.run(['vvp',str(exe),f'+OUT={ppm}'],cwd=frozen,stdout=f,stderr=subprocess.STDOUT,check=True)
        im=Image.open(ppm);assert im.size==size
        assert im.getbbox() and len(im.getcolors(size[0]*size[1]))>10
        if shot==5:
            assert im.getpixel(output_pixel(40,192))==(48,66,87),'main panel border pixel alignment'
            assert im.getpixel(output_pixel(38,192))==(9,15,25),'background pixel alignment'
        if shot not in [5,6]:assert im.getpixel(output_pixel(760,864))==(246,199,126),'judgment line alignment'
        im.save(out/f'ui{shot}.png');print(f'PASS actual {size[0]}x{size[1]} RTL screenshot {shot}',flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(capture,range(13 if args.bt else 9)))
    # Captures always use their saved source bundle. A delivery must compare
    # sources.json with its final source files before claiming a current image.
    canvas=Image.new('RGB',(1920,1080))
    for i in range(9):
        with Image.open(out/f'ui{i}.png') as im:canvas.paste(im.resize((640,360)),((i%3)*640,(i//3)*360))
    canvas.save(out/'contact.png')
    if args.bt:
        bt=Image.new('RGB',(1920,1080))
        for i in range(4):
            with Image.open(out/f'ui{i+9}.png') as im:bt.paste(im.resize((960,540)),((i%2)*960,(i//2)*540))
        bt.save(out/'bluetooth.png')
    (out/'sources.json').write_text(json.dumps(before,indent=2)+'\n')
if __name__=='__main__':main()
