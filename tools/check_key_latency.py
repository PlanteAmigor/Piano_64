#!/usr/bin/env python3
"""Measure actual add_top at 50/100MHz, real P64, actual I2S pin receiver."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,os,tempfile
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/key_latency'
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--timbre',type=int,choices=range(4));ap.add_argument('--effect',type=int,default=0);ap.add_argument('--ddr-delay',type=int,default=64);a=ap.parse_args()
    OUT.mkdir(exist_ok=True,parents=True)
    image=ROOT.parent/'P64.BIN'
    if not image.exists():image=ROOT/'P64.BIN'
    data=image.read_bytes()
    assert len(data)==1127968,'Use current four-instrument P64.BIN'
    wanted=''.join(f'{b:02x}\n' for b in data).encode()
    image_hex=ROOT/'work/song_checks/image_bytes.hex'
    image_hex.parent.mkdir(exist_ok=True,parents=True)
    if not image_hex.exists() or image_hex.read_bytes()!=wanted:
        with tempfile.NamedTemporaryFile(dir=image_hex.parent,delete=False) as f:
            f.write(wanted);temp_name=f.name
        os.replace(temp_name,image_hex)

    files=[]
    for line in (ROOT/'build_full.tcl').read_text().splitlines():
        if line.startswith('add_file '):
            p=line.split()[1]
            if p.endswith(('.v','.sv')) and not p.startswith(('src/hdmi/','src/gowin_pll/')) and p not in ['src/piano64_top.v','src/ddr/ddr_wrap.v','src/ddr/ddr3_memory_interface.v','src/ddr/gowin_pll.v','src/ddr/gowin_pll_mod.v','src/ddr/pll_init.v']:
                files.append(p)
    files+=['sim/tb_key_latency.v','sim/key_latency_ddr.v']
    timbres=range(4) if a.timbre is None else [a.timbre]
    for t in timbres:
        name=f'latency_t{t}_fx{a.effect}_ddr{a.ddr_delay}'
        exe=OUT/(name+'.vvp')
        p=subprocess.run(['iverilog','-g2012','-DSIM_PLL','-DSIM_INIT','-s','tb_key_latency',f'-Ptb_key_latency.TIMBRE={t}',f'-Ptb_key_latency.EFFECT={a.effect}','-o',str(exe),*files],cwd=ROOT,capture_output=True,text=True)
        (OUT/(name+'.compile.log')).write_text(p.stdout+p.stderr)
        if p.returncode:raise RuntimeError(p.stdout+p.stderr)
        with (OUT/(name+'.log')).open('w') as log:
            p=subprocess.run(['vvp',str(exe),f'+DDR_DELAY={a.ddr_delay}'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        result=(OUT/(name+'.log')).read_text();print(result,flush=True)
        if p.returncode or 'PASS full key latency' not in result:raise RuntimeError('Latency verification failed: '+name)
        measures=[dict(timbre=t,effect=a.effect,ddr_response_cycles=a.ddr_delay,phase=int(x),pcm_us=float(y),dac_us=float(z)) for x,y,z in re.findall(r'phase=(\d+).*?pcm_us=([\d.]+) dac_us=([\d.]+)',result)]
        assert len(measures)==(4 if t<2 else 3)
        record={'simulation_defines':['SIM_PLL','SIM_INIT'],'measurements':measures,'sources':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},'image_sha256':hashlib.sha256((ROOT/'work/song_checks/image_bytes.hex').read_bytes()).hexdigest(),'note':'Digital simulation, preloaded image, valid stationary optical hand; analog DAC/speaker delay and unbounded mechanical bounce require physical measurement.'}
        (OUT/(name+'.json')).write_text(json.dumps(record,indent=2)+'\n')
if __name__=='__main__':main()
