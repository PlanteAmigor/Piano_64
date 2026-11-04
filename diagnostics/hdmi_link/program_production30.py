#!/usr/bin/env python3
"""Verify the full 1080p30 candidate and load only SRAM on the selected Tang Mega."""
from pathlib import Path
import hashlib,json,shutil,subprocess,time

R=Path(__file__).resolve().parents[2]
W=R/'work/hdmi_production30'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
subprocess.run(['python3','tools/check_build.py'],cwd=R,check=True)
m=json.loads((R/'impl/pnr/piano64_full.manifest.json').read_text())
assert m['video_mode']=='1080p30.303'
checks=json.loads((W/'results.json').read_text())
assert {x['name'] for x in checks}=={'build','regression'}
assert all(x['exit_code']==0 for x in checks)
aux=json.loads((W/'auxiliary_verified.json').read_text())
assert all(x['exit_code']==0 for x in aux['vendor_and_natural_boot']['checks'])
for p,h in aux['vendor_and_natural_boot']['sources'].items():assert sha(R/p)==h,p
for p,h in json.loads((W/'screens/sources.json').read_text()).items():assert sha(R/p)==h,p
assert aux['renders']['identical_pages']==13
assert all(x['identical'] for x in json.loads((W/'screens_compare.json').read_text()))
count=0
for row in aux['latency']['records']:
 p=R/row['result'];assert sha(p)==row['sha256']
 d=json.loads(p.read_text())
 for p,h in d['sources'].items():assert sha(R/p)==h,p
 count+=len(d['measurements'])
assert count==18
backup=W/'offline_verified';backup.mkdir(exist_ok=True)
for name in ['piano64_full.fs','piano64_full.bin','piano64_full.manifest.json','piano64_full.rpt.txt','piano64_full.timing_paths','piano64_full_tr_content.html']:
 shutil.copy2(R/'impl/pnr'/name,backup/name)
for name in ['piano64_full.fs','piano64_full.bin']:assert sha(backup/name)==m['bitstreams'][name]
verification={'time':time.time(),'mode':m['video_mode'],'manifest_sha256':sha(backup/'piano64_full.manifest.json'),'auxiliary_sha256':sha(W/'auxiliary_verified.json'),'regression_log_sha256':sha(W/'regression.log'),'regression_pass_lines':sum(s.startswith('PASS') for s in (W/'regression.log').read_text().splitlines()),'latency_scenarios_reused_with_identical_sources':count,'physical_result':'pending','flash_changed':False}
(W/'verification.json').write_text(json.dumps(verification,indent=2)+'\n')
fs=backup/'piano64_full.fs'
cmd=['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-sram','--quiet',str(fs)]
p=subprocess.run(cmd,capture_output=True,text=True)
log=p.stdout+p.stderr
stamp=str(time.time_ns());(W/('program_'+stamp+'.log')).write_text(log)
board={'time':time.time(),'command':cmd,'exit_code':p.returncode,'fs_sha256':sha(fs),'verification_sha256':sha(W/'verification.json'),'flash_changed':False,'user_feedback':'pending'}
(W/('board_'+stamp+'.json')).write_text(json.dumps(board,indent=2)+'\n')
(W/'board.json').write_text(json.dumps(board,indent=2)+'\n')
print(log);print(json.dumps(board,indent=2));assert p.returncode==0
