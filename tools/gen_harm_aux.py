#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_harm_aux.py —— 生成谐波引擎需要的两张辅助表

## harm_u.hex —— 弯曲时间轴 u(t)

    u(t) = (1−α)·t/D + α·ln(1+t/T0)/ln(1+D/T0)      α=0.6  T0=0.06  D=3s

    RTL 里每 16 个样点取一次表点、线性插值，避免实时算对数。
    点数 = 16384，覆盖 16384×16 = 262144 个样点（> 3 s 的 146484）。
    格式：32 bit 无符号 Q0.32（u ∈ [0,1]）

## harm_sin.hex —— 单值正弦表

    1024 点，16 bit 有符号，sin(2πi/1024)×32767
    与现成的 add_sine.hex 不同：那个是 {sin(i+1), sin(i)} 配对格式（32 bit），
    谐波引擎因为已经用 A/φ 形式，每次只需要一个 sin 值 + 线性插值。

用法：
    export TMPDIR=$PWD/.tmp
    python3 gen_harm_aux.py --outdir ../../.tmp/tables_harm
"""
import argparse
import os
import sys

import numpy as np

FS = 48828.0
WARP_T0 = 0.06
WARP_D = 3.0
WARP_ALPHA = 0.6

TAB_STEP = 16          # RTL 每 16 个样点取一个表点
N_U = 16384
N_SIN = 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--outdir', required=True)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    # ── u 表 ──────────────────────────────────────────────────────
    n = np.arange(N_U) * TAB_STEP                 # 样点序号
    t = n / FS                                    # 秒
    u = ((1 - WARP_ALPHA) * t / WARP_D
         + WARP_ALPHA * np.log1p(t / WARP_T0) / np.log1p(WARP_D / WARP_T0))
    u = np.clip(u, 0.0, 1.0)
    u32 = np.round(u * (1 << 32)).astype(np.uint64) & 0xFFFFFFFF
    # 表尾（超出 3 s）保持 1.0
    u32[t > WARP_D] = 0xFFFFFFFF

    with open(os.path.join(a.outdir, 'harm_u.hex'), 'w') as f:
        for v in u32:
            f.write('%08X\n' % int(v))

    print('harm_u.hex  %d 点，覆盖 %d 样点 = %.2f s'
          % (N_U, N_U * TAB_STEP, N_U * TAB_STEP / FS))
    print('  u 范围 %.6f .. %.6f' % (u.min(), u.max()))
    print('  相邻点 Δu 最小 %.3e 最大 %.3e（比值 %.1f×）'
          % (np.diff(u).min(), np.diff(u).max(),
             np.diff(u).max() / max(np.diff(u).min(), 1e-30)))

    # ── 正弦表 ────────────────────────────────────────────────────
    i = np.arange(N_SIN)
    s = np.round(np.sin(2 * np.pi * i / N_SIN) * 32767).astype(np.int64) & 0xFFFF
    with open(os.path.join(a.outdir, 'harm_sin.hex'), 'w') as f:
        for v in s:
            f.write('%04X\n' % int(v))

    print('harm_sin.hex %d 点，16 bit 有符号' % N_SIN)
    print('  峰值 %d（满刻度 32767）' % int(np.abs(np.sin(2 * np.pi * i / N_SIN) * 32767).max()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
