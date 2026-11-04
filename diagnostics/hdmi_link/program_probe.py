#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json,os,select,subprocess,termios,time,re
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('variant',choices=['control720','cascade_old','cascade_ref','div5_ref']);a=ap.parse_args()
w=R/'work/hdmi_link'/a.variant;m=json.loads((w/'manifest.json').read_text());assert m['exit_code']==0 and m['violations']=={'setup':0,'hold':0}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for p,h in m['inputs'].items():assert sha(w/p)==h,p
s=R/'work/hdmi_link/sim'/(a.variant+'.json');s=json.loads(s.read_text());assert s['pass'] and s['manifest_sha256']==sha(w/'manifest.json') and s['testbench_sha256']==sha(D/'tb_link.v')
fs=w/'impl/pnr/hdmi_probe.fs';assert sha(fs)==m['fs_sha256']
args=['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-sram','--quiet',str(fs)]
p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(w/'program.log').write_text(p.stdout)
d={'variant':a.variant,'fs_sha256':m['fs_sha256'],'exit_code':p.returncode,'flash_changed':False,'user_screen_acceptance':'pending','time':time.time()}
(w/'board.json').write_text(json.dumps(d,indent=2)+'\n');assert p.returncode==0,p.stdout
fd=os.open('/dev/serial/by-id/usb-SIPEED_USB_Debugger_2025030317-if01-port0',os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
t=termios.tcgetattr(fd);t[0]=t[1]=t[3]=0;t[2]=termios.CS8|termios.CLOCAL|termios.CREAD;t[4]=t[5]=termios.B115200;t[6][termios.VMIN]=t[6][termios.VTIME]=0;termios.tcsetattr(fd,termios.TCSANOW,t);termios.tcflush(fd,termios.TCIFLUSH)
data=bytearray();end=time.monotonic()+3
try:
 while time.monotonic()<end:
  if select.select([fd],[],[],0.1)[0]:data.extend(os.read(fd,4096))
finally:os.close(fd)
(w/'uart.bin').write_bytes(data);text=data.decode('ascii',errors='replace');values=[{'locks':int(x,16),'reference_edges':int(y,16),'pixel_edges':int(z,16)} for x,y,z in re.findall(r'L([0-3]) ([0-9A-F]{4}) ([0-9A-F]{4})',text)]
d.update(uart_bytes=len(data),observed_windows=values,uart_tail=text[-350:]);(w/'board.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps(d,indent=2))
