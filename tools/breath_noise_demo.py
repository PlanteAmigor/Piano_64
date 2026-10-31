#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
breath_noise_demo.py —— 笛子「气声噪声」可行性验证 + 压缩版/全质量版对比

## 背景：残差在哪

谐波模型 s(t)=Σ env_m·A_m·sin(Θ_m) 只能表达「有周期的部分」。
笛膜蜂鸣 + 气流噪声是随机的，模型没有这一项，
所以残差全部堆在 8~20 kHz（实测该段 SNR 只有 4~7 dB）。

## 本脚本回答两个问题

① 换成「全质量表」（NT2=1200/NT3=600，存储 ×7.3）能补上那部分残差吗？
② 如果不能，用「LFSR + 一阶带通 + 包络」这套 FPGA 便宜结构能补多少？

## 为什么不用「全带 SNR」评价噪声

残差是某个具体的噪声实现，换一个实现就是完全不相关，
所以加噪声**一定**让全带 SNR 变差。正确的指标是
**分频段能量匹配**（1/3 倍频程电平差），以及听感。

用法：
    cd /mnt/project/InstruementSound
    .venv/bin/python piano64_3/tools/breath_noise_demo.py
"""
import glob
import os

import numpy as np

FS = 48828.125
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # InstruementSound/
OUTD = os.path.join(ROOT, ".tmp", "breath")

# 1/3 倍频程中心频率
TRI = [630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000,
       6300, 8000, 10000, 12500, 16000, 20000]


# ══════════════════════════════════════════════════════════════════
#  FPGA 风格的噪声源（一阶 HP + 一阶 LP 级联 = 带通，无条件稳定）
# ══════════════════════════════════════════════════════════════════
def lfsr_noise(n, seed=0xACE1):
    """16 位 Galois LFSR → ±1 白噪声。RTL：16 位移位寄存器 + 1 个异或。"""
    reg = seed
    out = np.empty(n)
    for i in range(n):
        b = ((reg >> 0) ^ (reg >> 2) ^ (reg >> 3) ^ (reg >> 5)) & 1
        reg = ((reg >> 1) | (b << 15)) & 0xFFFF
        out[i] = 1.0 if (reg & 1) else -1.0
    return out


def one_pole_lp(x, fc):
    """一阶低通 y[n] = y[n-1] + a·(x[n] − y[n-1])，a = 1 − e^(−2π fc/fs)"""
    a = 1.0 - np.exp(-2.0 * np.pi * fc / FS)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += a * (v - acc)
        y[i] = acc
    return y


def one_pole_hp(x, fc):
    """一阶高通 y[n] = a·(y[n-1] + x[n] − x[n-1])"""
    a = np.exp(-2.0 * np.pi * fc / FS)
    y = np.empty_like(x)
    xp = 0.0
    yp = 0.0
    for i, v in enumerate(x):
        yp = a * (yp + v - xp)
        xp = v
        y[i] = yp
    return y


def synth_breath(n, env, fc_lo=6000.0, fc_hi=18000.0, seed=0xACE1):
    """LFSR → HP(6k) → LP(18k) → × 包络，归一化到峰值 1"""
    w = lfsr_noise(n, seed)
    y = one_pole_hp(w, fc_lo)
    y = one_pole_lp(y, fc_hi)
    y = y * env
    pk = np.abs(y).max()
    return y / pk if pk > 0 else y


# ══════════════════════════════════════════════════════════════════
#  分析工具
# ══════════════════════════════════════════════════════════════════
def band_rms(y, lo, hi):
    Y = np.fft.rfft(y)
    f = np.fft.rfftfreq(len(y), 1.0 / FS)
    Y[(f < lo) | (f > hi)] = 0.0
    return float(np.sqrt((np.fft.irfft(Y, len(y)) ** 2).mean()))


def tri_levels(y):
    """1/3 倍频程电平，dB"""
    out = []
    for i, fc in enumerate(TRI):
        lo = fc / 1.122
        hi = fc * 1.122
        out.append(20 * np.log10(band_rms(y, lo, hi) + 1e-12))
    return np.array(out)


def snr_db(ref, est):
    n = min(len(ref), len(est))
    e = ref[:n] - est[:n]
    return 20 * np.log10(np.sqrt((ref[:n] ** 2).mean()) / (np.sqrt((e ** 2).mean()) + 1e-12))


def load(mi, full=False):
    d = "谐波_全质量" if full else "谐波"
    g = glob.glob(os.path.join(ROOT, f"out/dizi/{d}/harm_DiZi_M{mi:03d}_H*S0.npz"))
    return np.load(g[0]) if g else None


def save_wav(path, y, peak=0.85):
    try:
        import soundfile as sf
    except ImportError:
        return False
    m = np.abs(y).max()
    sf.write(path, (y / m * peak if m > 0 else y).astype(np.float32), int(FS))
    return True


# ══════════════════════════════════════════════════════════════════
def main():
    os.makedirs(OUTD, exist_ok=True)

    # ── ① 压缩版 vs 全质量版 ─────────────────────────────────────
    print("=" * 78)
    print("① 压缩版（NT2=300 / NT3=150，弯曲时间轴） vs 全质量版（1200 / 600，均匀）")
    print("=" * 78)
    print("%-6s %10s %10s %8s %14s %14s"
          % ("MIDI", "压缩SNR", "全质量SNR", "提升", "压缩 8-20k残差", "全质量 8-20k残差"))
    rows = []
    for mi in (67, 71, 76, 79, 85, 91):
        dc, df = load(mi), load(mi, True)
        if dc is None or df is None:
            continue
        x = dc["x"].astype(float)
        rc = x - dc["xh"].astype(float)
        rf = df["x"].astype(float) - df["xh"].astype(float)
        sc = snr_db(x, dc["xh"].astype(float))
        sf_ = snr_db(x, df["xh"].astype(float))
        bc = 20 * np.log10(band_rms(rc, 8000, 20000)
                           / (band_rms(x, 8000, 20000) + 1e-12) + 1e-12)
        bf = 20 * np.log10(band_rms(rf, 8000, 20000)
                           / (band_rms(x, 8000, 20000) + 1e-12) + 1e-12)
        rows.append((mi, sc, sf_, bc, bf))
        print("%-6d %8.2f dB %8.2f dB %+7.2f %11.1f dB %11.1f dB"
              % (mi, sc, sf_, sf_ - sc, bc, bf))
    A = np.array(rows)
    print()
    print("  全带 SNR 平均提升        %+.2f dB" % (A[:, 2] - A[:, 1]).mean())
    print("  8~20 kHz 残差平均改善    %+.2f dB" % (A[:, 4] - A[:, 3]).mean())

    # ── ② 残差分频段 ─────────────────────────────────────────────
    print()
    print("=" * 78)
    print("② 残差分频段（note 67 G4，压缩版）")
    print("=" * 78)
    d = load(67)
    x = d["x"].astype(float)
    xh = d["xh"].astype(float)
    r = x - xh
    print("%-14s %10s %10s %10s" % ("频段", "信号RMS", "残差RMS", "残差/信号"))
    for lo, hi in ((300, 1000), (1000, 3000), (3000, 5000),
                   (5000, 8000), (8000, 12000), (12000, 20000)):
        s, rr = band_rms(x, lo, hi), band_rms(r, lo, hi)
        print("%-14s %10.4f %10.4f %9.1f dB"
              % ("%d-%d" % (lo, hi), s, rr, 20 * np.log10(rr / s + 1e-12)))
    print("  → 0.3~8 kHz 只差 −15 ~ −28 dB（模型很准）")
    print("  → 8~20 kHz 只差 −4 ~ −7 dB（模型基本无能 = 笛膜/气声）")

    # ── ③ 补噪声 ─────────────────────────────────────────────────
    print()
    print("=" * 78)
    print("③ 用 FPGA 便宜结构补气声：LFSR → HP(6k) → LP(18k) → × 包络")
    print("=" * 78)

    env = np.convolve(np.abs(xh), np.ones(1000) / 1000, mode="same")
    env = env / (env.max() + 1e-12)

    target = band_rms(r, 8000, 20000)
    print("  目标：8~20 kHz 需补 RMS %.4f（原带内 %.4f）"
          % (target, band_rms(x, 8000, 20000)))

    lv_ref = tri_levels(x)
    lv_mod = tri_levels(xh)
    hi = slice(10, len(TRI))          # 从 8000 起
    e_mod = float(np.abs(lv_mod[hi] - lv_ref[hi]).mean())
    print("  合成噪声前：8 kHz 以上 1/3oct 平均电平误差 %.2f dB" % e_mod)

    # 扫滤波器拐点，选 8k 以上 1/3oct 误差最小的（前面那组 6k/18k 在 16~20k 补过头了）
    best = None
    for fc_lo in (5000, 6000, 7000, 8000):
        for fc_hi in (10000, 12000, 14000, 16000):
            yn = synth_breath(len(x), env, fc_lo, fc_hi)
            yn *= target / (band_rms(yn, 8000, 20000) + 1e-12)
            lv = tri_levels(xh + yn)
            e = float(np.abs(lv[hi] - lv_ref[hi]).mean())
            if best is None or e < best[0]:
                best = (e, fc_lo, fc_hi, yn)
    e_add, fc_lo, fc_hi, yn = best
    print("  扫拐点 → 最佳 HP=%d Hz / LP=%d Hz" % (fc_lo, fc_hi))
    print("  补噪声后：8 kHz 以上 1/3oct 平均电平误差 %.2f dB（改善 %.2f dB）"
          % (e_add, e_mod - e_add))

    lv_add = tri_levels(xh + yn)
    print()
    print("  %-9s %9s %9s %11s" % ("1/3oct", "原音", "模型", "模型+气声"))
    for i, fc in enumerate(TRI):
        if fc < 3150:
            continue
        mark = "← 补上" if abs(lv_add[i] - lv_ref[i]) < abs(lv_mod[i] - lv_ref[i]) - 0.5 else ""
        print("  %-9d %8.1f  %8.1f  %10.1f   %s"
              % (fc, lv_ref[i], lv_mod[i], lv_add[i], mark))
    print("  （全带 SNR 会下降：噪声是随机实现，不相关就算误差。")
    print("    听感看的是「有没有气」，不是 SNR。）")

    # ── ④ 导出 ───────────────────────────────────────────────────
    print()
    print("=" * 78)
    print("④ 试听对比 →  %s/" % OUTD)
    print("=" * 78)
    df = load(67, True)
    xf = df["xh"].astype(float) if df is not None else None
    files = [("1_原音.wav", x), ("2_模型_压缩.wav", xh),
             ("3_模型加气声.wav", xh + yn),
             ("4_纯残差_真气声.wav", r), ("5_合成噪声.wav", yn)]
    if xf is not None:
        files.append(("6_模型_全质量.wav", xf))
        files.append(("7_全质量加气声.wav", xf + yn))
    ok = all(save_wav(os.path.join(OUTD, n_), y) for n_, y in files)
    if ok:
        for n_, _ in files:
            print("    " + n_)
        print("  ★ 听 1 / 2 / 6：2(压缩) vs 6(全质量) 差多少？——这是「值不值 ×7.3 存储」的判据")
        print("  ★ 听 2 / 3：加气声后是否更接近 1")
        print("  ★ 听 4 / 5：真残差 vs 合成噪声，音色是否类似")
    else:
        print("  (缺 soundfile；用 .venv/bin/python 跑)")

    # ── ⑤ 成本 ───────────────────────────────────────────────────
    print()
    print("=" * 78)
    print("⑤ FPGA 实现成本")
    print("=" * 78)
    print("  LFSR 16 位 Galois       16 FF + 2 LUT（3 输入异或）")
    print("  一阶 HP（乘常量 a）      1 DSP，或用移位加法近似")
    print("  一阶 LP（乘常量 b）      1 DSP")
    print("  包络                     直接复用引擎已有 env 表（不加资源）")
    print("  定标 + 相加              1 乘 1 加")
    print("  ──────────────────────────────────────────────")
    print("  合计 ≈ 20 FF + 2~3 DSP + 少量 LUT（<0.05%），BSRAM 0")
    print("  新参数只有「噪声电平」1 个")

    # ── ⑥ 全质量版的代价 ────────────────────────────────────────
    print()
    print("=" * 78)
    print("⑥ 换全质量表要付多少代价（按音预取架构下，只算单音缓冲）")
    print("=" * 78)
    K, npsi = 62, 20            # 笛子最坏音 G4
    print("  笛子最坏音 G4：K=62, npsi=20")
    print("  %-24s %14s %14s %10s" % ("", "压缩(300/150)", "全质量(1200/600)", "增量"))
    rows2 = [
        ("psi_e 缓冲(词)", (npsi + 1) * 151, (npsi + 1) * 601),
        ("env_e 缓冲(词)", K * 76, K * 301),
    ]
    for n_, a_, b_ in rows2:
        print("  %-24s %14d %14d %10s" % (n_, a_, b_, "×%.1f" % (b_ / a_)))
    def blocks(words, wd):
        return int(np.ceil(words * wd / 18432))
    cur = blocks(4096, 16) * 2 + blocks(8192, 8) * 2
    new = blocks((npsi + 1) * 601, 16) * 2 + blocks(K * 301, 8) * 2
    print("  %-24s %14d %14d %10s" % ("BSRAM 块", cur, new, "+%d" % (new - cur)))
    print("  %-24s %14s %14s %10s" % ("总 BSRAM", "202/340 (60%)",
                                      "%d/340 (%.0f%%)" % (202 + new - cur, 100 * (202 + new - cur) / 340), ""))
    print("  %-24s %14s %14s %10s" % ("单音表(DDR)", "24.5 KB", "178.2 KB", "×7.3"))
    print("  %-24s %14s %14s %10s" % ("镜像总大小", "1.10 MB", "~5.15 MB", "×4.7"))
    print("  %-24s %14s %14s %10s" % ("MAX_BYTES", "1,280,000", "需抬到 ~6,000,000", ""))
    print("  ──────────────────────────────────────────")
    print("  还要改：psi 地址 12 位→16 位、env 地址 13 位→15 位；SD 加载时间 ×4.7")


if __name__ == "__main__":
    main()
