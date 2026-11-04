#!/usr/bin/env python3
from pathlib import Path
import argparse,re,subprocess,hashlib,json
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('--variants',nargs='+',default=['control720','cascade_old','cascade_ref','div5_ref']);a=ap.parse_args()
lib=Path('/mnt/project/ov-cli/Gowin/IDE/simlib/gw5a/prim_sim.v');text=lib.read_text();out=R/'work/hdmi_link/sim';out.mkdir(exist_ok=True,parents=True)
parts=[]
for n in ['PLL','OSER10','CLKDIV','ELVDS_OBUF']:
 m=re.search(r'^module '+n+r'\s*\(.*?^endmodule[^\n]*',text,re.M|re.S);assert m,n
 parts.append(m[0])
model=out/'vendor.v';model.write_text('`timescale 1ns/1fs\n'+'\n'.join(parts)+'\nmodule GSR;reg GSRO=0;initial #500 GSRO=1;endmodule\n')
for name in a.variants:
 w=R/'work/hdmi_link'/name;manifest=json.loads((w/'manifest.json').read_text());defs=manifest['defines']
 files=[str(D/'tb_link.v'),str(w/'probe.v'),str(w/'clocks.v'),str(w/'uart_tx.v')]+[str(p) for p in sorted((w/'src').rglob('*.v'))]+[str(model)]
 exe=out/(name+'.vvp');cmd=['iverilog','-g2012','-s','tb_link','-s','GSR','-o',str(exe)]+['-D'+x for x in defs]+files
 p=subprocess.run(cmd,cwd=w,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);assert p.returncode==0,p.stdout
 p=subprocess.run(['vvp',str(exe)],cwd=w,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/(name+'.log')).write_text(p.stdout);print(name,p.stdout,flush=True)
 assert p.returncode==0 and 'PASS independent serial' in p.stdout
 (out/(name+'.json')).write_text(json.dumps({'vendor_sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'manifest_sha256':hashlib.sha256((w/'manifest.json').read_bytes()).hexdigest(),'testbench_sha256':hashlib.sha256((D/'tb_link.v').read_bytes()).hexdigest(),'pass':True},indent=2)+'\n')
