#!/usr/bin/env python3
"""
fx_chorus_ab.py —— 生成 CHORUS 各版本的 WAV，用于人耳 A/B
                 （唯一的变量是「LFO 正弦近似」，其余完全同构）

生成文件（out/fx_ab/）
----------------------
  0_dry.wav              干声（输入，无效果）
  1_float.wav            浮点理想参考（同一条干湿增益，用精确浮点正弦）
  2_fixed_nointerp.wav   定点版 B：正弦查表【不】插值  → 上板有"滋滋声"那版
  3_fixed_interp.wav     定点版 C：正弦查表 + 12 位插值 → 上板"更差"那版

用法
----
  source /mnt/project/InstruementSound/.venv/bin/activate
  python tools/fx_chorus_ab.py
"""
import os
import sys
import math
import wave
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import fx_sim                                   # 复用同一段乐句素材

# ── 与 RTL 完全同源的参数 ──────────────────────────────────────────────
FS        = 48828.125
ABUF      = 1024
BASE_Q8   = 150000          # 585.9375 样本 = 12.0 ms
DEPTH_Q8  = 43750           # 170.8984 样本 = 3.5 ms
LFO_STEP  = 52777           # 0.6 Hz
GD_Q8     = 149             # 干声 0.582
GW_Q8     = 149             # 湿声 0.582
PH_QUARTER = 0x4000_0000

OUTDIR = os.path.join(ROOT, 'out', 'fx_ab')

#  四分之一波表 sin(2*pi*j/256)*32767
SIN_Q = [round(32767 * math.sin(2 * math.pi * j / 256)) for j in range(65)]


# ─────────────────────────── 三个正弦实现 ───────────────────────────
def sin_exact(p):
    """精确浮点正弦 —— 定点流水线的理想上限"""
    return int(round(32767 * math.sin(2 * math.pi * (p & 0xFFFFFFFF) / 4294967296.0)))


def sin_lut_nofix(p):
    """6 位查表，不插值（版本 B）"""
    p &= 0xFFFFFFFF
    qd = p >> 30
    jx = (p >> 24) & 0x3F
    j = (64 - jx) if (qd & 1) else jx
    s = SIN_Q[j]
    return -s if (qd & 2) else s


def sin_lut_interp(p):
    """6 位查表 + 12 位线性插值（版本 C）"""
    p &= 0xFFFFFFFF
    qd = p >> 30
    jx = (p >> 24) & 0x3F
    if qd & 1:
        ia, ib = 64 - jx, 63 - jx
    else:
        ia, ib = jx, jx + 1
    jf = (p >> 12) & 0xFFF
    v = SIN_Q[ia] + (((SIN_Q[ib] - SIN_Q[ia]) * jf) >> 12)
    return -v if (qd & 2) else v


def soft_lim(x):
    ax = -x if x < 0 else x
    if ax <= 24000:
        yy = ax
    else:
        d = ax - 24000
        if d > 16384:
            d = 16384
        yy = 24000 + d - ((d * d) >> 15)
    if yy > 32767:
        yy = 32767
    return -yy if x < 0 else yy


