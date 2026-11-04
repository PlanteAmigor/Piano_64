#!/usr/bin/env python3
"""Retry the near-clean serial-clock netlist using documented incremental placement.

Reuses the exact synthesized netlist and RTL of the two-endpoint-failing
experiment. Does not change timing constraints or synthesize another design.
Only starts when no other Gowin instance is active. No hardware programming.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,time
R=Path(__file__).resolve().parents[2];S=R/'work/hdmi_serial_clock60'
ap=argparse.ArgumentParser();ap.add_argument('--prepare-only',action='store_true');a=ap.parse_args()
W=R/'work/hdmi_serial_clock60_route1';assert not W.exists(),W
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((S/'manifest.json').read_text())
assert m['violations']=={'setup':2,'hold':0}
assert all(sha(S/p)==h for p,h in m['inputs'].items())
W.mkdir(parents=True)
for p in m['inputs']:
 q=W/p;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(S/p,q)
shutil.copytree(S/'impl/gwsynthesis',W/'impl/gwsynthesis')
shutil.copy2(S/'impl/pnr/piano64_full.p',W/'seed.p')
for name in ['link.log','boot.log']:shutil.copy2(S/name,W/name)
p=W/'build_full.tcl';s=p.read_text();assert s.count('run all')==1
s=s.replace('set_option -route_option 2','set_option -route_option 1')
s=s.replace('set_option -route_maxfan 16','set_option -route_maxfan 8')
s=s.replace('run all','set_option -inc_place seed.p\nrun pnr');p.write_text(s)
assert (W/'src/piano64_hdmi.sdc').read_bytes()==(S/'src/piano64_hdmi.sdc').read_bytes()
assert all(sha(W/p)==h for p,h in m['inputs'].items() if p!='build_full.tcl')
inputs={p:sha(W/p) for p in m['inputs']};inputs['seed.p']=sha(W/'seed.p')
netlist={str(p.relative_to(W)):sha(p) for p in (W/'impl/gwsynthesis').rglob('*') if p.is_file()}
(W/'netlist.json').write_text(json.dumps(netlist,indent=2)+'\n')
(W/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
d={k:v for k,v in m.items() if k not in ['inputs','violations','fs_sha256','time','checks']}
d.update(inputs=inputs,checks=m['checks'][:-1],physical_result='not tested',reused_simulation={'parent_manifest_sha256':sha(S/'manifest.json'),'rtl_and_assets_identical':True,'log_hashes':{n:sha(W/n) for n in ['link.log','boot.log']}},netlist=netlist,flow='Same netlist and SDC; incremental placement from original.p, routing algorithm1, fanout8')
(W/'prepared.json').write_text(json.dumps(d,indent=2)+'\n')
if a.prepare_only:
 print('PREPARED incremental retry; no Gowin started',flush=True);raise SystemExit(0)
assert subprocess.run(['pgrep','-x','gw_sh'],stdout=subprocess.DEVNULL).returncode!=0
os.environ['QT_QPA_PLATFORM']='offscreen';os.environ['XDG_CACHE_HOME']=str(W/'cache')
with (W/'build.log').open('w') as f:p=subprocess.run(['/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh','build_full.tcl'],cwd=W,stdout=f,stderr=subprocess.STDOUT)
d['checks'].append({'name':'build','command':['gw_sh','build_full.tcl'],'exit_code':p.returncode})
assert p.returncode==0
assert all(sha(W/p)==h for p,h in inputs.items())
assert all(sha(W/p)==h for p,h in netlist.items()),'PnR unexpectedly changed the reused synthesis snapshot'
h=(W/'impl/pnr/piano64_full_tr_content.html').read_text()
d['violations']={k.lower():int(re.search('Numbers of '+k+r' Violated Endpoints</td>\s*<td>(\d+)</td>',h)[1]) for k in ['Setup','Hold']}
d['fs_sha256']=sha(W/'impl/pnr/piano64_full.fs');d['time']=time.time()
(W/'manifest.json').write_text(json.dumps(d,indent=2)+'\n')
print(json.dumps({k:v for k,v in d.items() if k in ['violations','fs_sha256','flow']},indent=2),flush=True)
assert d['violations']=={'setup':0,'hold':0}
