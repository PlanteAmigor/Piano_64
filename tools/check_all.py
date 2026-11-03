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
    suffix=''.join('_'+p.split('.')[-1].replace('=','_').replace('-','m') for p in parameters)
    result_name=name+suffix
    exe=OUT/(result_name+'.vvp')
    compile_log=run(['iverilog','-g2012',*extra,*parameters,'-s',name,'-o',exe,*files])
    log=run(['vvp',exe,*args])
    if 'FAIL' in log and '0 FAIL' not in log: raise RuntimeError(log)
    (OUT/(result_name+'.log')).write_text('parameters: '+repr(parameters)+'\n'+compile_log+log)
    passes=[line for line in log.splitlines() if line.startswith('PASS') or '0 FAIL' in line]
    if not passes: raise RuntimeError('Missing PASS: '+log)
    print('\n'.join(passes),flush=True)
    return passes

def prepare_liss_reference():
    points=[(128,128),(180,130),(130,180),(128,128),(80,130),(128,80),(128,128),(128,190),
        (190,128),(128,128),(192,192),(255,0),(255,50),(240,0),(255,0),(0,255)]
    (OUT/'liss_points.hex').write_text('\n'.join(f'{x:02x}{y:02x}' for x,y in points)+'\n')
    for bits,pb in [(7,4),(8,4),(8,2)]:
        grid=[[0]*(1<<bits) for _ in range(1<<bits)];old=None
        for x,y in points:
            if bits==7:x>>=1;y>>=1
            if old is None or max(abs(x-old[0]),abs(y-old[1]))>(64 if bits==8 else 32):grid[y][x]=(1<<pb)-1
            else:
                a,b=old;dx=abs(x-a);dy=abs(y-b);err=dx-dy;sx=1 if x>=a else -1;sy=1 if y>=b else -1
                while True:
                    grid[b][a]=(1<<pb)-1
                    if (a,b)==(x,y):break
                    e2=err*2
                    if e2>-dy:err-=dy;a+=sx
                    if e2<dx:err+=dx;b+=sy
            old=x,y
        words=[]
        for row in grid:
            for col in range(0,len(row),16//pb):words.append(sum(row[col+j]<<(j*pb) for j in range(16//pb)))
        (OUT/f'liss_expected_{bits}_{pb}.hex').write_text('\n'.join(f'{w:04x}' for w in words)+'\n')

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
    results+=bench('tb_vibrato_replay',['sim/tb_vibrato_replay.v','src/optical/position_control.v'])
    results+=bench('tb_note_alloc_release',['sim/tb_note_alloc_release.v','src/note_alloc.v'])
    results+=bench('tb_song',['tb_song.v',*songs])
    for name in ['tb_song_teach','tb_song_repeat','tb_song_overlap','tb_song_multi']:
        results+=bench(name,['sim/'+name+'.v','src/song/bt_song_player.v'])
    for offset in [-151,-150,150,151]:
        results+=bench('tb_song_window',['sim/tb_song_window.v','src/song/bt_song_player.v'],
            parameters=[f'-Ptb_song_window.OFFSET={offset}'])
    results+=bench('tb_song_preview',['sim/tb_song_preview.v','src/sd/sd_async_fifo.v',*songs])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs],parameters=['-Ptb_song_sd.CORRUPT_IMAGE=1'])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs],parameters=['-Ptb_song_sd.BACKPRESSURE=1'])
    results+=bench('tb_song_sd',['sim/tb_song_sd.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v','src/ddr/ddr_ui_pipeline.v',*songs],
        parameters=['-Ptb_song_sd.BACKPRESSURE=1','-Ptb_song_sd.PIPELINE=1'])
    results+=bench('tb_soft_limiter',['sim/tb_soft_limiter.v','src/audio_soft_limiter.v'])
    results+=bench('tb_component_bars',['sim/tb_component_bars.v','src/ui_component_bars.v'])
    results+=bench('tb_sd_remaining',['sim/tb_sd_remaining.v','sim/sd_stub_songs.v','src/sd_ddr_loader.v','src/sd/sd_async_fifo.v','src/sd/uart_tx.v'])
    results+=bench('tb_sd_longname',['sim/tb_sd_longname.v','src/sd/sd_file_list_reader.v','src/sd/sd_reader.sv','src/sd/sdcmd_ctrl.sv'])
    # Run the real FAT parser, SD command engine and a read-only SDHC card model.
    run([sys.executable,ROOT/'tools/make_test_card.py'])
    results+=bench('tb_song_card',['sim/tb_song_card.v','sim/vendor/sd_fake.v','src/sd/sd_file_list_reader.v',
        'src/sd/sd_reader.sv','src/sd/sdcmd_ctrl.sv','src/sd_ddr_loader.v',
        'src/sd/sd_async_fifo.v','src/sd/uart_tx.v',*songs])
    results+=bench('tb_dma_image',['sim/tb_dma_image.v','src/suona_dma.v'])
    engine=['add_engine8','add_engine_harm','add_voice8','param_cache','param_dma','ddr_param_dma',
        'add_param_rom','add_sine_lut','mix_sum','harm_buf','suona_dma']
    results+=bench('tb_i2s_reverb',['sim/tb_i2s_reverb.v','src/pcm5102a_tx.v','src/fx/fx_reverb.v'])
    results+=bench('tb_modal_multi',['sim/tb_modal_multi.v',*['src/'+x+'.v' for x in engine]])
    results+=bench('tb_audio_controls',['sim/tb_audio_controls.v',*['src/'+x+'.v' for x in engine]])
    results+=bench('tb_guzheng_vibrato',['sim/tb_guzheng_vibrato.v',*['src/'+x+'.v' for x in engine]])
    results+=bench('tb_harm_hold',['sim/tb_harm_hold.v','src/add_engine_harm.v','src/harm_buf.v','src/add_sine_lut.v','src/suona_dma.v','src/mix_sum.v'])
    results+=bench('tb_harm_rom_compact',['sim/tb_harm_rom_compact.v','src/harm_buf.v','src/add_sine_lut.v'])
    results+=bench('tb_sine_quarter',['sim/tb_sine_quarter.v','src/add_sine_lut.v'])
    # Existing optical gesture regression returns zero even on failed assertions:
    # inspect its explicit failure count instead of trusting the process status.
    results+=bench('tb_art',['tb_art.v','src/optical/position_control.v'])
    prepare_liss_reference()
    for bits,pb in [(7,4),(8,4),(8,2)]:
        results+=bench('tb_liss_lines',['sim/tb_liss_lines.v','src/hdmi/ui/ui_liss_ram.v'],
            parameters=[f'-Ptb_liss_lines.BITS={bits}',f'-Ptb_liss_lines.PB={pb}'])
        results+=bench('tb_liss_resolution',['sim/tb_liss_resolution.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v'],
            parameters=[f'-Ptb_liss_resolution.BITS={bits}',f'-Ptb_liss_resolution.PB={pb}'])
    results+=bench('tb_scope_points',['sim/tb_scope_points.v','src/hdmi/ui/ui_scope_points.v'])
    results+=bench('tb_tmds_encode',['sim/tb_tmds_encode.v','src/hdmi/ir4/dvi_tx_tmds_enc.v'])
    results+=bench('tb_ui_timing',['sim/tb_ui_timing.v','src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v'],extra=['-DSIM_UI3'])
    if opt.ui:
        from PIL import Image
        images=[]
        for shot in range(9):
            ppm=OUT/f'ui{shot}.ppm'
            results+=bench('tb_song_ui',['sim/tb_song_ui.v','src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v'],
                extra=['-DSIM_UI3'],parameters=[f'-Ptb_song_ui.SHOT={shot}'],args=[f'+OUT={ppm}'])
            im=Image.open(ppm);assert im.size==(1920,1080);assert im.getbbox() is not None,'Blank screenshot'
            im.save(OUT/f'ui{shot}.png');images.append(im.copy())
        contact=Image.new('RGB',(1920,1080),(20,20,20))
        for i,im in enumerate(images):contact.paste(im.resize((640,360)),((i%3)*640,(i//3)*360))
        contact=contact.crop((0,0,1920,1080));contact.save(OUT/'ui_contact.png')
    (OUT/'all_results.txt').write_text('\n'.join(results)+'\n')
    (OUT/'source_sha256.txt').write_text('\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(ROOT))
        for p in sorted((ROOT/'src').rglob('*')) if p.is_file())+'\n')
    print('All requested regressions passed.',flush=True)
if __name__=='__main__':main()
