#!/usr/bin/env python3
"""Publish a byte-matched RAR5 snapshot of the user-accepted 1080p30 build.

Run in the validated worktree after committing delivery source/docs. Does not
program hardware, move branches, or upload. Source-only local comment changes
remain uncommitted and are documented in the archive's build input patch.
"""
from pathlib import Path
import hashlib,json,shutil,subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=Path('/home/amigor/Documents/Codex/2026-11-03/n/outputs')
W=ROOT/'work/hdmi_production30'
NAME='piano64_3_1080p30_完整已验收_20261104'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def cp(a,b):b.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a,b)
def read(p):return json.loads(p.read_text())
def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT)
def run(args,cwd,log):
 with log.open('w') as f:subprocess.run(args,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,check=True)

def main():
 subprocess.run(['python3','tools/check_build.py'],cwd=ROOT,check=True)
 m=read(W/'offline_verified/piano64_full.manifest.json')
 assert m==read(ROOT/'impl/pnr/piano64_full.manifest.json')
 assert m['video_mode']=='1080p30.303' and m['violations']=={'setup':0,'hold':0}
 for p,h in m['inputs'].items():assert sha(ROOT/p)==h,p
 for p,h in m['bitstreams'].items():assert sha(W/'offline_verified'/p)==h,p
 a=read(W/'acceptance.json');b=read(W/'board.json')
 assert a['status']=='user_accepted_sram' and b['exit_code']==0
 assert a['fs_sha256']==b['fs_sha256']==m['bitstreams']['piano64_full.fs']
 assert a['load_record_sha256']==sha(W/'board.json')
 assert a['verification_sha256']==sha(W/'verification.json')
 assert all(x['exit_code']==0 for x in read(W/'results.json'))
 assert 'All requested regressions passed.' in (W/'regression.log').read_text()
 for line in (ROOT/'work/song_checks/source_sha256.txt').read_text().splitlines():
  h,p=line.split('  ',1);assert sha(ROOT/p)==h,p
 aux=read(W/'auxiliary_verified.json')
 assert all(x['exit_code']==0 for x in aux['vendor_and_natural_boot']['checks'])
 for p,h in aux['vendor_and_natural_boot']['sources'].items():assert sha(ROOT/p)==h,p
 for p,h in read(W/'screens/sources.json').items():assert sha(ROOT/p)==h,p
 assert len(read(W/'screens_compare.json'))==13 and all(x['identical'] for x in read(W/'screens_compare.json'))
 lat=[]
 for row in aux['latency']['records']:
  p=ROOT/row['result'];assert sha(p)==row['sha256'];d=read(p)
  for p,h in d['sources'].items():assert sha(ROOT/p)==h,p
  lat.append((ROOT/row['result'],d))
 assert sum(len(d['measurements']) for _,d in lat)==18
 status=[x for x in git('status','--porcelain=v1','-z').split(b'\0') if x]
 assert status==[b' M src/add_engine_harm.v'] or not status,status
 commit=git('rev-parse','HEAD').decode().strip()
 OUT.mkdir(parents=True,exist_ok=True)
 archive=OUT/(NAME+'.rar');assert not archive.exists(),archive
 stage=ROOT/'work/release1080p30'/NAME;assert not stage.exists(),stage
 repo=stage/'piano64_3';repo.mkdir(parents=True)
 files=[x.decode() for x in git('ls-files','-z').split(b'\0') if x]
 files=[x for x in files if not x.startswith('releases/')]
 for p in files:cp(ROOT/p,repo/p)
 for p,h in m['inputs'].items():cp(ROOT/p,repo/p);assert sha(repo/p)==h,p
 common=Path(git('rev-parse','--git-common-dir').decode().strip())
 if not common.is_absolute():common=(ROOT/common).resolve()
 image=common.parent.parent/'P64.BIN';assert image.is_file(),image
 cp(image,repo/'P64.BIN');cp(image,stage/'SD/P64.BIN')
 songs=sorted((ROOT/'tools/generated').glob('SONG*.BIN'));assert len(songs)>=5
 for p in songs:cp(p,stage/'SD'/p.name)
 for p in (W/'offline_verified').iterdir():
  if p.is_file():cp(p,repo/'impl/pnr'/p.name)
 (repo/'work').mkdir(exist_ok=True)
 (repo/'work/build_inputs.json').write_text(json.dumps(m['inputs'],indent=2)+'\n')
 evidence=stage/'验证记录';evidence.mkdir()
 for p in ['results.json','auxiliary_verified.json','screens_compare.json','verification.json','board.json','acceptance.json','regression.log','build.log','video_sources.json','vendor.log','production_link.log','boot.log','screens_retry.log']:
  cp(W/p,evidence/p)
 for p in ['all_results.txt','source_sha256.txt']:cp(ROOT/'work/song_checks'/p,evidence/p)
 first_bench=(ROOT/'work/song_checks/tb_song_keys.log').stat().st_mtime
 for p in sorted((ROOT/'work/song_checks').glob('*.log')):
  if p.stat().st_mtime>=first_bench:cp(p,evidence/'功能仿真'/p.name)
 for p,_ in lat:cp(p,evidence/'既有18场景延迟'/p.name)
 for p in (W/'screens').glob('*.png'):cp(p,stage/'页面预览'/p.name)
 cp(W/'screens/sources.json',evidence/'页面源码指纹.json')
 patch=git('diff','--binary','--','src/add_engine_harm.v')
 if patch:
  actual=(ROOT/'src/add_engine_harm.v').read_bytes()
  assert actual.replace('     // ★ 增益合并：'.encode(),'    // ★ 增益合并：'.encode(),1)==git('show','HEAD:src/add_engine_harm.v')
  (evidence/'构建时既有注释空格差异.patch').write_bytes(patch)
 meta={'source_commit':commit,'mode':m['video_mode'],'resolution':[1920,1080],'refresh_hz':75000000/(2200*1125),'build':m,'acceptance':a,'source_snapshot_note':'Exact accepted build inputs included. Existing one-space comment difference remains uncommitted in the development worktree and is captured separately.','sd_image_sha256':sha(image),'flash_written_for_this_release':False}
 (stage/'版本.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
 notes=f'''# 已验收1080p30完整版本

输出1920×1080、约30.303Hz。源码提交：`{commit}`。

用户已确认“三页、按键和声音都正常”。已使用openFPGALoader临时加载SRAM；本次未写Flash，尚未做本1080p版本冷启动验收。当前板上Flash仍为此前已验收720p，断电后会恢复该版本。

保留三页界面、下落音符、多乐器自动播放/教学、蓝牙v3收谱并自动存SD、管乐长按及混响修复。按下确认0.5ms、释放确认20ms。与此前18项数字链路测量的音频/按键源文件指纹完全一致，最慢2.794ms；前提为样本已预加载、有效静态手势及指定DDR等待模型，不含模拟DAC/功放/声传播，也不是任意抖动与等待下的全局上界。

全局setup/hold违例0/0，最小报告setup+1.333ns，BSRAM313/340。68条功能回归PASS、13张完整页面比对一致；原厂PLL/DPB/OSER10模型下的自然启动与复位后串行引脚检查通过。

## 包内内容与使用

- `piano64_3/`：完整源码、参数/IP、工具与文档；`impl/pnr/piano64_full.fs`及`.bin`为匹配已验收固件，构建清单和时序报告同目录。
- `SD/`：真实P64.BIN和SONG01～05。原卡已具备文件时保留原内容；新卡按原工程FAT32要求准备后复制。蓝牙上传按原v3协议执行。
- `页面预览/`、`验证记录/`、`版本.json`和`SHA256SUMS`：页面、回归、构建、实测及逐文件指纹。归档包含构建时已存在的一个注释空格差异补丁，保证构建输入逐字匹配，不改动开发工作树中的该差异。

在`piano64_3/`运行：

```bash
./flash.sh --check
./flash.sh --ftdi-serial 2025030317 --write-sram --quiet
```

第一条只校验；第二条临时加载。需要固化时可自行运行`./flash.sh --ftdi-serial 2025030317 --write-flash --verify --quiet`，随后断电再上电检查三页、按键和声音。本次发布操作不执行固化。

源码默认选择`1080p30-single`；重建执行`bash build_full.sh`，功能检查执行`python3 tools/check_all.py --bt`。重新构建前可显式选择`python3 tools/set_video_mode.py 1080p30-single`。KEY0切三页；教学页R1[8]下一首、R2[8]确认，按曲谱自动切换乐器和八度；节拍点半力度兜底、±150ms内按对恢复正常力度。

固件SHA-256：`{m['bitstreams']['piano64_full.fs']}`。

GitHub默认源码及发行包现更新为本1080p30版本。旧720p可从历史及`720p-low-latency-flash-verified-20261104`标签恢复；1080p60实验的时序未通过固件未混入本包的`impl/pnr/`。
'''
 (stage/'使用说明.md').write_text(notes)
 run(['python3','tools/check_build.py'],repo,evidence/'归档工程一致性.log')
 for p,h in m['inputs'].items():assert sha(repo/p)==h,p
 for p,h in m['bitstreams'].items():assert sha(repo/'impl/pnr'/p)==h,p
 sums={str(p.relative_to(stage)):sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
 (stage/'SHA256SUMS').write_text(''.join(h+'  '+p+'\n' for p,h in sums.items()))
 run(['rar','a','-ma5','-m5','-idq','-r',str(archive),stage.name],stage.parent,ROOT/'work/release1080p30/rar_create.log')
 run(['rar','t','-idq',str(archive)],stage.parent,ROOT/'work/release1080p30/rar_test.log')
 extracted=ROOT/'work/release1080p30/extracted';assert not extracted.exists();extracted.mkdir()
 run(['rar','x','-idq',str(archive),str(extracted)+'/'],stage.parent,ROOT/'work/release1080p30/rar_extract.log')
 check=extracted/stage.name
 for p,h in sums.items():assert sha(check/p)==h,p
 assert (check/'SHA256SUMS').read_bytes()==(stage/'SHA256SUMS').read_bytes()
 run(['python3','tools/check_build.py'],check/'piano64_3',ROOT/'work/release1080p30/extracted_check.log')
 archive_hash=sha(archive)
 (OUT/(NAME+'.rar.sha256')).write_text(archive_hash+'  '+archive.name+'\n')
 (OUT/(NAME+'_说明.md')).write_text(notes)
 summary={'archive':archive.name,'bytes':archive.stat().st_size,'sha256':archive_hash,'source_commit':commit,'fs_sha256':m['bitstreams']['piano64_full.fs'],'files':len(sums)+1,'format':'RAR5','integrity_test':'PASS','extract_all_files_sha256':'PASS','extracted_source_firmware_check':'PASS','video_mode':m['video_mode'],'user_accepted':True,'flash_written_for_this_release':False}
 (OUT/(NAME+'_清单.json')).write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
 (OUT/(NAME+'_验收.json')).write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(summary,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
