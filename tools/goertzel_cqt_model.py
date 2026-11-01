#!/usr/bin/env python3
"""
goertzel_cqt_model.py —— 32 段变窗长常数-Q 频谱分析模型

════════ 为什么必须变窗长 ════════
时频不确定性 Δf·T ≥ 1：
    最窄的 40 Hz 段带宽 ≈ 8.5 Hz  → T ≥ 117 ms → N ≈ 5700 点
    最高的 16 kHz 段带宽 ≈ 2800 Hz → N ≈ 17 点
相差 336 倍。FFT / 滑动 DFT 的 N 是全局的，做不到；
本方案每段窗长独立，内存恒为 2 个字（无延迟线）。

    ┌──────────── 关键对比 ────────────┐
    32 段一起做滑动 DFT：延迟线 ΣN = 32511 点 = 65 KB → 4 块 BSRAM
    本方案：0 块 BSRAM，状态 32×2×32 bit ≈ 2 Kb
    └──────────────────────────────────┘

════════ 为什么不用实 Goertzel ════════
实 Goertzel 递推 s[n] = x[n] + 2cos(ω)·s[n-1] − s[n-2]
中间状态峰值 ≈ A·N / (2·sinω)，低频会放大 1/(2 sinω) 倍：
    40 Hz   → 97 倍  → 满幅 17.5e9，32 位溢出 813%
    16 kHz  → 0.57 倍
差 170 倍，同一个位宽装不下。

改为【复单极点谐振器】，状态增长恒为 A·N/2，与频率无关：
    X[n] = x[n]·w[n] + e^{−jω}·X[n−1]        （每段一个，块尾清零）
    代价：4 次实数乘法（vs 1 次），32 段 = 128 次/采样，
          占 1024 拍的 12.5%，完全可接受。
    好处：状态位宽统一，且能直接加窗（w[n] 就是一路乘）。

    ★ 数学上这不是"Goertzel"，但本质相同（都是单点 DFT 的递推形式）；
      严格说实 Goertzel 就是这个复谐振器把两个共轭极点合并后的结果。

本文验证：
    ① 32 段对数频点对 8 个八度 C 的响应（= 测试模式音源）
    ② 单音扫频：每个 C 是否落到最近的段
    ③ 低频分辨力：40/50/63/79 Hz（对照 1024 点 FFT）
    ④ 加窗 vs 不加窗 的频谱泄漏
    ⑤ 定点精度与状态溢出余量
"""

import numpy as np

FS = 48828.125
F_LO, F_HI = 40.0, 16000.0
NBAND = 32

RATIO = (F_HI / F_LO) ** (1.0 / (NBAND - 1))
FC = F_LO * RATIO ** np.arange(NBAND)

# ── 窗长倍数 ────────────────────────────────────────────────
#  1×：主瓣宽 = 相邻带宽，但 Hann 主瓣本就是 4 bin → 邻段只差 −4.6 dB（不能用）
#  2×：邻段 −15.5 dB，隔一段 −45.6 dB  ← 甜点
#  4×：邻段 −46.5 dB，但段 0 窗长 469 ms（2.1 fps）太慢
#  注意只有【最低几段】慢：段 12(407Hz)=23ms(43fps)、段 20(1.9k)=4.9ms
N_MULT = 2
NB = np.maximum(np.round(FS / (FC * (RATIO - 1.0))).astype(int) * N_MULT, 12)
WIN = "hann"          # "hann" 或 "rect"


def q31(v):
    return max(-2**31, min(2**31 - 1, int(round(v * 2**31))))


# ══════════════════════════════════════════════════════════════
#  复单极点谐振器（浮点参考）
# ══════════════════════════════════════════════════════════════
def dft_float(x, f, n, win="hann"):
    w = np.hanning(n) if win == "hann" else np.ones(n)
    p = np.exp(-2j * np.pi * f / FS)
    acc = 0j
    for i in range(n):
        acc = x[i] * w[i] + p * acc
    return abs(acc)


# ══════════════════════════════════════════════════════════════
#  复单极点谐振器（定点，完全按 RTL 会怎么算）
#    e^{-jω} 存 Q1.31（|·|=1，恒不溢出）
#    X_re / X_im 存 32 位有符号
# ══════════════════════════════════════════════════════════════
def dft_fixed(xi, f, n, win="hann"):
    w = np.hanning(n) if win == "hann" else np.ones(n)
    AR = q31(np.cos(2 * np.pi * f / FS))       #  p.re
    AI = q31(-np.sin(2 * np.pi * f / FS))      #  p.im
    xr = xi_i = 0
    peak = 0
    for i in range(n):
        xv = int(round(int(xi[i]) * w[i]))
        # 先算新的 im（用旧的 xr），再算新的 re —— 与 RTL 的非阻塞赋值一致
        nr = (xr * AR - xi_i * AI) >> 31
        ni = (xr * AI + xi_i * AR) >> 31
        xr = xv + nr
        xi_i = ni
        peak = max(peak, abs(xr), abs(xi_i))
    return float(np.hypot(xr, xi_i)), peak


def to_bar(mags, ref=None):
    m = np.asarray(mags, float)
    r = ref if ref is not None else m.max()
    db = 20 * np.log10(m / (r + 1e-12) + 1e-12)
    return np.clip((db + 60) / 60 * 255, 0, 255).astype(int)


def chart(bars, title):
    print(f"\n【{title}】")
    for k in range(NBAND):
        if bars[k] < 3:
            continue
        print(f"  {k:>2} {FC[k]:>7.1f}Hz |{'#'*(bars[k]//6):<42}| {bars[k]:>3}")


