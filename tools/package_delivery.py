#!/usr/bin/env python3
"""Package only a source-matched, timing-clean, SRAM-programmed delivery."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[1]
OUTPUTS=Path('/home/amigor/Documents/Codex/2026-11-03/n/outputs')

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def copy(a,b):b.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a,b)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--screens',type=Path,required=True)
    ap.add_argument('--checks',type=Path,required=True)
    args=ap.parse_args()
    subprocess.run(['python3','tools/check_build.py'],cwd=ROOT,check=True)
    manifest=json.loads((ROOT/'impl/pnr/piano64_full.manifest.json').read_text())
    board=json.loads((ROOT/'work/ui1080/board_delivery.json').read_text())
    assert board['exit_code']==0 and board['fs_sha256']==manifest['bitstreams']['piano64_full.fs']
    assert 'All requested regressions passed.' in args.checks.read_text()
    for line in (ROOT/'work/song_checks/source_sha256.txt').read_text().splitlines():
        want,relative=line.split('  ',1);assert sha(ROOT/relative)==want,relative
    sources=json.loads((args.screens/'sources.json').read_text())
    assert all(sha(ROOT/name)==want for name,want in sources.items())
    dirty=subprocess.check_output(['git','diff','--name-only'],cwd=ROOT,text=True).splitlines()
    assert set(dirty)<= {'src/add_engine_harm.v'},dirty
    status=subprocess.check_output(['git','status','--porcelain=v1','-z'],cwd=ROOT).split(b'\0')
    assert all(not item or item==b' M src/add_engine_harm.v' for item in status),status
    harm=(ROOT/'src/add_engine_harm.v').read_bytes().replace('     // ★ 增益合并：'.encode(),'    // ★ 增益合并：'.encode(),1)
    assert harm==subprocess.check_output(['git','show','HEAD:src/add_engine_harm.v'],cwd=ROOT)
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    OUTPUTS.mkdir(parents=True,exist_ok=True)
    folder=OUTPUTS/f'InstruementSound_BTSD_1080p_{commit[:7]}'
    folder.mkdir(exist_ok=False)
    repo=folder/'piano64_3';repo.mkdir()
    files=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).split(b'\0')
    for name in files:
        if name:copy(ROOT/name.decode(),repo/name.decode())
    for name,want in manifest['inputs'].items():
        assert sha(ROOT/name)==want;copy(ROOT/name,repo/name)
    copy(ROOT.parent/'P64.BIN',repo/'P64.BIN')
    copy(ROOT.parent/'P64.BIN',folder/'SD/P64.BIN')
    for p in sorted((ROOT/'tools/generated').glob('SONG*.BIN')):copy(p,folder/'SD'/p.name)
    pnr=ROOT/'impl/pnr'
    for p in sorted(pnr.iterdir()):
        if p.is_file() and p.name.startswith('piano64_full') and p.suffix in ['.fs','.bin','.json','.txt','.html','.timing_paths']:
            copy(p,repo/'impl/pnr'/p.name)
    for p in sorted(args.screens.glob('*.png')):copy(p,folder/'页面预览'/p.name)
    copy(args.screens/'sources.json',folder/'验证记录/页面源码指纹.json')
    copy(args.checks,folder/'验证记录/完整回归.log')
    assert 'PASS independent native SD image oracle' in (ROOT/'work/bt_store/regression.log').read_text()
    copy(ROOT/'work/bt_store/regression.log',folder/'验证记录/蓝牙SD回归.log')
    copy(ROOT/'doc/bluetooth/蓝牙收谱与SD保存.md',folder/'蓝牙收谱与SD保存.md')
    copy(ROOT/'doc/bluetooth/PROTOCOL_V3.md',folder/'蓝牙原协议.md')
    copy(ROOT/'work/song_checks/chorus/model.log',folder/'验证记录/合唱数值对比.log')
    first_bench=(ROOT/'work/song_checks/tb_song_keys.log').stat().st_mtime
    for p in sorted((ROOT/'work/song_checks').glob('*.log')):
        if p.stat().st_mtime>=first_bench:copy(p,folder/'验证记录/仿真'/p.name)
    for name in ['all_results.txt','source_sha256.txt']:copy(ROOT/'work/song_checks'/name,folder/'验证记录'/name)
    copy(ROOT/'work/ui1080/board_delivery.json',folder/'验证记录/烧录记录.json')
    copy(ROOT/'work/ui1080/flash_final.log',folder/'验证记录/烧录.log')
    copy(args.build.parent/(args.build.name+'.log'),folder/'验证记录/完整构建.log')
    copy(args.build/'work/inputs.json',repo/'work/build_inputs.json')
    (folder/'版本.json').write_text(json.dumps({'commit':commit,'build':manifest,'board':board},ensure_ascii=False,indent=2)+'\n')
    (folder/'使用说明.md').write_text(f'''# 蓝牙自动存谱 · 多乐器教学 · 1080p60

版本：`{commit[:7]}`。已通过完整仿真、全局 setup/hold 零违例检查，并使用 openFPGALoader 完成 SRAM 下载。SRAM 版本掉电后需重新下载。本机没有视频采集或声音回录，板上观感与试听请按下面步骤检查。

## 蓝牙收谱

1. BT36 的 TX 接 AB20，RX 接 AA21，共地；UART 为 115200/8N1。原有调试串口不变。
2. 卡内保留 P64.BIN 和已有曲谱，上电等音源、歌曲列表就绪。
3. 手机按 v3 协议上传。END 确认成功表示新 SONGxx.BIN 已存入 FAT32 SD 卡、读回核对并刷新目录。已有文件不覆盖，不自动播放。
4. 手机 PLAY 进入歌曲播放页；STOP 停止。之后也能从板端目录选择，进入自动或教学模式。重新上电仍能在目录中选择该文件。
5. 本版最多 2048 个事件、目录最多 16 首，手机应先 QUERY 获取容量。存卡期间保持供电和插卡。协议、错误恢复及存储范围见随包《蓝牙收谱与SD保存》。

## 先使用

1. 将 `SD/SONG05.BIN` 放到原有工程 SD 卡根目录，保留原有 P64.BIN 和曲谱。新卡可复制 `SD/` 中全部文件。电脑当前未识别到工程 SD 卡，因此新曲随包提供。
2. KEY0 切换主页面、八键纯音测试、教学页面。主页面保留频谱、64 分量和李萨如，显示为原生 1920×1080p60。
3. 教学页 R1[8] 下一首，R2[8] 确认；选择教学模式并开始。准备 3 秒后跟随判定线按七个 C/D/E/F/G/A/B 键。
4. 用户负责主旋律；乐器、八度自动按谱切换。其他声部自动伴奏，黑键自动演奏。漏按时主旋律准时以半力度发声，±150 ms 内按对后平滑恢复正常力度。
5. 演奏时 R2[8] 停止，长按 R2[8] 返回。手势影响主旋律，伴奏保持独立。

SONG05 是约 34 秒的多乐器《小星星》：笛子→古筝→唢呐→钢琴主旋律，钢琴低音与古筝分解音伴奏。现有引擎支持同时 7 个钢琴／古筝声部加 1 个管乐声部；笛子与唢呐可先后切换。

## 板上检查

- 显示器信息应报告 1080p60；三页文字、边框和音符应清晰且无抖动、花屏。
- 自由演奏检查多键紧密按下、松键停止、长按笛子／唢呐和四种音色的混响。
- SONG05 中故意漏按，再按对：主旋律应由半力度恢复正常，伴奏连续；换乐器和八度无需菜单操作。

## 工程与复验

完整工程在 `piano64_3/`。运行 `python3 tools/check_all.py --bt` 做功能回归，`python3 tools/render_ui1080.py --jobs 4` 捕获实际 RTL 页面，`./build_full.sh` 完整重建，`./flash.sh --check` 检查固件与源码是否匹配。

临时下载：`./flash.sh --ftdi-serial 2025030317 --write-sram --quiet`。已交付固件位于 `piano64_3/impl/pnr/piano64_full.fs`。构建、时序、测试、烧录和源码指纹记录均随包提供。

固件 SHA-256：`{manifest['bitstreams']['piano64_full.fs']}`。
''')
    subprocess.run(['python3','tools/check_build.py'],cwd=repo,check=True)
    # The delivered sources are byte-identical to the already tested inputs.
    # Verify the copied tree and its local instrument image without rerunning
    # unchanged audio simulations a second time.
    matched=[]
    for name in files:
        if name:
            relative=name.decode();assert sha(ROOT/relative)==sha(repo/relative),relative
            matched.append(relative)
    assert sha(repo/'P64.BIN')==sha(ROOT.parent/'P64.BIN')
    with (folder/'验证记录/工程一致性复验.log').open('w') as log:
        subprocess.run(['python3','tools/check_build.py'],cwd=repo,stdout=log,stderr=subprocess.STDOUT,check=True)
        log.write(f'PASS {len(matched)} tracked files identical to tested project; local P64.BIN exact\n')
    shutil.rmtree(repo/'work',ignore_errors=True)
    copy(args.build/'work/inputs.json',repo/'work/build_inputs.json')
    checks=[]
    for p in sorted(folder.rglob('*')):
        if p.is_file():checks.append(sha(p)+'  '+str(p.relative_to(folder)))
    (folder/'SHA256SUMS').write_text('\n'.join(checks)+'\n')
    archive=folder.with_suffix('.zip')
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in sorted(folder.rglob('*')):
            if p.is_file():z.write(p,folder.name+'/'+str(p.relative_to(folder)))
    with zipfile.ZipFile(archive) as z:assert z.testzip() is None
    archive.with_suffix('.zip.sha256').write_text(sha(archive)+'  '+archive.name+'\n')
    print('DELIVERED',folder,archive,sha(archive))

if __name__=='__main__':main()
