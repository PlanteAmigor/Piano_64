#!/usr/bin/env python3
"""
fx_chorus_range.py —— 把 CHORUS 从「纯加厚」到「强合唱」整个范围一次摊开

背景（三版试听后收敛到的认识）
------------------------------
上板试听三版：
  ① 正弦查表不插值   → "其他都好，就是有一些滋滋声"
  ② 插值 + 深度 3.5ms → "效果更差，音质更坏"
  ③ 插值 + 深度 2.0ms → "不如第一版；音色坏、都很吵、笛子音乱跳"

关键认识：① 之所以"其他都好"，是因为它的延迟【大部分时间是恒定的】
（阶梯状，每 6.5 ms 跳 4.19 个样本）。恒定的湿声 == 固定延迟复制品，
听感是"加厚/双轨"，没有音高摆动，所以讨喜；代价是跳跃处的滋滋。

② ③ 修好插值后延迟变成【连续调制】，这才是真合唱，但湿声被持续移调：

    音分 = 1200 · log2(1 + 2π·D·f)

    3.5 ms @ 0.6 Hz → 22.7 音分   人耳等同"跑调"
    2.0 ms @ 0.6 Hz → 13.0 音分   仍明显"抖"
    1.0 ms @ 0.15Hz →  1.6 音分   几乎听不出移调，只剩缓慢的梳状漂移

所以"抖不抖"由两个参数决定：深度 D 和 LFO 频率 f。降 f 比降 D 更有效
（音分与 f 成正比），而且 f 低到 0.1~0.2 Hz 时"抖"变成"缓慢流动"，
听感舒服得多。

输出（out/fx_range/）
--------------------
  0_dry.wav              干声
  1_chorus_strong.wav    D=3.5ms 0.60Hz 湿=1.0   22.7音分（对照，就是②）
  a1_ch_slow.wav         D=2.0ms 0.15Hz 湿=0.7    3.3音分  缓慢合唱
  a2_ch_veryfine.wav     D=1.0ms 0.15Hz 湿=0.7    1.6音分  极轻流动
  a3_ch_fast_low.wav     D=1.0ms 0.30Hz 湿=0.5    3.3音分  轻量
  a4_ch_tiny.wav         D=0.5ms 0.30Hz 湿=0.7    1.6音分  几乎不抖
  b1_dbl_08.wav          D=0    0.15Hz 湿=0.7    左右延迟 12.0/12.8ms 纯加厚
  b2_dbl_20.wav          D=0    0.15Hz 湿=0.7    左右延迟 12.0/14.0ms 更宽加厚
  c1_lowgain.wav         D=2.0ms 0.15Hz 低总增益（测软限幅是否在捣鬼）

用法
----
  source /mnt/project/InstruementSound/.venv/bin/activate
  python tools/fx_chorus_range.py
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
BASE_Q8    = 150000          # 12.0 ms
PH_QUARTER = 0x4000_0000

OUTDIR = os.path.join(ROOT, 'out', 'fx_range')

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


def run(x, depth_ms, rate_hz, gd_q8, gw_q8, roff_ms=0.0):
    """与 RTL 同构的定点流水线；roff_ms 是右声道额外的固定延迟"""
    depth_q8 = int(round(depth_ms * FS / 1000.0 * 256))
    roff_q8  = int(round(roff_ms  * FS / 1000.0 * 256))
    step     = int(round(rate_hz * 4294967296.0 / FS)) & 0xFFFFFFFF
    n = len(x)
    mem_l = [0] * ABUF
    mem_r = [0] * ABUF
    wr = 0
    ph = 0
    ol = [0] * n
    orr = [0] * n
    for i in range(n):
        d0 = BASE_Q8 + ((depth_q8 * sin_lut_interp(ph)) >> 15) if depth_q8 else BASE_Q8
        d1 = BASE_Q8 + roff_q8
        if depth_q8:
            d1 += (depth_q8 * sin_lut_interp((ph + PH_QUARTER) & 0xFFFFFFFF)) >> 15
        int0, fr0 = (d0 >> 8) & 0x3FF, d0 & 0xFF
        int1, fr1 = (d1 >> 8) & 0x3FF, d1 & 0xFF
        a0 = (wr - int0) & (ABUF - 1)
        b0 = (a0 - 1) & (ABUF - 1)
        a1 = (wr - int1) & (ABUF - 1)
        b1 = (a1 - 1) & (ABUF - 1)
        ip0 = mem_l[a0] + (((mem_l[b0] - mem_l[a0]) * fr0) >> 8)
        ip1 = mem_r[a1] + (((mem_r[b1] - mem_r[a1]) * fr1) >> 8)
        ol[i]  = soft_lim((x[i] * gd_q8 + ip0 * gw_q8) >> 8)
        orr[i] = soft_lim((x[i] * gd_q8 + ip1 * gw_q8) >> 8)
        mem_l[wr] = x[i]
        mem_r[wr] = x[i]
        wr = (wr + 1) & (ABUF - 1)
        ph = (ph + step) & 0xFFFFFFFF
    return ol, orr


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


def cents(depth_ms, rate_hz):
    if depth_ms <= 0:
        return 0.0
    return 1200 * math.log2(1 + 2 * math.pi * (depth_ms / 1000.0) * rate_hz)


CASES = [
    #  文件名,                     深度ms, 频率Hz, 干Q8, 湿Q8, 右声道额外延迟ms, 说明
    ('1_chorus_strong.wav',        3.5,   0.60, 149, 149, 0.0, '对照：就是现在这版（22.7音分）'),
    ('a1_ch_slow.wav',             2.0,   0.15, 149, 105, 0.0, '缓慢合唱（3.3音分）'),
    ('a2_ch_veryfine.wav',         1.0,   0.15, 149, 105, 0.0, '极轻流动（1.6音分）'),
    ('a3_ch_fast_low.wav',         1.0,   0.30, 149,  75, 0.0, '轻量、湿声少（3.3音分）'),
    ('a4_ch_tiny.wav',             0.5,   0.30, 149, 105, 0.0, '几乎不抖（1.6音分）'),
    ('b1_dbl_08.wav',              0.0,   0.15, 149, 105, 0.8, '纯加厚：左右 12.0/12.8ms，零调制'),
    ('b2_dbl_20.wav',              0.0,   0.15, 149, 105, 2.0, '更宽加厚：左右 12.0/14.0ms，零调制'),
    ('c1_lowgain.wav',             2.0,   0.15, 125,  90, 0.0, '同 a1 但总增益低（查软限幅）'),
]


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    raw = fx_sim.build_phrase()
    pk = max(abs(v) for v in raw) or 1.0
    x = [int(round(v * 0.79 * 32767 / pk)) for v in raw]
    write_wav16(os.path.join(OUTDIR, '0_dry.wav'), x, x)
    print(f"素材 {len(x)} 样点 = {len(x)/FS:.2f} s\n")

    for fn, dms, rate, gd, gw, roff, desc in CASES:
        c = cents(dms, rate)
        print(f"{fn:24s} {desc:38s} 移调 {c:5.1f} 音分 ...")
        l, r = run(x, dms, rate, gd, gw, roff)
        write_wav16(os.path.join(OUTDIR, fn), l, r)

    print(f"\n完成，文件在 {OUTDIR}")
    print("\n移调音分对照（同一深度下，降 LFO 频率比降深度更有效）：")
    for dms in (3.5, 2.0, 1.0, 0.5):
        row = "  ".join(f"{r:4.2f}Hz→{cents(dms, r):5.1f}" for r in (0.6, 0.3, 0.15))
        print(f"  深度 {dms:3.1f} ms:  {row}  音分")
    return 0


if __name__ == '__main__':
    sys.exit(main())
