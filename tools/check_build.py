#!/usr/bin/env python3
"""Record/verify a source-matched full build with zero setup/hold violations."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[1]
PNR=ROOT/'impl/pnr'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def inputs():
    paths=sorted(p for p in (ROOT/'src').rglob('*') if p.is_file())
    paths+=sorted(ROOT.glob('*.hex'))+[ROOT/'build_full.tcl']
    return {str(p.relative_to(ROOT)):sha(p) for p in paths}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--capture',type=Path);ap.add_argument('--record',action='store_true')
    ap.add_argument('--inputs',type=Path);opt=ap.parse_args()
    if opt.capture:
        opt.capture.parent.mkdir(parents=True,exist_ok=True)
        opt.capture.write_text(json.dumps(inputs(),indent=2)+'\n');return
    manifest=PNR/'piano64_full.manifest.json'
    if opt.record:
        assert opt.inputs,'--record requires the input snapshot captured before synthesis'
        assert inputs()==json.loads(opt.inputs.read_text()),'Sources changed during build; rebuild'
        mode_file=ROOT/'src/hdmi/ui_video_mode.vh'
        low=mode_file.exists() and '`define UI_VIDEO_720P' in mode_file.read_text()
        sdc=(ROOT/'src/piano64_hdmi.sdc').read_text()
        if low:
            for pin,mul,div in [('CLKOUT0',3,2),('CLKOUT1',15,2)]:
                assert f'-multiply_by {mul} -divide_by {div} [get_pins {{u_hdmi/u_pll/u_pixel/PLL_inst/{pin}}}]' in sdc,'Video PLL/constraint mode mismatch'
        else:
            for pin,div in [('CLKOUT0',5),('CLKOUT1',1)]:
                assert f'-multiply_by 27 -divide_by {div} [get_pins {{u_hdmi/u_pll/u_pixel/PLL_inst/{pin}}}]' in sdc,'Video PLL/constraint mode mismatch'
        html=(PNR/'piano64_full_tr_content.html').read_text()
        violations={}
        for kind in ['Setup','Hold']:
            m=re.search(r'Numbers of '+kind+r' Violated Endpoints</td>\s*<td>(\d+)</td>',html)
            assert m,'Missing timing result: '+kind
            violations[kind.lower()]=int(m[1]);assert int(m[1])==0,f'{kind} timing violations: {m[1]}'
        report=(PNR/'piano64_full.rpt.txt').read_text()
        resources={}
        for key in ['Logic','Register','BSRAM','DSP']:
            m=re.search(r'^\s*'+key+r'\s*\|\s*([\d.]+)/([\d.]+)',report,re.M)
            assert m,'Missing resource: '+key
            resources[key]=[float(m[1]),float(m[2])];assert float(m[1])<=float(m[2])
        paths=(PNR/'piano64_full.timing_paths').read_text().split('=====')
        setup=[float(p.strip().splitlines()[1]) for p in paths if p.strip().startswith('SETUP')]
        record={'video_mode':'720p60.606' if low else '1080p60','inputs':inputs(),'bitstreams':{name:sha(PNR/name) for name in ['piano64_full.fs','piano64_full.bin']},
            'violations':violations,'resources':resources,'worst_reported_setup_ns':min(setup)}
        manifest.write_text(json.dumps(record,indent=2)+'\n')
    else:
        record=json.loads(manifest.read_text())
        assert record['inputs']==inputs(),'Source differs from the bitstream; run ./build_full.sh'
        for name,want in record['bitstreams'].items():assert sha(PNR/name)==want,'Bitstream changed: '+name
        assert record['violations']=={'setup':0,'hold':0},'Timing failed'
    print('PASS full build: matching sources and bitstreams, zero setup/hold violations')
    print(json.dumps({k:v for k,v in record.items() if k not in ['inputs']},indent=2))
if __name__=='__main__':main()