def spectrum(x, fixed=True, win="hann"):
    xi = np.clip(np.round(x * 32767), -32768, 32767).astype(np.int64)
    mags = np.zeros(NBAND)
    peaks = np.zeros(NBAND, dtype=np.int64)
    for k in range(NBAND):
        n = min(NB[k], len(x))
        if fixed:
            mags[k], peaks[k] = dft_fixed(xi[-n:], FC[k], n, win)
        else:
            mags[k] = dft_float(x[-n:], FC[k], n, win)
    return mags, peaks


# ══════════════════════════════════════════════════════════════
print("=" * 78)
print(f"fs={FS} Hz   {F_LO}-{F_HI} Hz   {NBAND} 段   r={RATIO:.4f} "
      f"= 1/{1/np.log2(RATIO):.2f} 倍频程")
print("=" * 78)
print(f"{'段':>3} {'中心Hz':>9} {'带宽Hz':>8} {'N':>6} {'窗ms':>8} {'刷新fps':>8}")
for k in range(0, NBAND, 4):
    print(f"{k:>3} {FC[k]:>9.1f} {FC[k]*(RATIO-1):>8.1f} {NB[k]:>6} "
          f"{1000*NB[k]/FS:>8.2f} {FS/NB[k]:>8.1f}")
print(f"  SUM N_k = {NB.sum()} 点")

nmax = NB[0]
t = np.arange(nmax) / FS
OCTAVES = [261.6255653 * 2 ** (j - 4) for j in range(3, 11)]

# ══════════════════════════════════════════════════════════════
print("\n" + "=" * 78)
print("测试 1  8 路纯正弦 C3..C10（= 测试模式音源）")
print("=" * 78)
x8 = sum(np.sin(2 * np.pi * f * t) for f in OCTAVES) / 8
m_nw, _ = spectrum(x8, True, "rect")
m_w, pk_w = spectrum(x8, True, "hann")
chart(to_bar(m_nw), "不加窗（矩形）")
chart(to_bar(m_w), "加 Hann 窗")

# ══════════════════════════════════════════════════════════════
print("\n" + "=" * 78)
print("测试 2  单音扫频：每个 C 是否落到最近的段（加 Hann）")
print("=" * 78)
print(f"{'音':>4} {'频率Hz':>9} {'最近段':>6} {'段中心':>9} {'偏差':>7} "
      f"{'峰柱高':>6} {'次高':>5} {'泄漏dB':>8}")
for j, f0 in enumerate(OCTAVES):
    x = np.sin(2 * np.pi * f0 * t)
    m, _ = spectrum(x, True, "hann")
    b = to_bar(m)
    k = int(np.argmax(b))
    o = np.argsort(b)[::-1]
    sec = int(o[1])
    print(f"C{j+3:<3} {f0:>9.1f} {k:>6} {FC[k]:>9.1f} "
          f"{100*(f0/FC[k]-1):>+6.1f}% {b[k]:>6} {b[sec]:>5} "
          f"{20*np.log10(m[sec]/m[k]+1e-12):>8.1f}")

# ══════════════════════════════════════════════════════════════
print("\n" + "=" * 78)
print("测试 3  低频分辨力（本方案 vs 1024 点 FFT）")
print("=" * 78)


def fft_bands(x, nfft):
    X = np.abs(np.fft.rfft(x[:nfft] * np.hanning(nfft)))
    fr = np.fft.rfftfreq(nfft, 1 / FS)
    out = np.zeros(NBAND)
    for k in range(NBAND):
        sel = (fr > FC[k] / np.sqrt(RATIO)) & (fr < FC[k] * np.sqrt(RATIO))
        out[k] = X[sel].max() if sel.any() else 0
    return to_bar(out)


print(f"  {'输入':>7} | {'本方案 最亮3段':<30} | {'1024点FFT 最亮3段':<30}")
print("  " + "-" * 72)
for f0 in (40.0, 50.0, 63.0, 79.0):
    x = np.sin(2 * np.pi * f0 * t)
    bg = to_bar(spectrum(x, True, "hann")[0])
    bf = fft_bands(x, 1024)
    sg = " ".join(f"{k}({FC[k]:.0f})" for k in np.argsort(bg)[::-1][:3])
    sf = " ".join(f"{k}({FC[k]:.0f})" for k in np.argsort(bf)[::-1][:3])
    print(f"  {f0:>5.0f}Hz | {sg:<30} | {sf:<30}")

# ══════════════════════════════════════════════════════════════
print("\n" + "=" * 78)
print("测试 4/5  定点精度 与 状态溢出余量")
print("=" * 78)
a, b_ = to_bar(m_w).astype(float), to_bar(m_w).astype(float)
mf, _ = spectrum(x8, False, "hann")
print(f"  定点 vs 浮点：柱高最大差 {np.abs(to_bar(m_w)-to_bar(mf)).max():.0f}/255")
print(f"  8 音混合时状态峰值 {pk_w.max():>12,} = {100*pk_w.max()/2**31:>5.1f}%")

print("\n  最坏情况（满幅单音落在该段中心）：")
ok = True
for k in range(0, NBAND, 4):
    x = np.sin(2 * np.pi * FC[k] * t) * 0.999
    _, pk = spectrum(x, True, "hann")
    p = pk[k]
    ok &= p < 2**31
    print(f"    段{k:>2}({FC[k]:>7.1f}Hz) N={NB[k]:>5} -> 状态峰值 {p:>12,} "
          f"({100*p/2**31:>5.1f}%)  {'OK' if p < 2**31 else 'FAIL'}")
print(f"  => {'全部不溢出' if ok else '有溢出！'}")
print("=" * 78)
