#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cmp_harm_sim.py —— 把 RTL 输出（harm_sim_out.txt）与「同一张表」的浮点参考对比

参考模型完全按 RTL 的解码方式重建，只是用 float 算：
    hA    = A × 8192                        → A = hA/8192
    hSC   = env_scale × 32768               → scale = hSC/32768
    env   = int8/127 × scale
    psi   = Q3.12  → /4096
    phi   = Q13.19 → /2^19   （圈）
    phi_a = Q0.16  → /65536  （圈）
    dm    = /1000   （Hz）
    Θ_m   = m·Φ(u) + δ_m·t + Ψ_m(u) + phi_a
    s(t)  = Σ env_m(t)·A_m·sin(2π·Θ_m)
    out   = 32767·s(t)

用法（在工程根目录）：
    python3 tools/cmp_harm_sim.py --tab sim/harm_tab --out sim/harm_sim_out.txt \
        --midi 67 --n 64
"""
import argparse
import os
import re
import sys

import numpy as np

FS = 48828.0
WARP_T0, WARP_D, WARP_ALPHA = 0.06, 3.0, 0.6
NT, NT2, NT3 = 600, 300, 150


def warp_u(t):
    return ((1 - WARP_ALPHA) * t / WARP_D
            + WARP_ALPHA * np.log1p(t / WARP_T0) / np.log1p(WARP_D / WARP_T0))


def rd_hex(path):
    return np.array([int(x, 16) for x in open(path).read().split()], dtype=np.uint64)


def sx16(v):
    v = v.astype(np.int64) & 0xFFFF
    return np.where(v >= 0x8000, v - 0x10000, v)


def sx8(v):
    v = v.astype(np.int64) & 0xFF
    return np.where(v >= 0x80, v - 0x100, v)


def q13_19_to_turns(v):
    """32 位无符号 Q13.19 → 圈（浮点）"""
    return v.astype(np.float64) / float(1 << 19)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tab', required=True, help='含 *_param.hex / *_base.hex 的目录')
    ap.add_argument('--prefix', default='dizi')
    ap.add_argument('--out', required=True, help='RTL 输出样点文件')
    ap.add_argument('--midi', type=int, default=67)
    ap.add_argument('--n', type=int, default=0, help='对比样点数（0=用文件里的全部）')
    a = ap.parse_args()

    data = rd_hex(os.path.join(a.tab, '%s_param.hex' % a.prefix))
    bases = rd_hex(os.path.join(a.tab, '%s_base.hex' % a.prefix))

    # 音基址表按 MIDI 升序（见 npz2hex_harm.py），首个 MIDI 由文件名顺序决定
    # 这里按 --midi 与 base 表顺序推测：base.hex 第 i 行对应第 i 个音
    # 为稳妥起见直接扫描所有 base 找 K/npsi 合理的那个
    # —— 简化：第一个音是 MIDI 67（dizi 目录里 M67 起）
    midi_lo = 67 if a.prefix == 'dizi' else 64
    idx = a.midi - midi_lo
    if idx < 0 or idx >= len(bases):
        print('✗ base 索引越界：idx=%d len=%d' % (idx, len(bases)))
        return 1
    base = int(bases[idx])

    K = int(data[base] & 0xFF)
    npsi = int((data[base] >> 8) & 0xFF)
    words = int(data[base + 1])
    print('MIDI %d  base=%d  K=%d  npsi=%d  words=%d' % (a.midi, base, K, npsi, words))

    o_A = base + 2
    o_PA = o_A + K
    o_DM = o_PA + K
    o_SC = o_DM + K
    o_PI = o_SC + K
    o_PHI = o_PI + K
    o_PSI = o_PHI + 2 * NT
    o_ENV = o_PSI + npsi * NT2

    A = sx16(data[o_A:o_A + K]) / 4096.0     # A 是 Q4.11（±8.0）
    hPA = sx16(data[o_PA:o_PA + K]) / 65536.0
    DM = sx16(data[o_DM:o_DM + K]) / 1000.0
    SC = (data[o_SC:o_SC + K] & 0xFFFF).astype(np.float64) / 32768.0
    PI = (data[o_PI:o_PI + K] & 0xFFFF).astype(np.int64)

    ph32 = (data[o_PHI:o_PHI + NT].astype(np.uint64)
            | (data[o_PHI + NT:o_PHI + 2 * NT].astype(np.uint64) << np.uint64(16)))
    PHI = q13_19_to_turns(ph32)

    PSI = np.zeros((npsi, NT2))
    for r in range(npsi):
        PSI[r] = sx16(data[o_PSI + r * NT2: o_PSI + (r + 1) * NT2]) / 4096.0

    ENVRAW = np.zeros((K, NT3))
    for m in range(K):
        ENVRAW[m] = sx8(data[o_ENV + m * NT3: o_ENV + (m + 1) * NT3])

    rtl = np.array([int(x) for x in open(a.out).read().split()], dtype=np.int64)
    n = a.n if a.n > 0 else len(rtl)
    n = min(n, len(rtl))

    # ── 逐样点重建（向量化）─────────────────────────────────────
    #  ★ 必须用 RTL 那张 u 表（每 16 样点一点 + 线性插值），不能用解析式：
    #    dΦ/dt 在起振段高达 250 圈/秒，u 差 1e-6 就能让高次谐波差几度
    t = np.arange(n) / FS
    ut = rd_hex(os.path.join(a.tab, 'harm_u.hex')).astype(np.uint64)
    ui = np.arange(n) >> 4
    uf = (np.arange(n) & 0xF).astype(np.uint64)
    u0 = ut[ui]
    u1 = ut[np.minimum(ui + 1, len(ut) - 1)]
    # ★ 注意括号：Python 里 >> 的优先级比 + 低，写成 u0 + x >> 4 会变成 (u0+x)>>4
    u = ((u0 + (((u1 - u0) * uf) >> np.uint64(4))).astype(np.uint64)) / float(1 << 32)
    uu = np.linspace(0.0, 1.0, NT)
    uu2 = np.linspace(0.0, 1.0, NT2)
    uu3 = np.linspace(0.0, 1.0, NT3)

    Phi = np.interp(u, uu, PHI)
    s = np.zeros(n)
    for m in range(K):
        psi = np.interp(u, uu2, PSI[PI[m]]) if PI[m] != 0xFFFF else np.zeros(n)
        env = np.interp(u, uu3, ENVRAW[m]) / 127.0 * SC[m]
        thr = m * Phi + DM[m] * t + psi + hPA[m]
        s += env * A[m] * np.sin(2 * np.pi * thr)
    ref = 32767.0 * s

    # ── 统计 ──────────────────────────────────────────────────────
    err = rtl[:n] - ref
    sig = np.sum(ref ** 2)
    noi = np.sum(err ** 2)
    snr = 10 * np.log10(sig / noi) if noi > 0 else float('inf')
    print('\n样点 %d   RTL 峰值 %.0f   参考峰值 %.0f   增益 %.4f'
          % (n, np.abs(rtl[:n]).max(), np.abs(ref).max(),
             np.abs(rtl[:n]).max() / max(np.abs(ref).max(), 1e-30)))
    print('SNR = %.2f dB' % snr)
    print('\n%6s %12s %12s %12s' % ('i', 'RTL', 'ref', 'err'))
    show = min(n, 24)
    for i in range(show):
        print('%6d %12d %12.2f %12.2f' % (i, rtl[i], ref[i], err[i]))
    if n > show:
        step = max(1, n // 12)
        print('  ...')
        for i in range(show, n, step):
            print('%6d %12d %12.2f %12.2f' % (i, rtl[i], ref[i], err[i]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
