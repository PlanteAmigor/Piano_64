#!/usr/bin/env python3
"""Compact the existing paired sine ROM without changing any table value."""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def main():
    original=[int(x,16) for x in (ROOT/'add_sine.hex').read_text().split()]
    assert len(original)==1024
    quarter=original[:256]
    reconstructed=[]
    for i in range(1024):
        mirrored=bool(i&256);negative=bool(i&512)
        word=quarter[(~i if mirrored else i)&255]
        lo,hi=word&65535,word>>16
        if mirrored:lo,hi=hi,lo
        if negative:lo,hi=(-lo)&65535,(-hi)&65535
        reconstructed.append(lo|(hi<<16))
    assert reconstructed==original
    (ROOT/'add_sine_quarter.hex').write_text(''.join(f'{v:08X}\n' for v in quarter))
    print('PASS quarter sine ROM: all 1024 original paired words exact; 256 stored pairs')

if __name__=='__main__':main()
