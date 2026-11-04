#!/usr/bin/env python3
"""Program timing-clean full black-screen diagnostic and capture fresh telemetry."""
from pathlib import Path
import argparse,hashlib,json,os,re,select,subprocess,termios,time
R=Path(__file__).resolve().parents[2]
ap=argparse.ArgumentParser();ap.add_argument('--half-rate',action='store_true');a=ap.parse_args()
W=R/'work/hdmi_black'/('full_debug30' if a.half_rate else 'full_debug')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((W/'manifest.json').read_text());assert m['exit_code']==0 and m['violations']=={'setup':0,'hold':0}
assert all(sha(W/f)==h for f,h in m['inputs'].items())
sim=json.loads((R/'work/hdmi_black'/('debug_serial30' if a.half_rate else 'debug_serial')/'results.json').read_text())
assert sim['frozen_inputs_sha256']==sha(W/'inputs.json')
assert {x['mode'] for x in sim['results']}=={1,2}
for row in sim['results']:
 assert row['pass'] and all(sha(Path(p))==h for p,h in row['sources'].items())
fs=W/'impl/pnr/piano64_full.fs';assert sha(fs)==m['fs_sha256']
syn=(W/'impl/gwsynthesis/piano64_full_syn.rpt.html').read_text();clocks={}
for row in re.findall(r'<tr[^>]*>(.*?)</tr>',syn,re.S):
 cells=[re.sub(r'<[^>]+>','',s).strip() for s in re.findall(r'<td[^>]*>(.*?)</td>',row,re.S)]
 if len(cells)>=10 and cells[2]=='Generated':clocks[cells[1]]=float(cells[4])
for leaf,mhz in [('CLKOUT0',75 if a.half_rate else 150),('CLKOUT1',375 if a.half_rate else 750)]:assert clocks.get('u_hdmi/u_pll/u_pixel/PLL_inst/'+leaf+'.default_gen_clk')==mhz
p=subprocess.run(['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-sram','--quiet',str(fs)],capture_output=True,text=True)
(W/'program.log').write_text(p.stdout+p.stderr)
d={'exit_code':p.returncode,'fs_sha256':sha(fs),'flash_changed':False,'time':time.time(),'user_feedback':'pending','programmer_sha256':sha(Path(__file__))}
(W/'board.json').write_text(json.dumps(d,indent=2)+'\n');assert p.returncode==0,p.stdout+p.stderr
fd=os.open('/dev/serial/by-id/usb-SIPEED_USB_Debugger_2025030317-if01-port0',os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
t=termios.tcgetattr(fd);t[0]=t[1]=t[3]=0;t[2]=termios.CS8|termios.CLOCAL|termios.CREAD;t[4]=t[5]=termios.B115200;t[6][termios.VMIN]=t[6][termios.VTIME]=0;termios.tcsetattr(fd,termios.TCSANOW,t)
end=time.monotonic()+0.5
while time.monotonic()<end:
 if select.select([fd],[],[],0.05)[0]:os.read(fd,65536)
termios.tcflush(fd,termios.TCIFLUSH)
data=bytearray();end=time.monotonic()+12
try:
 while time.monotonic()<end:
  if select.select([fd],[],[],0.1)[0]:data.extend(os.read(fd,65536))
finally:os.close(fd)
(W/'uart.bin').write_bytes(data);rows=[]
for s in re.findall(rb'D([0-9A-F]{24})\r\n',data):
 n=int(s,16)
 def field(lo,width=1):return (n>>lo)&((1<<width)-1)
 rows.append(dict(raw=s.decode(),lock=field(0),reset_released=field(1),local_reset_released=field(2,8),por=field(10,4),fade=field(14,4),page=field(18,2),fading=field(20),visible_seen=field(21),nonzero_seen=field(22),de=field(23),h=field(24,12),v=field(36,12),frame=field(48,8),pixel_count=field(56,10),rgb=field(66,24),mode=field(90,2)))
summary={mode:{'samples':len([x for x in rows if x['mode']==mode]),'locked':all(x['lock'] for x in rows if x['mode']==mode),'resets_released':all(x['reset_released'] and x['local_reset_released']==255 for x in rows if x['mode']==mode),'visible_seen':any(x['visible_seen'] for x in rows if x['mode']==mode),'nonzero_seen':any(x['nonzero_seen'] for x in rows if x['mode']==mode),'fade_values':sorted(set(x['fade'] for x in rows if x['mode']==mode))} for mode in range(4)}
d.update(uart_bytes=len(data),telemetry_samples=len(rows),mode_summary=summary,telemetry=rows,limits='Approximate diagnostic multi-bit CDC snapshot; stable flags and repeated frames support interpretation, not a coherent production protocol.')
(W/'board.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps({k:v for k,v in d.items() if k!='telemetry'},indent=2))
assert len(rows)>100,'Missing diagnostic telemetry'
