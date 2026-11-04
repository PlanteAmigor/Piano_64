#!/usr/bin/env python3
"""Load only the timing-clean, frozen 60.606Hz serialized-clock experiment."""
from pathlib import Path
import hashlib,json,re,subprocess,time

R=Path(__file__).resolve().parents[2]
W=R/'work/hdmi_serial_clock60'
B=R/'work/hdmi_production30'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((W/'manifest.json').read_text())
assert m['experimental'] and m['video_mode']=='1080p60.606'
assert m['violations']=={'setup':0,'hold':0}
assert all(sha(W/p)==h for p,h in m['inputs'].items())
assert all(x['exit_code']==0 for x in m['checks'])
assert {x['name'] for x in m['checks']}=={'link_compile','link','boot_compile','boot','build'}
assert 'PASS independent serial' in (W/'link.log').read_text()
assert 'PASS complete UI serial' in (W/'boot.log').read_text()
base=json.loads((B/'offline_verified/piano64_full.manifest.json').read_text())
accepted=json.loads((B/'acceptance.json').read_text())
assert m['base_manifest']==base
assert accepted['status']=='user_accepted_sram'
assert accepted['fs_sha256']==base['bitstreams']['piano64_full.fs']
changed={p for p,h in base['inputs'].items() if sha(W/p)!=h}
assert changed=={'src/hdmi/ui_video_mode.vh','src/piano64_hdmi.sdc','src/hdmi/ir4/dvi_tx_top.v','src/hdmi/ir4/dvi_tx_clk_drv.v'},changed
for leaf,mhz in [('CLKOUT0',150),('CLKOUT1',750)]:
 assert m['pll_clocks_mhz']['u_hdmi/u_pll/u_pixel/PLL_inst/'+leaf+'.default_gen_clk']==mhz
# A fresh parse guards the actual post-route report as well as its manifest.
h=(W/'impl/pnr/piano64_full_tr_content.html').read_text()
for kind in ['Setup','Hold']:
 assert int(re.search('Numbers of '+kind+r' Violated Endpoints</td>\s*<td>(\d+)</td>',h)[1])==0
fs=W/'impl/pnr/piano64_full.fs';assert sha(fs)==m['fs_sha256']
rpt=(W/'impl/pnr/piano64_full.rpt.txt').read_text()
assert re.search(r'--OSER10\s*\|\s*4\b',rpt),'Expected three data serializers plus one clock serializer'
cmd=['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-sram','--quiet',str(fs)]
p=subprocess.run(cmd,capture_output=True,text=True)
log=p.stdout+p.stderr;stamp=str(time.time_ns())
(W/('program_'+stamp+'.log')).write_text(log)
d={'time':time.time(),'exit_code':p.returncode,'command':cmd,'fs_sha256':sha(fs),'manifest_sha256':sha(W/'manifest.json'),'programmer_sha256':sha(Path(__file__)),'changed_production_inputs':sorted(changed),'accepted_30hz_fallback':accepted['fs_sha256'],'flash_changed':False,'user_feedback':'pending'}
for name in ['board_'+stamp+'.json','board.json']:(W/name).write_text(json.dumps(d,indent=2)+'\n')
print(log);print(json.dumps(d,indent=2));assert p.returncode==0
