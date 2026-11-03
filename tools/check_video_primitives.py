#!/usr/bin/env python3
"""Validate native 1080p clocks and plot RAM using installed Gowin models."""
from pathlib import Path
import argparse,re,subprocess,hashlib,json
from check_all import prepare_liss_reference
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--prim-sim',type=Path,default=Path('/mnt/project/ov-cli/Gowin/IDE/simlib/gw5a/prim_sim.v'))
    args=ap.parse_args();lib=args.prim_sim.read_text()
    assert '`define UI_VIDEO_720P' not in (ROOT/'src/hdmi/ui_video_mode.vh').read_text(),'Select 1080p before this clock test'
    out=ROOT/'work/video_primitives';out.mkdir(parents=True,exist_ok=True)
    for name in ['DPB','PLL']:
        match=re.search(r'^module '+name+r' \(.*?^endmodule',lib,re.M|re.S)
        assert match,'Missing vendor '+name
        (out/(name.lower()+'.v')).write_text('`timescale 1ns/1ps\n'+match[0]+'\n')
    # Keep the installed DPB model unchanged. Its global reset stays inactive;
    # the DUT exercises the individual bank reset inputs.
    (out/'global.v').write_text("module GSR; wire GSRO=1'b1; endmodule\n")
    (ROOT/'work/song_checks').mkdir(parents=True,exist_ok=True)
    prepare_liss_reference();logs=[]
    def run(name,suffix,files,extra=()):
        exe=out/(name+suffix+'.vvp')
        p=subprocess.run(['iverilog','-g2012','-s',name,'-o',str(exe),*extra,*files],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        assert p.returncode==0,p.stdout
        p=subprocess.run(['vvp',str(exe)],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (out/(name+suffix+'.log')).write_text(p.stdout)
        assert p.returncode==0 and 'PASS' in p.stdout,p.stdout
        logs.append(p.stdout);print(p.stdout,end='',flush=True)
    for bits,pb in [(7,4),(8,4),(8,2)]:
        for name in ['tb_liss_lines','tb_liss_resolution']:
            run(name,f'_{bits}_{pb}',['sim/'+name+'.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v',str(out/'dpb.v'),str(out/'global.v')],['-DUI_VENDOR_RAM_SIM','-s','GSR',f'-P{name}.BITS={bits}',f'-P{name}.PB={pb}'])
    run('tb_video_pll','',['sim/tb_video_pll.v','src/hdmi/ir4/gowin_pll_720p.v',str(out/'pll.v')])
    (out/'results.log').write_text(''.join(logs)+'All vendor video primitive checks passed.\n')
    files=['src/hdmi/ui/ui_liss_ram.v','src/hdmi/ir4/gowin_pll_720p.v','src/hdmi/ui_video_mode.vh','sim/tb_video_pll.v','sim/tb_liss_lines.v','sim/tb_liss_resolution.v']
    (out/'sources.json').write_text(json.dumps({'vendor_file':str(args.prim_sim),'vendor_sha256':hashlib.sha256(args.prim_sim.read_bytes()).hexdigest(),'inputs':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files}},indent=2)+'\n')
    print('All vendor video primitive checks passed.')
if __name__=='__main__':main()
