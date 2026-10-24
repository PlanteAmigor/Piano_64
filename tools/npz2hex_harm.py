#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
npz2hex_harm.py —— 把笛子/唢呐的「谐波表」npz 转成 FPGA 可读的 hex。

## 模型（与 tools/harm_fit.py 的 HarmModel.forward 一致）

    s(t) = Σ_m env_m(t) · [ a_m·cos(2πΘ_m) − b_m·sin(2πΘ_m) ]
    env_m(t) = EnvTab_m(u(t)) · (1 − e^(−t/τu_m))
    Θ_m(t) = m·Φ(u(t)) + δ_m·t + Ψ_m(u(t))

    u(t) = (1−α)·t/D + α·ln(1+t/T0)/ln(1+D/T0)      α=0.6  T0=0.06  D=3s

## 表布局（紧凑，按音连续，变长）

所有音拼在一个地址空间里，每音给一个基址。每音内部的相对偏移：

    标量区   K+1 字：{K, npsi}                     1 字（K, Ψ 条数）
             a_m[K]  b_m[K]                        2K 字（16 bit 有符号）
             dm_m[K]                                K 字（16 bit，0.001 Hz/LSB）
             tau_u_m[K]                             K 字（16 bit，0.01 ms/LSB）
    ❰ 区     phi[NT]                              NT×2 字（32 bit **无符号**，Q11.21 圈）
    Ψ 区     psi[npsi][NT2]                        npsi×NT2 字（16 bit，Q3.12 圈）
    Env 区   env[K][NT3]                           K×NT3 字（16 bit，Q0.15）

★ Φ 存【绝对值】32 位 Q11.21，不存增量：
  - 16 bit 存绝对值只剩 5 bit 小数（1/32 圈 ≈ 0.11 rad），超出 0.2 rad 要求
  - 试过存「每样点增量」dphi 再用 32 bit 累加器重建，SNR 只有 4 dB ——
    累积误差把相位咬掉了；存绝对值直接查表无此问题
  - Q11.21：最大 1172.78 圈 ⇒ 2.46e9 < 2^32，用**无符号** 32 位刚好
  - 分辨率 2^-21 圈；相邻表点差约 1.95 圈，相对误差 2.4e-7
    ⇒ 频率误差 9.4e-5 Hz，远小于公式表要求的 0.011 Hz

◆ 实测定点量化后 SNR（vs 浮点参考 47.3 dB）:
    MIDI 67 (K=62) 44.82 dB   MIDI 79 (K=31) 43.68 dB   MIDI 91 (K=15) 48.11 dB

用法：
    export TMPDIR=$PWD/.tmp
    python3 npz2hex_harm.py \
        --dir ../../out/dizi/谐波 --pattern 'harm_DiZi_M*.npz' \
        --prefix dizi --outdir ../../.tmp/tables_harm
