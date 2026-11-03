#!/usr/bin/env python3
"""TMDS transition-minimized byte and signed ones-minus-zeros balance."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
words=[]
for data in range(256):
    flip=data.bit_count()>4 or (data.bit_count()==4 and not data&1)
    qm=data&1
    for bit in range(1,8):
        qm|=(((qm>>(bit-1))^(data>>bit)^flip)&1)<<bit
    balance=2*qm.bit_count()-8
    direct=balance//2-(not (not flip))
    inverse=-balance//2+(not flip)
    packed=((balance==0)<<17)|((direct&15)<<13)|((inverse&15)<<9)|((not flip)<<8)|qm
    words.append(f'{packed:018b}')
(root/'src/hdmi/ir4/tmds_encode.mem').write_text('\n'.join(words)+'\n')
