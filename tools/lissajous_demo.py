#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lissajous_demo.py —— 「李萨如图形」在乐器可视化里到底画什么？四方案对比图

输出：.tmp/lissajous/方案对比.png

四种画法：
  A  当前实现：X=Lout, Y=Rout           —— 因为 L==R，退化成一条 45° 直线
  B  相位图  ：X=s[n], Y=s[n-Δ]         —— 零成本，形状 = 音色/谐波结构
  C  声像法  ：每声部 pan 铺开，X=L, Y=R —— 真正的立体声李萨如，和弦会张开
  D  组合    ：B + C
"""
import glob
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

plt.rcParams["font.sans-serif"] = ["Noto Sans CJK TC", "Noto Sans CJK SC",
                                 "WenQuanYi Zen Hei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

FS = 48828.125
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUTD = os.path.join(ROOT, ".tmp", "lissajous")


def load(inst, mi, d="谐波"):
    pat = os.path.join(ROOT, f"out/{inst}/{d}/harm_{'DiZi' if inst=='dizi' else 'SuoNa'}_M{mi:03d}_H*S0.npz")
    g = glob.glob(pat)
    return np.load(g[0])["xh"].astype(float) if g else None


def load_piano(mi=60):
    """钢琴用模态模型的 h? 没有 npz，就用 add_param 表近似——这里只做形状示意，
    改用一条合成的富谐波信号代替。"""
    t = np.arange(146484) / FS
    f0 = 261.63
    y = np.zeros_like(t)
    for k, a in enumerate([1.0, 0.55, 0.42, 0.30, 0.22, 0.16, 0.11, 0.08,
                           0.06, 0.045, 0.03, 0.02], start=1):
        y += a * np.sin(2 * np.pi * k * f0 * t + 0.15 * k * k)
    env = np.exp(-t / 0.9)
    return (y * env / np.abs(y * env).max()).astype(float)


def liss(ax, xs, ys, n, title, sub, color, off=None):
    s = 0 if off is None else off
    xs = xs[s:s + n]
    ys = ys[s:s + n]
    ax.plot(xs, ys, lw=0.25, color=color, alpha=0.75)
    ax.set_xlim(-1.15, 1.15)
    ax.set_ylim(-1.15, 1.15)
    ax.set_aspect("equal")
    ax.grid(alpha=0.25, lw=0.5)
    ax.axhline(0, color="k", lw=0.4)
    ax.axvline(0, color="k", lw=0.4)
    ax.set_title(title, fontsize=11, pad=6)
    ax.set_xlabel(sub, fontsize=8)
    ax.set_xticks([])
    ax.set_yticks([])


def main():
    os.makedirs(OUTD, exist_ok=True)
    dizi = load("dizi", 67)          # G4
    suona = load("suona", 69)        # A4
    piano = load_piano()

    def norm(v):
        return v / (np.abs(v).max() + 1e-12)

    dizi, suona, piano = norm(dizi), norm(suona), norm(piano)
    n = 2500                          # 显示约 50 ms

    fig, axes = plt.subplots(2, 2, figsize=(11, 10))

    # ── A：当前 L==R → 45° 直线 ────────────────────────────────
    seg = dizi[-n:]
    liss(axes[0][0], seg, seg, n,
         "A  现在的画法：X = Lout, Y = Rout",
         "L 和 R 是同一个信号 → 永远是这条 45° 直线（没信息量）",
         "#888888")

    # ── B：相位图（单音）────────────────────────────────────────
    D = 25                            # Δ ≈ 1/4 周期（G4 周期 99 样点）
    liss(axes[0][1], dizi[:-D], dizi[D:], n,
         "B  相位图：X = s[n], Y = s[n−Δ]（笛子 G4）",
         "Δ = 25 样点 ≈ 1/4 周期 → 闭合环，形状由谐波相位决定",
         "#1f77b4")

    # ── C：声像法（真实和弦，4 个音不同 pan）──────────────────
    pans = [-1.0, -0.35, 0.35, 1.0]
    chord = [load("dizi", m) for m in (67, 71, 74, 79)]      # G4 B4 D5 G5
    L = np.zeros(len(dizi))
    R = np.zeros(len(dizi))
    for v, p in zip(chord, pans):
        if v is None:
            continue
        v = norm(v)
        ang = (p + 1) * np.pi / 4          # 左 -45° … 右 +45°
        n_ = min(len(v), len(dizi))
        L[:n_] += 0.35 * v[:n_] * np.cos(ang)
        R[:n_] += 0.35 * v[:n_] * np.sin(ang)
    L, R = norm(L), norm(R)
    liss(axes[1][0], L, R, n,
         "C  声像法：X = Lout, Y = Rout（和弦 G4 B4 D5 G5，各声部不同 pan）",
         "真正的立体声李萨如 —— 弹和弦时从直线张开成扇形",
         "#d62728")

    # ── D：相图（和弦）──────────────────────────────────────────
    mix = L + R
    mix = norm(mix)
    liss(axes[1][1], mix[:-D], mix[D:], n,
         "D  相位图（和弦）：X = s[n], Y = s[n−Δ]",
         "多音叠加后图形更复杂，能看出「正在响几个音」",
         "#2ca02c")

    fig.suptitle("HDMI 上「李萨如图形」四种候选画法（真实数据，最近 ~50 ms）",
                 fontsize=13, y=0.995)
    fig.tight_layout(rect=[0, 0, 1, 0.98])
    p = os.path.join(OUTD, "方案对比.png")
    fig.savefig(p, dpi=110)
    print("输出", p)

    # ── 顺带：三种乐器的相位图对比（说明它能区分音色）───────────
    fig2, ax2 = plt.subplots(1, 3, figsize=(12, 4.2))
    off = int(0.30 * FS)                       # 取 0.3 s 附近的稳定段
    for a, sig, nm, c in ((ax2[0], dizi, "笛子 G4", "#1f77b4"),
                          (ax2[1], suona, "唢呐 A4", "#ff7f0e"),
                          (ax2[2], piano, "钢琴 C4", "#7f7f7f")):
        d = 25
        liss(a, sig[:-d], sig[d:], n, nm, "X = s[n], Y = s[n−Δ]", c, off=off)
    fig2.suptitle("相位图能区分音色（同一画法，三种乐器）", fontsize=12)
    fig2.tight_layout(rect=[0, 0, 1, 0.94])
    p2 = os.path.join(OUTD, "乐器区分.png")
    fig2.savefig(p2, dpi=110)
    print("输出", p2)


if __name__ == "__main__":
    main()
