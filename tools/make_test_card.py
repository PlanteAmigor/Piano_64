#!/usr/bin/env python3
"""Small deterministic FAT32 disk for the real SD CMD/DAT model regression.
The P64 fixture spans deliberately fragmented clusters. This is test data,
not an SD card image for hardware or a replacement for the real P64.BIN.
"""
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/song_checks'

def main():
    disk=bytearray(65536)
    # MBR -> partition DBR at sector 1 -> one FAT at sector 2 -> data at 3.
    disk[0x1be+4]=0x0c
    struct.pack_into('<II',disk,0x1be+8,1,127);disk[510:512]=b'\x55\xaa'
    d=512;disk[d]=0xeb
    struct.pack_into('<H',disk,d+11,512);disk[d+13]=1
    struct.pack_into('<H',disk,d+14,1);disk[d+16]=1
    struct.pack_into('<I',disk,d+32,127);struct.pack_into('<I',disk,d+36,1)
    struct.pack_into('<I',disk,d+44,2);disk[d+82:d+90]=b'FAT32   ';disk[d+510:d+512]=b'\x55\xaa'
    def fat(cluster,value):struct.pack_into('<I',disk,1024+cluster*4,value)
    fat(0,0x0ffffff8);fat(1,0x0fffffff);fat(2,0x0fffffff)
    files=[('P64.BIN',(OUT/'P64.BIN').read_bytes()),
        ('SONG04.BIN',(ROOT/'tools/generated/SONG04.BIN').read_bytes()),
        ('OTHER0.TXT',b'ignored'),('SONG01.BIN',(ROOT/'tools/generated/SONG01.BIN').read_bytes()),
        ('SONG02.BIN',(ROOT/'tools/generated/SONG02.BIN').read_bytes()),
        ('SONG03.BIN',(ROOT/'tools/generated/SONG03.BIN').read_bytes())]
    cluster=3;starts={}
    for i,(name,data) in enumerate(files):
        count=(len(data)+511)//512;chain=[cluster+2*j for j in range(count)]
        starts[name]=(3+chain[0]-2)*512
        stem,ext=name.split('.')
        entry=1536+i*32
        disk[entry:entry+11]=(stem.ljust(8)+ext.ljust(3)).encode('ascii');disk[entry+11]=0x20
        struct.pack_into('<H',disk,entry+26,chain[0]);struct.pack_into('<I',disk,entry+28,len(data))
        for j,c in enumerate(chain):
            fat(c,chain[j+1] if j+1<len(chain) else 0x0fffffff)
            start=(3+c-2)*512;chunk=data[j*512:(j+1)*512];disk[start:start+len(chunk)]=chunk
        cluster=chain[-1]+2
    (OUT/'card.hex').write_text('\n'.join(f'{w[0]:04x}' for w in struct.iter_unpack('<H',disk))+'\n')
    (OUT/'disk_meta.vh').write_text(f"localparam [39:0] SONG02_BAD_WORD=40'd{(starts['SONG02.BIN']+15)//2};\n")
if __name__=='__main__':main()
