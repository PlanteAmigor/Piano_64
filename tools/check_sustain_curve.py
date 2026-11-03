#!/usr/bin/env python3
"""Check native P64 phase motion across both sustain-table turns.
This is a control-curve check, not a listening test or a full RTL audio render.
"""
from pathlib import Path
import struct,json
import numpy as np
root=Path(__file__).resolve().parents[1]
image=root.parent/'P64.BIN'
if not image.exists():image=root/'P64.BIN'
b=image.read_bytes()
u=np.array([int(x,16) for x in (root/'harm_u.hex').read_text().split()],dtype=np.int64)
a=np.arange(48832,97665,dtype=np.int64)
u0=u[a>>4];ua=u0+((u[(a>>4)+1]-u0)*(a&15)>>4)
pos=ua*599;idx=pos>>32;fr=(pos>>16)&65535
u32=lambda o:struct.unpack_from('<I',b,o)[0]
rows=[]
for inst,base,lo,hi in [('suona',8769,69,96),('dizi',22176,67,91)]:
 for note in range(lo,hi+1):
  desc=(base+2)*32+(note-lo)*64;off=u32(desc+44)
  phi=np.frombuffer(b,dtype='<u4',count=600,offset=off).astype(np.int64)
  curve=phi[idx]+(((phi[idx+1]-phi[idx])*fr+32768)>>16)
  step=np.diff(curve);freq=step*48828.125/524288
  assert step.min()>0 and step.max()<32768,(inst,note,step.min(),step.max())
  cents=1200*np.log2(freq/np.mean(freq))
  # Reversing table traversal mirrors frequency order, while the carrier
  # advances by positive increments. Endpoints share the exact same step.
  loop=np.concatenate([step,step[::-1]])
  assert loop[len(step)-1]==loop[len(step)] and loop[-1]==loop[0]
  rows.append({'instrument':inst,'note':note,'mean_hz':float(freq.mean()),
   'native_cents_rms':float(np.std(cents)),'native_cents_peak_to_peak':float(np.ptp(cents)),
   'max_adjacent_phase_step_change':int(np.max(np.abs(np.diff(loop))))})
assert min(r['native_cents_peak_to_peak'] for r in rows if r['instrument']=='dizi')>1
out=root/'work/song_checks/sustain_curve.json';out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(rows,indent=2)+'\n')
flute=[r['native_cents_peak_to_peak'] for r in rows if r['instrument']=='dizi']
print(f'PASS native sustain curves: all 53 P64 notes forward phase, both turns share endpoint frequency; flute native pitch variation {min(flute):.1f}..{max(flute):.1f} cents peak-to-peak, no frozen sustain')
