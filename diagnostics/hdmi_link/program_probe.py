#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json,os,select,subprocess,termios,time,re
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('variant',choices=['control720','cascade_old','cascade_ref','div5_ref','mode1080p30','mode900p60','mode1080p30_single','mode1080p60_single','mode1080p60_registered']);a=ap.parse_args()
w=R/'work/hdmi_link'/a.variant;m=json.loads((w/'manifest.json').read_text());assert m['exit_code']==0 and m['violations']=={'setup':0,'hold':0}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for p,h in m['inputs'].items():assert sha(w/p)==h,p
s=R/'work/hdmi_link/sim'/(a.variant+'.json');s=json.loads(s.read_text());assert s['pass'] and s['manifest_sha256']==sha(w/'manifest.json') and s['testbench_sha256']==sha(D/'tb_link.v')
fs=w/'impl/pnr/hdmi_probe.fs';assert sha(fs)==m['fs_sha256']
# Check the synthesizer's independent frequency calculation before hardware use.
# The primitive behavioral model can implement fractional settings the synthesis
# configuration does not enable, so simulation alone is insufficient.
syn=(w/'impl/gwsynthesis/hdmi_probe_syn.rpt.html').read_text();freq={}
for row in re.findall(r'<tr[^>]*>(.*?)</tr>',syn,re.S):
 cells=[re.sub(r'<[^>]+>','',x).strip() for x in re.findall(r'<td[^>]*>(.*?)</td>',row,re.S)]
 if len(cells)>=10 and cells[2]=='Generated':freq[cells[1]]=float(cells[4])
if a.variant in ['control720','mode1080p30_single']:pix,ser=75.0,375.0
elif a.variant in ['mode1080p60_single','mode1080p60_registered']:pix,ser=150.0,750.0
elif a.variant=='mode1080p30':pix,ser=74.25,371.25
elif a.variant=='mode900p60':pix,ser=97.5,487.5
else:pix,ser=148.5,742.5
pixel_leaf='divide_pixel/CLKOUT' if a.variant in ['div5_ref','mode1080p30'] else 'video/PLL_inst/CLKOUT0'
for leaf,want in [(pixel_leaf,pix),('video/PLL_inst/CLKOUT1',ser)]:
 name='clocks/'+leaf+'.default_gen_clk'
 assert abs(freq.get(name,-1)-want)<0.001,('Synthesized clock mismatch',name,freq.get(name),want)

args=['openFPGALoader','-b','tangmega138k','--ftdi-serial','2025030317','--write-sram','--quiet',str(fs)]
p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(w/'program.log').write_text(p.stdout)
d={'variant':a.variant,'fs_sha256':m['fs_sha256'],'exit_code':p.returncode,'flash_changed':False,'user_screen_acceptance':'pending','time':time.time()}
(w/'board.json').write_text(json.dumps(d,indent=2)+'\n');assert p.returncode==0,p.stdout
fd=os.open('/dev/serial/by-id/usb-SIPEED_USB_Debugger_2025030317-if01-port0',os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
t=termios.tcgetattr(fd);t[0]=t[1]=t[3]=0;t[2]=termios.CS8|termios.CLOCAL|termios.CREAD;t[4]=t[5]=termios.B115200;t[6][termios.VMIN]=t[6][termios.VTIME]=0;termios.tcsetattr(fd,termios.TCSANOW,t);termios.tcflush(fd,termios.TCIFLUSH)
# Discard any USB/UART backlog from the previous SRAM image. Keep the raw
# post-drain capture and use only its trailing windows for clock evaluation.
drain_end=time.monotonic()+0.5
while time.monotonic()<drain_end:
 if select.select([fd],[],[],0.05)[0]:os.read(fd,65536)
termios.tcflush(fd,termios.TCIFLUSH)
data=bytearray();end=time.monotonic()+3
try:
 while time.monotonic()<end:
  if select.select([fd],[],[],0.1)[0]:data.extend(os.read(fd,4096))
finally:os.close(fd)
(w/'uart.bin').write_bytes(data);text=data.decode('ascii',errors='replace');values=[{'locks':int(x,16),'reference_edges':int(y,16),'pixel_edges':int(z,16)} for x,y,z in re.findall(r'L([0-3]) ([0-9A-F]{4}) ([0-9A-F]{4})',text)]
tail=values[-10:]
clock_ok=len(tail)==10 and all(v['locks']==3 and abs(v['pixel_edges']-pix*100000/512)<3 for v in tail)
d.update(uart_bytes=len(data),observed_windows=values,uart_tail=text[-350:],fresh_clock_windows=tail,clock_count_matches=clock_ok,synthesized_pixel_mhz=pix,synthesized_serial_mhz=ser);
(w/'board.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps(d,indent=2))