# ─────────────────── 定点流水线（与 RTL 逐位等价） ───────────────────
def run_fixed(x, sinfn):
    """返回 (out_l, out_r)；左右 LFO 相差 90°"""
    n = len(x)
    mem_l = [0] * ABUF
    mem_r = [0] * ABUF
    wr = 0
    ph = 0
    ol = [0] * n
    orr = [0] * n
    for i in range(n):
        dq = []
        for ch in (0, 1):
            p = ph if ch == 0 else (ph + PH_QUARTER) & 0xFFFFFFFF
            sv = sinfn(p)
            dq.append((BASE_Q8 + ((DEPTH_Q8 * sv) >> 15)) & 0xFFFFFFFF)

        dint0 = (dq[0] >> 8) & 0x3FF
        frac0 = dq[0] & 0xFF
        dint1 = (dq[1] >> 8) & 0x3FF
        frac1 = dq[1] & 0xFF

        a0 = (wr - dint0) & (ABUF - 1)
        b0 = (a0 - 1) & (ABUF - 1)
        a1 = (wr - dint1) & (ABUF - 1)
        b1 = (a1 - 1) & (ABUF - 1)

        ip0 = mem_l[a0] + (((mem_l[b0] - mem_l[a0]) * frac0) >> 8)
        ip1 = mem_r[a1] + (((mem_r[b1] - mem_r[a1]) * frac1) >> 8)

        ol[i] = soft_lim((x[i] * GD_Q8 + ip0 * GW_Q8) >> 8)
        orr[i] = soft_lim((x[i] * GD_Q8 + ip1 * GW_Q8) >> 8)

        mem_l[wr] = x[i]
        mem_r[wr] = x[i]
        wr = (wr + 1) & (ABUF - 1)
        ph = (ph + LFO_STEP) & 0xFFFFFFFF
    return ol, orr


# ─────────────────── 浮点理想参考（同一干湿增益） ───────────────────
def run_float(x):
    import numpy as np
    n = len(x)
    xn = np.asarray(x, dtype=np.float64)
    t = np.arange(n) / FS
    out = []
    for phase in (0.0, math.pi / 2):
        d = (12.0 + 3.5 * np.sin(2 * np.pi * 0.6 * t + phase)) * FS / 1000.0
        idx = np.arange(n) - d
        i0 = np.floor(idx).astype(np.int64)
        fr = idx - i0
        wet = np.zeros(n)
        ok = (i0 >= 0) & (i0 + 1 < n)
        wet[ok] = (1 - fr[ok]) * xn[i0[ok]] + fr[ok] * xn[i0[ok] + 1]
        acc = (xn * GD_Q8 + wet * GW_Q8) / 256.0
        out.append([soft_lim(int(round(v))) for v in acc])
    return out[0], out[1]


def write_wav16(path, l, r, fs=48828):
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(fs)
        blob = bytearray()
        for a, b in zip(l, r):
            blob += struct.pack('<hh', max(-32768, min(32767, int(a))),
                                max(-32768, min(32767, int(b))))
        w.writeframes(bytes(blob))


def main():
    os.makedirs(OUTDIR, exist_ok=True)

    #  素材：复用 fx_sim 的乐句（C4-E4-G4-C5 琶音 + C 大三和弦，6 s）
    raw = fx_sim.build_phrase()
    pk = max(abs(v) for v in raw) or 1.0
    #  归一化到 −2 dBFS（与钢琴引擎的最大输出同量级）
    scale = 0.79 * 32767 / pk
    x = [int(round(v * scale)) for v in raw]
    n = len(x)
    print(f"素材 {n} 样点 = {n/FS:.2f} s，峰值 {max(abs(v) for v in x)}")

    print("生成 0_dry ...")
    write_wav16(os.path.join(OUTDIR, '0_dry.wav'), x, x)

    print("生成 1_float（精确浮点正弦）...")
    l, r = run_float(x)
    write_wav16(os.path.join(OUTDIR, '1_float.wav'), l, r)

    print("生成 2_fixed_nointerp（查表不插值 = 有滋滋声那版）...")
    l, r = run_fixed(x, sin_lut_nofix)
    write_wav16(os.path.join(OUTDIR, '2_fixed_nointerp.wav'), l, r)

    print("生成 3_fixed_interp（查表 + 12 位插值 = 现在上板这版）...")
    l, r = run_fixed(x, sin_lut_interp)
    write_wav16(os.path.join(OUTDIR, '3_fixed_interp.wav'), l, r)

    print(f"\n完成，文件在 {OUTDIR}")
    for f in sorted(os.listdir(OUTDIR)):
        p = os.path.join(OUTDIR, f)
        print(f"  {f}  {os.path.getsize(p)/1024:.0f} KB")
    return 0


if __name__ == '__main__':
    sys.exit(main())
