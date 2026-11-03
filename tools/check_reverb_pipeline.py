#!/usr/bin/env python3
"""Check every reverb sample against a modulo-address fixed-point oracle."""
from pathlib import Path
import random,subprocess,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
def clamp(v):return max(-32768,min(32767,v))
def s16(v):return ((v+32768)&65535)-32768
def main():
    out=ROOT/'work/reverb_pipeline';out.mkdir(parents=True,exist_ok=True)
    delays=[1236,1315,1414,1502,1574,1651,1724,1790]
    aps=[616,488,378,249]
    comb=[[0]*(d+1) for d in delays];left=[[0]*(d+1) for d in aps];right=[[0]*(d+1) for d in aps]
    cp=[0]*8;ap=[0]*4;damp=[0]*8;rng=random.Random(1080);rows=[];saturated=0
    for n in range(120000):
        l,r=(32767,32767) if n<30000 else (-32768,-32768) if n<60000 else (rng.randrange(-32768,32768),rng.randrange(-32768,32768)) if n<70000 else (0,0)
        enabled=(n//997)%5!=3;wetl=wetr=0;mono=(l+r)>>7
        for k,buf in enumerate(comb):
            ql=buf[(cp[k]+1)%len(buf)];qr=buf[(cp[k]+24)%len(buf)]
            damp[k]=(ql+damp[k])>>1;buf[cp[k]]=s16(mono+((damp[k]*225)>>8))
            cp[k]=(cp[k]+1)%len(buf);wetl+=ql;wetr+=qr
        saturated+=int(abs(wetl)>32767 or abs(wetr)>32767)
        wetl=clamp(wetl);wetr=clamp(wetr)
        for k in range(4):
            j=(ap[k]+1)%len(left[k]);ql=left[k][j];qr=right[k][j]
            saturated+=int(abs(wetl+(ql>>1))>32767 or abs(wetr+(qr>>1))>32767)
            left[k][ap[k]]=clamp(wetl+(ql>>1));right[k][ap[k]]=clamp(wetr+(qr>>1))
            wetl=clamp(ql-(wetl>>1));wetr=clamp(qr-(wetr>>1));ap[k]=j
        ol=clamp((l*128+wetl*140)>>8) if enabled else l
        or_=clamp((r*128+wetr*140)>>8) if enabled else r
        word=(int(enabled)<<64)|((l&65535)<<48)|((r&65535)<<32)|((ol&65535)<<16)|(or_&65535)
        rows.append(f'{word:017x}')
    assert saturated>1000,'Stimulus must exercise saturation'
    (out/'samples.hex').write_text('\n'.join(rows)+'\n')
    exe=out/'check.vvp'
    subprocess.run(['iverilog','-g2012','-s','tb_reverb_pipeline','-o',str(exe),'sim/tb_reverb_pipeline.v','src/fx/fx_reverb.v'],cwd=ROOT,check=True)
    p=subprocess.run(['vvp',str(exe)],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/'results.log').write_text(p.stdout)
    assert p.returncode==0 and 'PASS' in p.stdout,p.stdout
    files=['src/fx/fx_reverb.v','sim/tb_reverb_pipeline.v','tools/check_reverb_pipeline.py']
    (out/'sources.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in files},indent=2)+'\n')
    print(p.stdout,end='');print('Oracle saturation samples:',saturated)
if __name__=='__main__':main()
