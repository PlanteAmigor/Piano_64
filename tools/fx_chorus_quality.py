#!/usr/bin/env python3
"""
fx_chorus_quality.py —— 用客观指标判断哪个定点版本更接近浮点参考

背景：上板后用户反馈
    · 版本 B（LFO 正弦查表【不】插值）  → "其他都好，就是有一些滋滋声"
    · 版本 C（LFO 正弦查表【加】插值）  → "效果更差了，而且音质更坏了"
两个版本都与定点模型 bit-exact，所以只能靠客观指标判断。

做法
----
  A = 浮点理想参考（等价于 tools/fx_sim.py 的 chorus()，用户听过这个 WAV）
  B = 定点，正弦查表不插值（6 位下标直查）
  C = 定点，正弦查表 + 12 位线性插值
  D = 定点，正弦查表 + 12 位插值，但用一个【故意做错】的对照（可选）

  统一用 1 kHz 正弦作为输入 —— 有缺陷时会在频谱上露出离散杂散，
  比人耳判断可靠得多。

指标
----
  SNR(A→X)   = 20*log10( rms(A) / rms(X-A) )    越大越好
  152 Hz 分量 = LFO 阶梯在输出上留下的周期性杂散（对照 A 的同一位置）
"""
import sys
import math

# ── 与 RTL 同源的常数 ────────────────────────────────────────────────
FS        = 48828.125
ABUF      = 1024
BASE_Q8   = 150000
DEPTH_Q8  = 43750
LFO_STEP  = 52777
GD_Q8     = 149
GW_Q8     = 149
PH_QUARTER = 0x4000_0000

BASE_MS  = 12.0
DEPTH_MS = 3.5
RATE     = 0.6

SIN_Q = [round(32767 * math.sin(2 * math.pi * j / 256)) for j in range(65)]


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


def sin_of_fixed(p, interp, jf_bits):
    """定点正弦：interp=False 时只查表；True 时线性插值"""
    p &= 0xFFFFFFFF
    qd = p >> 30
    jx = (p >> 24) & 0x3F
    if qd & 1:
        ia = 64 - jx
        ib = 63 - jx
    else:
        ia = jx
        ib = jx + 1
    if not interp:
        return -SIN_Q[ia] if (qd & 2) else SIN_Q[ia]
    jf = (p >> (24 - jf_bits)) & ((1 << jf_bits) - 1)
    v = SIN_Q[ia] + (((SIN_Q[ib] - SIN_Q[ia]) * jf) >> jf_bits)
    return -v if (qd & 2) else v


# ────────────────────────────────────────────────────────────────────
#  A：浮点理想参考
# ────────────────────────────────────────────────────────────────────
def model_float(x):
    x = np.asarray(x, dtype=np.float64)
    n = len(x)
    d = (BASE_MS + DEPTH_MS * np.sin(2 * np.pi * RATE * np.arange(n) / FS)) * FS / 1000.0
    idx = np.arange(n) - d
    out = np.zeros(n)
    i0 = np.floor(idx).astype(np.int64)
    fr = idx - i0
    ok = (i0 >= 0) & (i0 + 1 < n)
    out[ok] = (1 - fr[ok]) * x[i0[ok]] + fr[ok] * x[i0[ok] + 1]
    return out


# ────────────────────────────────────────────────────────────────────
#  B / C：定点（与 RTL 同构）
# ────────────────────────────────────────────────────────────────────
def model_fixed(x, interp, jf_bits):
    n = len(x)
    mem = [0] * ABUF
    wr = 0
    ph = 0
    out = [0] * n
    for i in range(n):
        sv = sin_of_fixed(ph, interp, jf_bits)
        dq8 = BASE_Q8 + ((DEPTH_Q8 * sv) >> 15)
        dint = (dq8 >> 8) & 0x3FF
        frac = dq8 & 0xFF
        ada = (wr - dint) & (ABUF - 1)
        adb = (ada - 1) & (ABUF - 1)
        a = mem[ada]
        b = mem[adb]
        ip = a + (((b - a) * frac) >> 8)
        mx = (x[i] * GD_Q8 + ip * GW_Q8) >> 8
        out[i] = soft_lim(mx)
        mem[wr] = x[i]
        wr = (wr + 1) & (ABUF - 1)
        ph = (ph + LFO_STEP) & 0xFFFFFFFF
    return out


