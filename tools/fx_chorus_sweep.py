#!/usr/bin/env python3
"""
fx_chorus_sweep.py —— 扫描 CHORUS 的深度 / 湿声量，出多版 WAV 供人耳挑选

为什么需要扫参数
----------------
修正 LFO 正弦插值后，延迟变成【连续调制】，这才是真合唱，
但湿声被持续移调：

    Δ = 2π · D · f           （D = 调制深度[秒]，f = LFO 频率[Hz]）
    音分 = 1200 · log2(1 + Δ)

    D=3.5ms, f=0.6Hz → Δ=1.32% → 22.7 音分   ← 现在的参数，太"飘"
    D=2.0ms          → 13.0 音分
    D=1.2ms          →  7.8 音分             ← 典型合唱单元的量级

之前那版有滋滋声的定点实现，延迟是【阶梯状、大部分时间恒定】，
湿声等于固定延迟复制 → 听感像"加厚双轨"，不飘，所以反而更讨喜。
但那本身是缺陷（每 6.5 ms 跳 4.19 个样本）。

输出（out/fx_sweep/）
--------------------
  0_dry.wav            干声
  1_ideal.wav          浮点理想（当前参数 D=3.5ms，作为标尺）
  v1_d35_w100.wav      D=3.5ms  湿=干        （现在上板这版）
  v2_d20_w100.wav      D=2.0ms  湿=干
  v3_d12_w100.wav      D=1.2ms  湿=干
  v4_d20_w60.wav       D=2.0ms  湿=0.6×干
  v5_d35_w60.wav       D=3.5ms  湿=0.6×干
  v6_d12_w60.wav       D=1.2ms  湿=0.6×干

用法
----
  source /mnt/project/InstruementSound/.venv/bin/activate
  python tools/fx_chorus_sweep.py
"""
import os
import sys
import math
import wave
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import fx_sim

FS         = 48828.125
ABUF       = 1024
BASE_MS    = 12.0
RATE       = 0.6
LFO_STEP   = 52777
GD_Q8      = 149                 # 干声 0.582（所有版本固定）
PH_QUARTER = 0x4000_0000

OUTDIR = os.path.join(ROOT, 'out', 'fx_sweep')

SIN_Q = [round(32767 * math.sin(2 * math.pi * j / 256)) for j in range(65)]


def sin_lut_interp(p):
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


def run_fixed(x, depth_ms, gw_q8):
    """与 RTL 逐位等价的定点流水线，深度与湿声增益可调"""
    base_q8  = int(round(BASE_MS  * FS / 1000.0 * 256))
    depth_q8 = int(round(depth_ms * FS / 1000.0 * 256))
    n = len(x)
    mem_l = [0] * ABUF
    mem_r = [0] * ABUF
    wr = 0
    ph = 0
    ol = [0] * n
    orr = [0] * n
    for i in range(n):
        d0 = base_q8 + ((depth_q8 * sin_lut_interp(ph)) >> 15)
        d1 = base_q8 + ((depth_q8 * sin_lut_interp((ph + PH_QUARTER) & 0xFFFFFFFF)) >> 15)
        int0, fr0 = (d0 >> 8) & 0x3FF, d0 & 0xFF
        int1, fr1 = (d1 >> 8) & 0x3FF, d1 & 0xFF
        a0 = (wr - int0) & (ABUF - 1)
        b0 = (a0 - 1) & (ABUF - 1)
        a1 = (wr - int1) & (ABUF - 1)
        b1 = (a1 - 1) & (ABUF - 1)
        ip0 = mem_l[a0] + (((mem_l[b0] - mem_l[a0]) * fr0) >> 8)
        ip1 = mem_r[a1] + (((mem_r[b1] - mem_r[a1]) * fr1) >> 8)
        ol[i]  = soft_lim((x[i] * GD_Q8 + ip0 * gw_q8) >> 8)
        orr[i] = soft_lim((x[i] * GD_Q8 + ip1 * gw_q8) >> 8)
        mem_l[wr] = x[i]
        mem_r[wr] = x[i]
        wr = (wr + 1) & (ABUF - 1)
        ph = (ph + LFO_STEP) & 0xFFFFFFFF
    return ol, orr


def run_float(x):
    import numpy as np
    n = len(x)
    xn = np.asarray(x, dtype=np.float64)
    t = np.arange(n) / FS
    outs = []
    for phase in (0.0, math.pi / 2):
        d = (BASE_MS + 3.5 * np.sin(2 * np.pi * RATE * t + phase)) * FS / 1000.0
        idx = np.arange(n) - d
        i0 = np.floor(idx).astype(np.int64)
        fr = idx - i0
        wet = np.zeros(n)
        ok = (i0 >= 0) & (i0 + 1 < n)
        wet[ok] = (1 - fr[ok]) * xn[i0[ok]] + fr[ok] * xn[i0[ok] + 1]
        acc = (xn * GD_Q8 + wet * 149) / 256.0
        outs.append([soft_lim(int(round(v))) for v in acc])
    return outs[0], outs[1]


def write_wav16(path, l, r):
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48828)
        blob = bytearray()
        for a, b in zip(l, r):
            blob += struct.pack('<hh',
                                max(-32768, min(32767, int(a))),
                                max(-32768, min(32767, int(b))))
        w.writeframes(bytes(blob))


def cents(depth_ms, rate=RATE):
    delta = 2 * math.pi * (depth_ms / 1000.0) * rate
    return 1200 * math.log2(1 + delta)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    raw = fx_sim.build_phrase()
    pk = max(abs(v) for v in raw) or 1.0
    x = [int(round(v * 0.79 * 32767 / pk)) for v in raw]
    print(f"素材 {len(x)} 样点 = {len(x)/FS:.2f} s\n")

    write_wav16(os.path.join(OUTDIR, '0_dry.wav'), x, x)

    print("1_ideal（浮点理想，D=3.5ms 湿=干）...")
    l, r = run_float(x)
    write_wav16(os.path.join(OUTDIR, '1_ideal.wav'), l, r)

    #  (文件名, 深度 ms, 湿声 Q8, 说明)
    cases = [
        ('v1_d35_w100.wav', 3.5, 149, 'D=3.5ms 湿=干   （现在上板这版）'),
        ('v2_d20_w100.wav', 2.0, 149, 'D=2.0ms 湿=干'),
        ('v3_d12_w100.wav', 1.2, 149, 'D=1.2ms 湿=干'),
        ('v4_d20_w60.wav',  2.0,  90, 'D=2.0ms 湿=0.6×干'),
        ('v5_d35_w60.wav',  3.5,  90, 'D=3.5ms 湿=0.6×干'),
        ('v6_d12_w60.wav',  1.2,  90, 'D=1.2ms 湿=0.6×干'),
    ]

    print()
    for fn, dms, gw, desc in cases:
        print(f"{fn}   {desc}   移调 {cents(dms):5.1f} 音分 ...")
        l, r = run_fixed(x, dms, gw)
        write_wav16(os.path.join(OUTDIR, fn), l, r)

    print(f"\n完成，文件在 {OUTDIR}")
    print("\n移调深度对照（越大越飘）：")
    for dms in (3.5, 2.0, 1.2, 0.6):
        print(f"  深度 {dms:3.1f} ms @ 0.6 Hz  →  {cents(dms):5.1f} 音分")
    return 0


if __name__ == '__main__':
    sys.exit(main())
