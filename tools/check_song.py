#!/usr/bin/env python3
"""Reproducible v3 transport regression: CRC, counts, RAM boundaries, recovery.
Run from the project root. Artifacts are written to work/song_checks/.
"""
from pathlib import Path
import importlib.util
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/song_checks'

def run(argv):
    p=subprocess.run(argv,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True)
    return p.stdout

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('gen',ROOT/'tools/gen_song_v3.py')
    g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
    def stream(events,declared=None,timbre=0):
        n=len(events) if declared is None else declared
        duration=max(t+d for t,_,d,_ in events)+1 if events else 100
        frames=[g.make_frame(1,struct.pack('<HIBB',n,duration,timbre,0),0)]
        for off in range(0,len(events),32):
            payload=struct.pack('<H',off)+b''.join(struct.pack('<IBHB',*e) for e in events[off:off+32])
            frames.append(g.make_frame(2,payload,len(frames)))
        frames.append(g.make_frame(3,struct.pack('<H',n),len(frames)))
        return frames
    small=[(0,36,100,72),(0,48,100,86),(0,60,100,100),(0,64,100,78)]
    maximum=[(i*2,60,1,80) for i in range(2048)]
    good=stream(small)
    bad_crc=bytearray(good[1]);bad_crc[-1]^=1
    cases=[('valid_chord',b''.join(good),small,4,0),
        ('full_capacity',b''.join(stream(maximum)),maximum,4,0),
        ('missing_data',good[0]+good[-1],None,4,0),
        ('bad_crc',good[0]+bad_crc+good[-1],None,4,0),
        ('overdeclared',b''.join(stream(small,3)),None,4,0),
        ('capacity_plus_one',b''.join(stream(maximum+[(4096,60,1,80)])),None,4,0),
        ('bad_sort',b''.join(stream([(100,60,10,80),(0,61,10,80)])),None,4,0),
        ('zero_duration',b''.join(stream([(0,60,0,80)])),None,4,0),
        ('polyphony_limit',b''.join(stream([(0,60+i,100,80) for i in range(9)])),None,4,0),
        ('fifo_overflow',b''.join(stream(maximum)),None,1,0),
        ('transport_error',b''.join(good),None,4,1)]
    exe=OUT/'transport.vvp'
    run(['iverilog','-g2012','-s','tb_song_transport','-o',str(exe), 'sim/tb_song_transport.v',
        *[str(p.relative_to(ROOT)) for p in (ROOT/'src/song').glob('*.v')]])
    log=[]
    for name,data,expected,gap,byte_error in cases:
        src=OUT/(name+'.bin');src.write_bytes(data); dump=OUT/(name+'.hex')
        text=run(['vvp',str(exe),f'+FILE={src}',f'+DUMP={dump}',f'+GAP={gap}',
            f'+VALID={int(expected is not None)}',f'+COUNT={len(expected or [])}',f'+BYTE_ERROR={byte_error}'])
        if expected is not None:
            actual=[int(v,16) for v in dump.read_text().splitlines() if v and not v.startswith('//')]
            want=[int.from_bytes(struct.pack('<IBHB',*e),'little') for e in expected]
            assert actual==want, name
        line=name+': '+next(l for l in text.splitlines() if l.startswith('PASS'))
        print(line);log.append(line)
    # Each generated song must round-trip every event through the HDL RAM.
    for src in sorted((ROOT/'tools/generated').glob('SONG*.BIN')):
        b=src.read_bytes();at=0;expected=[]
        while at<len(b):
            length=int.from_bytes(b[at+5:at+7],'little');frame=b[at:at+9+length]
            assert g.crc16(frame[:-2])==int.from_bytes(frame[-2:],'little')
            if frame[3]==2:expected.extend(struct.iter_unpack('<IBHB',frame[9:-2]))
            at+=len(frame)
        dump=OUT/(src.stem+'.hex')
        text=run(['vvp',str(exe),f'+FILE={src}',f'+DUMP={dump}',f'+COUNT={len(expected)}'])
        actual=[int(v,16) for v in dump.read_text().splitlines() if v and not v.startswith('//')]
        assert actual==[int.from_bytes(struct.pack('<IBHB',*e),'little') for e in expected]
        line=src.name+': all '+str(len(expected))+' events match'
        print(line);log.append(line)
    (OUT/'results.txt').write_text('\n'.join(log)+'\n')
if __name__=='__main__':main()
