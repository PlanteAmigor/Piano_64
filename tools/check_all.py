#!/usr/bin/env python3
"""Focused regressions for song playback and the changed audio controls.
Run from anywhere: python3 tools/check_all.py [--ui]. Requires Icarus Verilog;
--ui additionally uses Pillow and captures the actual HDMI pixel pipeline.
No FPGA, mounted SD card, or vendor simulator is needed.
"""
from pathlib import Path
import argparse
import hashlib
import struct
import subprocess
import sys
import random

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/song_checks'

def run(args):
    p=subprocess.run([str(a) for a in args],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if p.returncode:
        print(p.stdout);raise SystemExit(p.returncode)
    return p.stdout

def bench(name,files,extra=(),parameters=(),args=()):
    exe=OUT/(name+'.vvp')
    compile_log=run(['iverilog','-g2012',*extra,*parameters,'-s',name,'-o',exe,*files])
    log=run(['vvp',exe,*args])
    if 'FAIL' in log and '0 FAIL' not in log: raise RuntimeError(log)
    (OUT/(name+'.log')).write_text(compile_log+log)
    passes=[line for line in log.splitlines() if line.startswith('PASS') or '0 FAIL' in line]
    if not passes: raise RuntimeError('Missing PASS: '+log)
    print('\n'.join(passes),flush=True)
    return passes

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--ui',action='store_true');opt=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    # Tiny checksum-valid instrument image is for the SD file-service model only.
    payload=random.Random(64).randbytes(32*63)
    checksum=sum(struct.unpack('<504I',payload))&0xffffffff
    (OUT/'P64.BIN').write_bytes(struct.pack('<4s7I',b'P64I',2,64,checksum,1,21,1,38)+payload)
    image=ROOT.parent/'P64.BIN'
    if not image.exists():image=ROOT/'P64.BIN'
    data=image.read_bytes()
    assert len(data)==1127968,'Use current 4-instrument P64.BIN for all 53 DMA notes'
    (OUT/'image_bytes.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
    output=run([sys.executable,ROOT/'tools/check_song.py']);print(output,end='',flush=True)
    results=output.splitlines()
    songs=[str(p.relative_to(ROOT)) for p in (ROOT/'src/song').glob('*.v')]
    results+=bench('tb_song_keys',['sim/tb_song_keys.v','src/key_scan.v','src/sd/sd_async_fifo.v',*songs])
    results+=bench('tb_key_scan_bounce',['sim/tb_key_scan_bounce.v','src/key_scan.v'])
    results+=bench('tb_note_alloc_release',['sim/tb_note_alloc_release.v','src/note_alloc.v'])
    results+=bench('tb_song',['tb_song.v',*songs])
    for name in ['tb_song_teach','tb_song_repeat','tb_song_overlap']:
        results+=bench(name,['sim/'+name+'.v','src/song/bt_song_player.v'])
    for offset in [-151,-150,150,151]:
        results+=bench('tb_song_window',['sim/tb_song_window.v','src/song/bt_song_player.v'],
            parameters=[f'-Ptb_song_window.OFFSET={offset}'])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs],parameters=['-Ptb_song_sd.CORRUPT_IMAGE=1'])
    # Run the real FAT parser, SD command engine and a read-only SDHC card model.
    run([sys.executable,ROOT/'tools/make_test_card.py'])
    results+=bench('tb_song_card',['sim/tb_song_card.v','sim/vendor/sd_fake.v','src/sd/sd_file_list_reader.v',
        'src/sd/sd_reader.sv','src/sd/sdcmd_ctrl.sv','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs])
    results+=bench('tb_dma_image',['sim/tb_dma_image.v','src/suona_dma.v'])
    engine=['add_engine8','add_engine_harm','add_voice8','param_cache','param_dma','ddr_param_dma',
        'add_param_rom','add_sine_lut','mix_sum','harm_buf','suona_dma']
    results+=bench('tb_audio_controls',['sim/tb_audio_controls.v',*['src/'+x+'.v' for x in engine]])
    # Existing optical gesture regression returns zero even on failed assertions:
    # inspect its explicit failure count instead of trusting the process status.
    results+=bench('tb_art',['tb_art.v','src/optical/position_control.v'])
    if opt.ui:
        from PIL import Image
        images=[]
        for shot in range(5):
            ppm=OUT/f'ui{shot}.ppm'
            results+=bench('tb_song_ui',['sim/tb_song_ui.v','src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v'],
                extra=['-DSIM_UI3'],parameters=[f'-Ptb_song_ui.SHOT={shot}'],args=[f'+OUT={ppm}'])
            im=Image.open(ppm);assert im.getbbox() is not None,'Blank screenshot'
            im.save(OUT/f'ui{shot}.png');images.append(im.copy())
        contact=Image.new('RGB',(1280,720*3),(20,20,20))
        for i,im in enumerate(images):contact.paste(im.resize((640,360)),((i%2)*640,(i//2)*360))
        contact=contact.crop((0,0,1280,1080));contact.save(OUT/'ui_contact.png')
    (OUT/'all_results.txt').write_text('\n'.join(results)+'\n')
    (OUT/'source_sha256.txt').write_text('\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(ROOT))
        for p in sorted((ROOT/'src').rglob('*')) if p.is_file())+'\n')
    print('All requested regressions passed.',flush=True)
if __name__=='__main__':main()
