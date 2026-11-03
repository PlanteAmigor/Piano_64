#!/usr/bin/env python3
"""Capture all nine states from the actual 1080p RTL pixel pipeline."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['sim/tb_song_ui.v','src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v']
ASSETS=['src/hdmi/ui/ui1080_font.hex','src/hdmi/ui/ui1080_tiles.hex','src/hdmi/ui/ui1080_assets.json','src/hdmi/ui/ui1080_decimal.vh']
def fingerprints():return {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in SOURCES+ASSETS}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'work/ui1080/screens_final')
    ap.add_argument('--jobs',type=int,choices=range(1,10),default=4);args=ap.parse_args()
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);before=fingerprints()
    frozen=out/'inputs';frozen.mkdir(exist_ok=True)
    for relative in SOURCES+ASSETS:
        target=frozen/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/relative,target)
    assert {p:hashlib.sha256((frozen/p).read_bytes()).hexdigest() for p in SOURCES+ASSETS}==before
    def capture(shot):
        exe=out/f'ui{shot}.vvp';ppm=out/f'ui{shot}.ppm'
        with (out/f'ui{shot}.log').open('w') as f:
            subprocess.run(['iverilog','-g2012','-DSIM_UI3','-s','tb_song_ui',f'-Ptb_song_ui.SHOT={shot}','-o',str(exe),*SOURCES],cwd=frozen,stdout=f,stderr=subprocess.STDOUT,check=True)
            subprocess.run(['vvp',str(exe),f'+OUT={ppm}'],cwd=frozen,stdout=f,stderr=subprocess.STDOUT,check=True)
        im=Image.open(ppm);assert im.size==(1920,1080)
        assert im.getbbox() and len(im.getcolors(1920*1080))>10
        if shot==5:
            assert im.getpixel((40,192))==(48,66,87),'main panel border pixel alignment'
            assert im.getpixel((39,192))==(9,15,25),'background pixel alignment'
        if shot not in [5,6]:assert im.getpixel((760,864))==(246,199,126),'judgment line alignment'
        im.save(out/f'ui{shot}.png');print(f'PASS actual 1080p RTL screenshot {shot}',flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(capture,range(9)))
    # Captures always use their saved source bundle. A delivery must compare
    # sources.json with its final source files before claiming a current image.
    canvas=Image.new('RGB',(1920,1080))
    for i in range(9):
        with Image.open(out/f'ui{i}.png') as im:canvas.paste(im.resize((640,360)),((i%3)*640,(i//3)*360))
    canvas.save(out/'contact.png');(out/'sources.json').write_text(json.dumps(before,indent=2)+'\n')
if __name__=='__main__':main()
