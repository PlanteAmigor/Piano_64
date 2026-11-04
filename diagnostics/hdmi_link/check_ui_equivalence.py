#!/usr/bin/env python3
"""Compare optimized real UI RTL with accepted UI and all 13 saved pages."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess
from PIL import Image,ImageChops
R=Path(__file__).resolve().parents[2]
ap=argparse.ArgumentParser();ap.add_argument('--group-ui',action='store_true');a=ap.parse_args()
W=R/('work/hdmi_serial_clock60_group' if a.group_ui else 'work/hdmi_serial_clock60_opt');T=W/'equivalence';T.mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
old=R/'work/hdmi_production30/screens/inputs/src/hdmi/hdmi_ui3_top.v'
base=json.loads((R/'work/hdmi_production30/offline_verified/piano64_full.manifest.json').read_text())
assert sha(old)==base['inputs']['src/hdmi/hdmi_ui3_top.v']
(T/'reference.v').write_text(old.read_text().replace('module hdmi_ui3_top (','module hdmi_ui3_top_reference (',1))
bench=R/'diagnostics/hdmi_link/tb_ui_equivalence.v';s=bench.read_text()
if a.group_ui:
 for name in ['spectrum','component','liss','note_auto','note_lead','note_hit','note_edge','judgment','text','spectrum_high','liss_color','note_color','text_color']:
  s=s.replace('.'+name+'5=','.'+name+'4=')
(T/bench.name).write_text(s)
files=[T/bench.name,T/'reference.v',W/'src/hdmi/hdmi_ui3_top.v',W/'src/hdmi/ui/ui_liss_ram.v',W/'src/hdmi/ui/ui_scope_points.v']
source=sha(W/'src/hdmi/hdmi_ui3_top.v')
cmd=['iverilog','-g2012','-DSIM_UI3','-s','tb_ui_equivalence','-o',str(T/'check.vvp'),*[str(p) for p in files]]
with (T/'compile.log').open('w') as log:subprocess.run(cmd,cwd=W,stdout=log,stderr=subprocess.STDOUT,check=True)
p=subprocess.run(['vvp',str(T/'check.vvp')],cwd=W,capture_output=True,text=True)
(T/'check.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr,flush=True);assert p.returncode==0
assert 'PASS real UI equivalence' in p.stdout
for name in ['tools/render_ui1080.py','sim/tb_song_ui.v']:
 q=W/name;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(R/name,q)
cmd=['python3','tools/render_ui1080.py','--vendor-ram','--bt','--jobs','4','--verilator','/mnt/project/InstruementSound/piano64_3/work/bt_store/work/toolchain/usr/bin/verilator','--out',str(W/'screens')]
with (T/'render.log').open('w') as log:subprocess.run(cmd,cwd=W,stdout=log,stderr=subprocess.STDOUT,check=True)
for i in range(13):
 a=R/f'work/hdmi_production30/screens/ui{i}.png';b=W/f'screens/ui{i}.png'
 assert ImageChops.difference(Image.open(a).convert('RGB'),Image.open(b).convert('RGB')).getbbox() is None,i
assert sha(W/'src/hdmi/hdmi_ui3_top.v')==source
proof={'pass':True,'source_sha256':source,'reference_sha256':sha(old),'bench_sha256':sha(T/bench.name),'test_log_sha256':sha(T/'check.log'),'render_sources_sha256':sha(W/'screens/sources.json'),'identical_pages':13,'coverage':'Two actual UI modules: all512 overlay combinations across all16 fade levels, random palette; every12-bit X and Y coordinate with cross-axis window boundaries; exact RGB and registered fade/area latency. All13 rendered pages match accepted30Hz pixel for pixel.'}
(W/'ui_equivalence.json').write_text(json.dumps(proof,indent=2)+'\n');print('PASS 13 optimized full pages identical to accepted UI',flush=True)