def snr(ref, sig):
    n = min(len(ref), len(sig))
    #  去掉前 900 个样点（延迟线未填满）
    ref = ref[900:n]
    sig = sig[900:n]
    e = [ref[i] - sig[i] for i in range(len(ref))]
    r = math.sqrt(sum(v * v for v in ref) / len(ref))
    q = math.sqrt(sum(v * v for v in e) / len(e))
    if q < 1e-9:
        return 99.0, r, q
    return 20 * math.log10(r / q), r, q


def goertzel_mag(sig, f, fs=FS):
    """单频点能量（不用 numpy，避免外部依赖）"""
    n = len(sig)
    w = 2 * math.pi * f / fs
    c = 2 * math.cos(w)
    s1 = s2 = 0.0
    for v in sig:
        s0 = v + c * s1 - s2
        s2 = s1
        s1 = s0
    return math.sqrt(s1 * s1 + s2 * s2 - c * s1 * s2) / n


def main():
    n = 20000                                   # ≈0.41 s
    #  输入：1 kHz 正弦，幅度 0.5 满幅（避免软限幅介入）
    amp = 0.5 * 32767
    x = [int(round(amp * math.sin(2 * math.pi * 1000 * i / FS))) for i in range(n)]

    A = model_float(x)
    B = model_fixed(x, interp=False, jf_bits=0)
    C = model_fixed(x, interp=True,  jf_bits=12)

    print("=" * 66)
    print("输入：1 kHz 正弦，幅度 0.5 满幅（不触发软限幅）")
    print(f"长度 {n} 样点，指标只统计后 {n-900} 点（延迟线已填满）")
    print("=" * 66)

    for name, sig in (("B  正弦查表【不】插值（→ 滋滋声的版本）", B),
                      ("C  正弦查表 + 12 位插值（→ 现在这版）", C)):
        s, r, q = snr(A, sig)
        print(f"\n{name}")
        print(f"  与浮点参考的 SNR : {s:7.2f} dB")
        print(f"  参考 RMS {r:8.1f}   误差 RMS {q:8.1f}")

    #  LFO 阶梯的指纹：0.6 Hz × 256 点 = 152.6 Hz 的调制率
    #  它会在输出上产生 1 kHz ± k*152.6 Hz 的边带
    print("\n--- 152.6 Hz 阶梯杂散（1 kHz 的 ±152.6 Hz 边带）---")
    for name, sig in (("A 浮点参考", A), ("B 不插值 ", B), ("C 有插值 ", C)):
        u = goertzel_mag(sig[900:], 1000 + 152.6)
        d = goertzel_mag(sig[900:], 1000 - 152.6)
        car = goertzel_mag(sig[900:], 1000)
        print(f"  {name}: 上边带 {20*math.log10(max(u,1e-9)/max(car,1e-9)):7.1f} dBc"
              f"   下边带 {20*math.log10(max(d,1e-9)/max(car,1e-9)):7.1f} dBc")

    print("\n--- 其它杂散（相对 1 kHz 载波）---")
    for name, sig in (("A 浮点参考", A), ("B 不插值 ", B), ("C 有插值 ", C)):
        parts = []
        for f in (2000, 3000, 305, 5000):
            parts.append(f"{f}Hz {20*math.log10(max(goertzel_mag(sig[900:], f),1e-9)/max(goertzel_mag(sig[900:],1000),1e-9)):6.1f}dBc")
        print(f"  {name}: " + "  ".join(parts))
    return 0


if __name__ == '__main__':
    try:
        import numpy as np
    except ImportError:
        print("需要 numpy")
        sys.exit(1)
    sys.exit(main())
