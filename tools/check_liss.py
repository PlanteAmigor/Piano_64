#!/usr/bin/env python3
"""Compare real Lissajous RTL using modal signals derived from P64.BIN.
Requires NumPy, Pillow, Icarus Verilog and baseline commit 5ec3098.
The image is a scope simulation, not a hardware photograph.
"""
from pathlib import Path
import subprocess,struct,numpy as np,json
from concurrent.futures import ThreadPoolExecutor
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parents[1];out=root/'work/liss_check';out.mkdir(exist_ok=True)
old=out/'hdmi_old.v';old.write_bytes(subprocess.check_output(['git','show','5ec3098:src/hdmi/hdmi_ui3_top.v'],cwd=root))
image=root.parent/'P64.BIN'
if not image.exists():image=root/'P64.BIN'
b=image.read_bytes()
for inst,lo,base,note in [(0,21,1,60),(1,38,5633,62)]:
 off=(base+(note-lo)*64)*32
 p=np.array([struct.unpack_from('<4I',b,off+k*16) for k in range(128)],dtype=np.uint64)
 t=np.arange(16384);phase=t[:,None]*p[:,0]/2**32+((p[:,2]>>8)&255)/256
 a=(p[:,2]>>16).astype(float)
 env=(1-p[:,1].astype(float)/2**32)[None,:]**t[:,None]
 y=(env*a[None,:]*np.sin(2*np.pi*phase)).sum(axis=1)
 y=np.clip(np.round(y/max(abs(y))*20000),-32768,32767).astype(np.int16)
 inp=out/f'audio{inst}.hex';inp.write_text(''.join(f'{int(x)&65535:04x}\n' for x in y))
def render(pair):
 inst,before=pair
 exe=out/f'liss{inst}_{before}.vvp';dump=out/f'liss{inst}_{before}.hex'
 source=old if before else root/'src/hdmi/hdmi_ui3_top.v'
 subprocess.run(['iverilog','-g2012','-DSIM_UI3','-s','tb_liss_view',f'-Ptb_liss_view.INST={inst}',f'-Ptb_liss_view.BEFORE={before}','-o',str(exe),'sim/tb_liss_view.v',str(source),'src/hdmi/ui/ui_liss_ram.v'],check=True,cwd=root)
 r=subprocess.run(['vvp',str(exe),f'+IN={out/f"audio{inst}.hex"}',f'+OUT={dump}'],check=False,text=True,capture_output=True)
 (out/f'liss{inst}_{before}.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,flush=True);r.check_returncode()
with ThreadPoolExecutor(max_workers=2) as pool:
 list(pool.map(render,[(i,b) for i in range(2) for b in range(2)]))
canvas=Image.new('RGB',(560,610),(18,22,28));d=ImageDraw.Draw(canvas)
report={}
for inst in range(2):
 for before in range(2):
  words=[int(x,16) for x in (out/f'liss{inst}_{before}.hex').read_text().split()]
  v=np.array([(w>>(4*j))&15 for w in words for j in range(4)],dtype=np.uint8).reshape(128,128)
  rgb=np.stack([v*17,v*8,v*2],axis=-1);im=Image.fromarray(rgb).resize((256,256),Image.Resampling.NEAREST)
  x=(0 if before else 280);y=inst*305+35
  canvas.paste(im,(x,y));d.text((x+5,y-25),f'{"Piano" if inst==0 else "Guzheng"} / {"Before" if before else "After"}',fill='white')
  report[f'{inst}_{before}']={'lit_pixels':int((v>0).sum()),'bright_pixels':int((v>=8).sum())}
canvas.save(out/'liss_before_after.png');(out/'metrics.json').write_text(json.dumps(report,indent=2))
print(report)
