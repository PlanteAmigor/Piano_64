#!/usr/bin/env python3
"""Losslessly bank the live prefix of the original harmonic time-warp ROM."""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def main():
    original=[int(x,16) for x in (ROOT/'harm_u.hex').read_text().split()]
    assert len(original)==16384
    assert original[9155]!=0xffffffff and set(original[9156:])=={0xffffffff}
    banks=[original[:8192],original[8192:9156]+[0xffffffff]*(1024-964)]
    for name,values in zip(['head','tail'],banks):
        (ROOT/f'harm_u_{name}.hex').write_text(''.join(f'{v:08X}\n' for v in values))
    rebuilt=[banks[0][i] if i<8192 else banks[1][i-8192] if i<9156 else 0xffffffff for i in range(16384)]
    assert rebuilt==original
    print('PASS compact harmonic ROM: all 16384 original words exact; 8192+1024 stored words')

if __name__=='__main__':main()
