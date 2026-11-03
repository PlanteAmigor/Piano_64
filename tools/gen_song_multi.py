#!/usr/bin/env python3
"""Multi-instrument v3 extension, BEGIN.flags bit7. Legacy files unchanged.
Events: (start_ms, MIDI_note, duration_ms, velocity, timbre0..3, lead_bool).
Modal capacity7, shared wind capacity1; overlaps are rejected at generation.
"""
import argparse
import struct
from pathlib import Path
from gen_song_v3 import make_frame, TIMBRES, nn

def encode(events, default_timbre=3):
    events=sorted(events,key=lambda e:(e[0],not e[5],e[1]))
    if not 0<len(events)<=2048:raise ValueError('event count must be 1..2048')
    ends=[0]*8
    encoded=[]
    for start,note,dur,vel,timbre,lead in events:
        _,lo,hi,_=TIMBRES[timbre]
        if not (0<=start<86400000 and lo<=note<=hi and 1<=dur<=32767 and 1<=vel<=127):
            raise ValueError(f'invalid event {start,note,dur,vel,timbre,lead}')
        slots=range(7) if timbre<2 else [7]
        free=next((i for i in slots if ends[i]<=start),None)
        if free is None:raise ValueError('capacity exceeded: seven modal voices and one shared wind voice')
        ends[free]=start+dur
        encoded.append((start,note|((timbre>>1)<<7),dur|((not lead)<<15),vel|((timbre&1)<<7)))
    duration=max(e[0]+e[2] for e in events)
    out=bytearray(make_frame(1,struct.pack('<HIBB',len(events),duration,default_timbre,0x80),0))
    for off in range(0,len(encoded),32):
        payload=struct.pack('<H',off)+b''.join(struct.pack('<IBHB',*e) for e in encoded[off:off+32])
        out+=make_frame(2,payload,off//32+1)
    out+=make_frame(3,struct.pack('<H',len(events)),255)
    return bytes(out),events

def demo():
    melody=['C5','C5','G5','G5','A5','A5','G5','F5','F5','E5','E5','D5','D5','C5']
    events=[]
    # Four phrases demonstrate automatic flute -> guzheng -> suona -> piano.
    for section,instrument in enumerate([3,1,2,0]):
        base=section*8400
        for i,n in enumerate(melody):events.append((base+i*600,nn(n),540,100,instrument,True))
        for bar in range(7):
            t=base+bar*1200
            for n in ['C3','G3']:events.append((t,nn(n),1120,58,0,False))
            events.append((t+600,nn('E4'),500,58,1,False))
    return events

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=Path(__file__).parent/'generated');args=ap.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    blob,events=encode(demo());(args.out/'SONG05.BIN').write_bytes(blob)
    print(f'SONG05.BIN: {len(events)} events, 4 instruments, lead + automatic accompaniment, {len(blob)} bytes')
if __name__=='__main__':main()