"""
import argparse
import glob
import os
import re
import sys

import numpy as np

FS = 48828.0
WARP_T0 = 0.06
WARP_D = 3.0
WARP_ALPHA = 0.6

MIDI_RE = re.compile(r'_M(\d+)')


def warp_u(t, T0=WARP_T0, D=WARP_D, alpha=WARP_ALPHA):
    """时间 → 表内归一化坐标 u∈[0,1]（与 harm_fit._warp_u 一致）"""
    return (1 - alpha) * (t / D) + alpha * np.log1p(t / T0) / np.log1p(D / T0)


def q16(x, lo, hi):
    """浮点 → 16 bit 定点（clamp 后 round）。返回 (数值, 缩放说明)"""
    v = np.clip(x, lo, hi)
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True)
    ap.add_argument('--pattern', default='harm_*_M*.npz')
    ap.add_argument('--prefix', required=True)
    ap.add_argument('--outdir', required=True)
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.dir, a.pattern)))
    if not files:
        print('✗ 没匹配到文件: %s/%s' % (a.dir, a.pattern))
        return 1

    notes = {}
    for fn in files:
        m = MIDI_RE.search(os.path.basename(fn))
        if not m:
            continue
        notes[int(m.group(1))] = fn

    midis = sorted(notes)
    print('读取 %d 个音  MIDI %d..%d' % (len(midis), midis[0], midis[-1]))

    # ── 先扫一遍算总字数和范围 ─────────────────────────────────────
    info = {}
    tot_words = 0
    for mi in midis:
        d = np.load(notes[mi], allow_pickle=True)
        K = int(len(d['dm']))
        NT = int(d['nt'])
        NT2 = int(d['nt2'])
        NT3 = int(d['nt3'])
        mask = np.asarray(d['phm_mask'], dtype=np.float64)
        npsi = int((mask != 0).sum())
        words = (2 + 2 * K + K + K) + NT * 2 + npsi * NT2 + K * NT3
        info[mi] = dict(K=K, NT=NT, NT2=NT2, NT3=NT3, npsi=npsi, words=words)
        tot_words += words

    print('  总字数 %d（16 bit）= %.3f Mbit = %.1f%% of 6.12 Mbit'
          % (tot_words, tot_words * 16 / 1e6, tot_words * 16 / 6.12e6 * 100))
    print('  按 18432 bit/块 估算 BSRAM ≈ %d 块 = %.0f%%'
          % (int(np.ceil(tot_words * 16 / 18432)),
             tot_words * 16 / 18432 / 340 * 100))
    print('  K 范围 %d..%d，Ψ 条数 %d..%d'
          % (min(v['K'] for v in info.values()), max(v['K'] for v in info.values()),
             min(v['npsi'] for v in info.values()), max(v['npsi'] for v in info.values())))

    # ── 分配基址 ──────────────────────────────────────────────────
    base = {}
    cur = 0
    for mi in midis:
        base[mi] = cur
        cur += info[mi]['words']

    os.makedirs(a.outdir, exist_ok=True)

    # ── 逐音转换 ──────────────────────────────────────────────────
    # 所有音拼成一个连续数组（16 bit 无符号存储，有符号量用二进制补码）
    data = np.zeros(cur, dtype=np.uint16)
    stats = []

    for mi in midis:
        d = np.load(notes[mi], allow_pickle=True)
        inf = info[mi]
        K, NT, NT2, NT3, npsi = inf['K'], inf['NT'], inf['NT2'], inf['NT3'], inf['npsi']

        c = np.asarray(d['c'], dtype=np.float64)
        am = c[:K]
        bm = c[K:2 * K]
        dm = np.asarray(d['dm'], dtype=np.float64)          # Hz
        tau_u = np.asarray(d['u'], dtype=np.float64)        # s
        phi = np.asarray(d['phi'], dtype=np.float64)        # 圈（绝对值）
        phm = np.asarray(d['phm'], dtype=np.float64)
        env = np.asarray(d['env'], dtype=np.float64)
        mask = np.asarray(d['phm_mask'], dtype=np.float64)

        # Φ → 32 位无符号绝对值（Q11.21 圈）。直接查表，不做差分/累加。
        SC_PHI = float(1 << 21)

        # 量化
        SC_A = 4096.0                     # a/b：±8.0 → Q3.12
        SC_DM = 1000.0                    # dm：0.001 Hz/LSB，±32 Hz
        SC_TU = 100000.0                  # tau_u：0.01 ms/LSB，0..655 ms
        SC_PS = 8192.0                    # psi：±4 圈 → Q3.12（实测最大 2.28 圈）
        SC_EV = 32768.0                   # env：±1.0 → Q0.15

        def q(v, sc, lo, hi):
            return np.round(np.clip(v * sc, lo, hi)).astype(np.int64) & 0xFFFF

        w = base[mi]
        data[w + 0] = (K & 0xFF) | ((npsi & 0xFF) << 8)
        data[w + 1] = inf['words'] & 0xFFFF
        w += 2
        data[w:w + K] = q(am, SC_A, -32768, 32767);      w += K
        data[w:w + K] = q(bm, SC_A, -32768, 32767);      w += K
        data[w:w + K] = q(dm, SC_DM, -32768, 32767);     w += K
        data[w:w + K] = q(tau_u, SC_TU, 0, 65535);       w += K

        # phi 存 32 位无符号：低 16 字在前，高 16 字接后
        ph32 = np.round(np.clip(phi, 0.0, 2047.0) * SC_PHI).astype(np.uint64) & 0xFFFFFFFF
        data[w:w + NT] = (ph32 & 0xFFFF).astype(np.uint16)
        w += NT
        data[w:w + NT] = ((ph32 >> 16) & 0xFFFF).astype(np.uint16)
        w += NT

        rows = np.where(mask != 0)[0]
        psi_all = []
        for r in rows:
            row = phm[r] * mask[r]
            data[w:w + NT2] = q(row, SC_PS, -32768, 32767)
            psi_all.append(np.abs(row).max())
            w += NT2

        for m in range(K):
            data[w:w + NT3] = q(env[m], SC_EV, -32768, 32767)
            w += NT3

        stats.append(dict(midi=mi, K=K, npsi=npsi, words=inf['words'],
                          phi_max=float(np.abs(phi).max()),
                          tau_min=float(tau_u.min() * 1e3),
                          tau_max=float(tau_u.max() * 1e3),
                          a_max=float(np.abs(am).max()),
                          psi_max=float(max(psi_all) if psi_all else 0.0),
                          env_max=float(np.abs(env).max())))

    # ── 写出 ──────────────────────────────────────────────────────
    # 每行一个字，8 位十六进制（高位补 0）
    with open(os.path.join(a.outdir, '%s_param.hex' % a.prefix), 'w') as f:
        for v in data:
            f.write('%08X\n' % int(v))
    with open(os.path.join(a.outdir, '%s_base.hex' % a.prefix), 'w') as f:
        for mi in midis:
            f.write('%08X\n' % base[mi])

    print('\n写出:')
    print('  %s/%s_param.hex  (%d 字)' % (a.outdir, a.prefix, len(data)))
    print('  %s/%s_base.hex   (%d 音基址)' % (a.outdir, a.prefix, len(midis)))
    print('\n%-6s %4s %5s %8s %10s %10s %7s %7s %7s' %
          ('MIDI', 'K', 'npsi', 'words', 'phi_max', 'tau_ms', 'a_max', 'psi_max', 'env_max'))
    for s in stats:
        print('%-6d %4d %5d %8d %10.1f %4.1f-%-4.1f %7.3f %7.3f %7.3f'
              % (s['midi'], s['K'], s['npsi'], s['words'], s['phi_max'],
                 s['tau_min'], s['tau_max'], s['a_max'], s['psi_max'], s['env_max']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
