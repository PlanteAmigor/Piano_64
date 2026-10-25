#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cmp_engine.py —— 流水引擎 vs 已验证的单声部 add_voice_harm

两套 RTL 用完全不同的表格式和调度，能逐样点对上就说明流水引擎的
寻址/流水/定标全对。允许 ±3 个样点的整体延迟差（两者起始时刻的定义不同）。

用法：
    python3 tools/cmp_engine.py --a sim/harm_sim_out.txt \
        --b sim/harm2/engine_sim_out.txt --n 2800
"""
import argparse
import sys

import numpy as np


def load(p, n):
    v = np.array([int(x) for x in open(p).read().split()], dtype=np.int64)
    return v[:n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--a', required=True, help='add_voice_harm 输出（基准）')
    ap.add_argument('--b', required=True, help='add_engine_harm 输出')
    ap.add_argument('--n', type=int, default=2800)
    ap.add_argument('--skip', type=int, default=40, help='跳过起振最开始几拍（量化噪声主导）')
    a = ap.parse_args()

    A = load(a.a, a.n + 8)
    B = load(a.b, a.n + 8)
    n = min(len(A), len(B))

    best = None
    for off in range(-4, 5):
        if off >= 0:
            x, y = A[a.skip:n], B[a.skip + off:n + off]
        else:
            x, y = A[a.skip - off:n - off], B[a.skip:n]
        m = min(len(x), len(y))
        x, y = x[:m], y[:m]
        d = np.abs(x - y).max()
        if best is None or d < best[0]:
            best = (d, off, x, y)

    d, off, x, y = best
    sig = np.sqrt((x.astype(float) ** 2).mean())
    noi = np.sqrt(((x.astype(float) - y) ** 2).mean())
    snr = 20 * np.log10(sig / noi) if noi > 0 else float('inf')
    print('对齐偏移 %+d 样点，比较 %d 点' % (off, len(x)))
    print('  基准 rms = %8.1f   差异 rms = %8.2f   SNR = %s'
          % (sig, noi, ('∞（逐点完全一致）' if noi == 0 else '%.1f dB' % snr)))
    print('  最大绝对差 = %d' % d)
    bad = np.where(np.abs(x - y) > max(3, int(0.02 * sig)))[0]
    print('  超差样点 %d / %d' % (len(bad), len(x)))
    if len(bad):
        print('  前 10 个超差位置：', bad[:10])
        for i in bad[:8]:
            print('    i=%4d  基准=%7d  引擎=%7d  差=%6d' % (i, x[i], y[i], x[i] - y[i]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
