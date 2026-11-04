#!/usr/bin/env python3
"""Stress native divider/serializer startup using the independent serial receiver.
Run build_matrix.py and check_sim.py first. Only configuration GSR release time
changes; PLL, OSER10, CLKDIV and ELVDS vendor cores remain unchanged.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser()
ap.add_argument('--gsr-release-ns',nargs='+',type=int,default=[13,117,499,713,999])
a=ap.parse_args()
assert all(0<n<1000 for n in a.gsr_release_ns),'Release GSR before the bench releases external reset at 1000ns'
w=R/'work/hdmi_link/div5_ref';out=R/'work/hdmi_link/startup_phase'
out.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((w/'manifest.json').read_text())
assert m['exit_code']==0 and m['violations']=={'setup':0,'hold':0}
for p,h in m['inputs'].items():assert sha(w/p)==h,p
s=(R/'work/hdmi_link/sim/vendor.v').read_text()
old='module GSR;reg GSRO=0;initial #500 GSRO=1;endmodule'
assert old in s,'Run check_sim.py with the current extracted vendor models first'
s=s.replace(old,'module GSR;reg GSRO=0;integer release_ns;initial begin if(!$value$plusargs("GSR_RELEASE=%d",release_ns))release_ns=500;#(release_ns) GSRO=1;end endmodule')
model=out/'vendor_phase.v';model.write_text(s)
files=[D/'tb_link.v',w/'probe.v',w/'clocks.v',w/'uart_tx.v',*sorted((w/'src').rglob('*.v')),model]
exe=out/'div5_phase.vvp'
p=subprocess.run(['iverilog','-g2012','-DPROBE_DIV5','-s','tb_link','-s','GSR','-o',str(exe),*[str(p) for p in files]],cwd=w,capture_output=True,text=True)
assert p.returncode==0,p.stdout+p.stderr
results=[]
for offset in a.gsr_release_ns:
    p=subprocess.run(['vvp',str(exe),f'+GSR_RELEASE={offset}'],cwd=w,capture_output=True,text=True)
    (out/f'phase_{offset}.log').write_text(p.stdout+p.stderr)
    ok=p.returncode==0 and 'PASS independent serial' in p.stdout
    results.append({'gsr_release_ns':offset,'exit_code':p.returncode,'pass':ok})
    print(offset,ok,p.stdout.strip(),flush=True)
record={'variant':'div5_ref','results':results,'manifest_sha256':sha(w/'manifest.json'),'testbench_sha256':sha(D/'tb_link.v'),'model_sha256':sha(model),'runner_sha256':sha(Path(__file__)),'note':'Native PLL/OSER10/CLKDIV cores unchanged; configuration GSR release varied before external reset release; four lines at boot and after reset, not full VS frame.'}
(out/'results.json').write_text(json.dumps(record,indent=2)+'\n')
assert all(x['pass'] for x in results),record
