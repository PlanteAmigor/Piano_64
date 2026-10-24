#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge_guzheng_txt.py —— 把古筝逐音参数 txt（每音一个文件）合并成
gen_modal_rom.py 能读的分段格式。

输入目录下每个文件形如 A3.txt：
    # A3 (MIDI 57) K=256 3s窗 GPU Adam fs=48828  抗混叠已修 τ上限3.0s
      #      f(Hz)    tau(ms)          a       dB  phi(deg)
      1    498.855       3.07   29.50902      0.0      -9.0
      2    680.713       2.46   21.32802     -2.8     150.6
      ...

输出（gen_modal_rom.py 的解析格式）：
    ### M057
    | 1 | 498.855 | 3.07 | 29.50902 | 0.0 | -9.0 |
    ### M058
    ...

用法：
    export TMPDIR=$PWD/.tmp
    python3 merge_guzheng_txt.py \
        --dir /mnt/project/InstruementSound/out/古筝_全音域/参数 \
        --out /mnt/project/InstruementSound/.tmp/guzheng_all.md
"""
import argparse
import os
import re
import sys

HEAD_MIDI = re.compile(r'MIDI\s+(\d+)')
# 数据行：序号 频率 时间常数 幅度 dB 相位
ROW = re.compile(r'^\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*$')


def parse_one(path):
    """返回 (midi, [(idx, f, tau_ms, a, db, phi_deg), ...]) 或 (None, None)"""
    midi = None
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            if midi is None:
                m = HEAD_MIDI.search(line)
                if m:
                    midi = int(m.group(1))
                    continue
            m = ROW.match(line)
            if m:
                rows.append((int(m.group(1)), m.group(2), m.group(3),
                             m.group(4), m.group(5), m.group(6)))
    if midi is None or not rows:
        return None, None
    # 按幅度降序（与 gen_modal_rom.py 的假设一致：取前 NPART 个幅度最大的）
    rows.sort(key=lambda r: -float(r[3]))
    return midi, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='古筝逐音 txt 目录')
    ap.add_argument('--out', required=True, help='输出合并文件')
    a = ap.parse_args()

    files = sorted(f for f in os.listdir(a.dir) if f.endswith('.txt'))
    if not files:
        print('✗ 目录里没有 .txt: %s' % a.dir)
        return 1

    got = {}
    for fn in files:
        midi, rows = parse_one(os.path.join(a.dir, fn))
        if midi is None:
            print('  ⚠ 跳过（没解析出 MIDI 或数据行）: %s' % fn)
            continue
        if midi in got:
            print('  ⚠ MIDI %d 重复: %s' % (midi, fn))
            continue
        got[midi] = (fn, rows)

    midis = sorted(got)
    print('解析 %d 个文件，得到 %d 个音  MIDI %d..%d'
          % (len(files), len(midis), midis[0], midis[-1]))
    missing = [m for m in range(midis[0], midis[-1] + 1) if m not in got]
    if missing:
        print('  ⚠ 音号不连续，缺: %s' % missing)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write('# 古筝全音域参数（由 merge_guzheng_txt.py 合并）\n')
        f.write('# 每音的分量按幅度降序排列\n\n')
        for m in midis:
            fn, rows = got[m]
            f.write('### M%03d   %s\n' % (m, fn))
            f.write('| # | f (Hz) | tau (ms) | a | dB | phi (deg) |\n')
            f.write('|---|---|---|---|---|---|\n')
            for r in rows:
                f.write('| %d | %s | %s | %s | %s | %s |\n' % r)
            f.write('\n')

    print('写出 %s' % a.out)
    print('  每音分量数: min=%d max=%d'
          % (min(len(r) for _, r in got.values()),
             max(len(r) for _, r in got.values())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
