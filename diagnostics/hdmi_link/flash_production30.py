#!/usr/bin/env python3
"""Flash and readback-verify only the user-accepted complete 1080p30 build."""
from pathlib import Path
import hashlib,json,subprocess,time
R=Path(__file__).resolve().parents[2];W=R/'work/hdmi_production30'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
subprocess.run(['python3','tools/check_build.py'],cwd=R,check=True)
m=json.loads((W/'offline_verified/piano64_full.manifest.json').read_text())
assert m==json.loads((R/'impl/pnr/piano64_full.manifest.json').read_text())
assert m['video_mode']=='1080p30.303' and m['violations']=={'setup':0,'hold':0}
assert all(sha(R/p)==h for p,h in m['inputs'].items())
a=json.loads((W/'acceptance.json').read_text());b=json.loads((W/'board.json').read_text())
assert a['status']=='user_accepted_sram' and b['exit_code']==0
assert a['load_record_sha256']==sha(W/'board.json')
assert a['verification_sha256']==sha(W/'verification.json')
fs=W/'offline_verified/piano64_full.fs'
assert a['fs_sha256']==b['fs_sha256']==m['bitstreams']['piano64_full.fs']==sha(fs)
assert all(x['exit_code']==0 for x in json.loads((W/'results.json').read_text()))
cmd=['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-flash','--verify','--quiet',str(fs)]
p=subprocess.run(cmd,capture_output=True,text=True)
log=p.stdout+p.stderr;stamp=str(time.time_ns())
log_path=W/('flash_'+stamp+'.log');log_path.write_text(log)
d={'time':time.time(),'command':cmd,'exit_code':p.returncode,'fs_sha256':sha(fs),'manifest_sha256':sha(W/'offline_verified/piano64_full.manifest.json'),'sram_acceptance_sha256':sha(W/'acceptance.json'),'programmer_sha256':sha(Path(__file__)),'log':str(log_path.relative_to(R)),'log_sha256':sha(log_path),'mode':'flash','verify_requested':True,'readback_verified':p.returncode==0,'cold_boot':'pending_user_confirmation'}
for name in ['flash_'+stamp+'.json','flash.json']:(W/name).write_text(json.dumps(d,indent=2)+'\n')
print(log);print(json.dumps(d,indent=2));assert p.returncode==0
