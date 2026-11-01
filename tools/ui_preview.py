#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ui_preview.py —— 用 Python 逐比特复现 `src/hdmi/hdmi_ui_top.v` 的画面

目的：在板子上看不到画面 / 画面不对时，先确认「理论上应该长什么样」，
      再对照实物定位问题（是绘制逻辑错了，还是显示链路错了）。

★ 这里的数学模型必须和 RTL 一模一样，改 RTL 就要同步改这里：
    ui_dds       三角波 1 + 2/3 次谐波，相位字 inc = 38702809（440 Hz）
    ui_wave_ram  1024 点环形缓冲，扫描 idx = (lx*89)>>6
    ui_liss_ram  256×256 位图，X=s[n], Y=s[n-24]
    布局          状态条 8..52 / 波形 8..744×60..706 / 相图 752..1264×60..572
                  / INFO 752..1264×580..706

用法：
    cd /mnt/project/InstruementSound
    .venv/bin/python piano64_3/tools/ui_preview.py
输出：
    .tmp/ui_preview/ui_expected.png   理论画面（1280×720）
"""
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

FS = 48828.125
INC = 38702809                      # 440.00 Hz

W, H = 1280, 720
H_TOTAL, H_SYNC, H_BP = 1650, 40, 220
V_TOTAL, V_SYNC, V_BP = 750, 5, 20
H_START = H_SYNC + H_BP
V_START = V_SYNC + V_BP

# 面板坐标（与 RTL 一致）
WAVE_X0, WAVE_Y0, WAVE_X1, WAVE_Y1 = 8, 60, 744, 706
LISS_X0, LISS_Y0, LISS_X1, LISS_Y1 = 752, 60, 1264, 572
INFO_X0, INFO_Y0, INFO_X1, INFO_Y1 = 752, 580, 1264, 706
STAT_X0, STAT_Y0, STAT_X1, STAT_Y1 = 8, 8, 1272, 52

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUTD = os.path.join(ROOT, ".tmp", "ui_preview")

M32 = 0xFFFFFFFF


def s_ext(v, bits):
    """把 bits 位的无符号整数按二进制补码解释成有符号"""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


SINE = [int(round(32767 * np.sin(2 * np.pi * i / 256))) for i in range(256)]


def gen_samples(n=4000):
    """逐样点复现 ui_dds：sin(φ) + 0.5 sin(2φ) + 0.25 sin(3φ)"""
    ph = 0
    vib = 0
    out = np.zeros(n, dtype=np.int64)
    for i in range(n):
        vt = s_ext(vib >> 4, 12) * 16
        ph = (ph + INC + vt) & M32
        vib = (vib + 1) & 0xFFFF
        ph2 = (ph << 1) & M32
        ph3 = (ph + ph2) & M32
        y1 = SINE[(ph >> 24) & 0xFF]
        y2 = SINE[(ph2 >> 24) & 0xFF]
        y3 = SINE[(ph3 >> 24) & 0xFF]
        sum3 = y1 + (y2 >> 1) + (y3 >> 2)
        out[i] = s_ext((sum3 >> 1) & 0xFFFF, 16)
    return out


def wave_y(s):
    """RTL: t = s*300 (signed); wave_y = 323 - (t >>> 15)  ← 算术右移"""
    t = int(s) * 300
    return 323 - (t >> 15)


def main():
    os.makedirs(OUTD, exist_ok=True)
    samp = gen_samples(4000)
    print("样点范围 %d .. %d  (峰值 %d)" % (samp.min(), samp.max(),
                                            np.abs(samp).max()))

    img = np.zeros((H, W, 3), dtype=np.float32)

    # ── 面板底色 / 边框 ────────────────────────────────────────
    def rect_edge(x0, y0, x1, y1, c):
        img[y0, x0:x1 + 1] = c
        img[y1, x0:x1 + 1] = c
        img[y0:y1 + 1, x0] = c
        img[y0:y1 + 1, x1] = c

    EDGE = (0.50, 0.56, 0.63)
    rect_edge(STAT_X0, STAT_Y0, STAT_X1, STAT_Y1, EDGE)
    rect_edge(WAVE_X0, WAVE_Y0, WAVE_X1, WAVE_Y1, EDGE)
    rect_edge(LISS_X0, LISS_Y0, LISS_X1, LISS_Y1, EDGE)
    rect_edge(INFO_X0, INFO_Y0, INFO_X1, INFO_Y1, EDGE)

    # ── 波形 ───────────────────────────────────────────────────
    # 最后一帧的 1024 点在环形缓冲里；这里直接用最后 1024 个样点
    ring = samp[-1024:]
    for lx in range(0, WAVE_X1 - WAVE_X0):
        # 当前列与上一列各自的样点下标（画两点之间的竖线）
        idx_c = ((lx * 89) >> 6) & 0x3FF
        idx_p = (((lx - 1) * 89) >> 6) & 0x3FF if lx > 0 else idx_c
        y1 = wave_y(ring[idx_p])
        y0 = wave_y(ring[idx_c])
        lo, hi = min(y0, y1) - 1, max(y0, y1) + 1
        ys = WAVE_Y0 + np.arange(lo, hi + 1)
        ys = ys[(ys > WAVE_Y0) & (ys < WAVE_Y1)]
        img[ys, WAVE_X0 + lx] = (0.19, 1.0, 0.38)

    # ── 相图（X=s[n], Y=s[n-24]）──────────────────────────────
    bm = np.zeros((256, 256), dtype=bool)
    lag = 24
    for n in range(lag, len(samp)):
        px = ((samp[n] >> 8) + 128) & 0xFF
        py = ((samp[n - lag] >> 8) + 128) & 0xFF
        bm[py, px] = True

    # 2×2 上采样 + 中心十字
    up = np.zeros((512, 512), dtype=bool)
    up[::2, ::2] = bm
    up[1::2, ::2] = bm
    up[::2, 1::2] = bm
    up[1::2, 1::2] = bm
    hh = LISS_Y1 - (LISS_Y0 + 1)
    ww = LISS_X1 - (LISS_X0 + 1)
    m = up[:hh, :ww]
    sub = img[LISS_Y0 + 1:LISS_Y1, LISS_X0 + 1:LISS_X1]
    sub[m] = (1.0, 0.50, 0.13)
    img[LISS_Y0 + 1:LISS_Y1, LISS_X0 + 1:LISS_X1] = sub
    img[LISS_Y0 + 256, LISS_X0 + 1:LISS_X1] = (0.19, 0.22, 0.25)
    img[LISS_Y0 + 1:LISS_Y1, LISS_X0 + 256] = (0.19, 0.22, 0.25)

    # ── 文字（用系统字体近似点阵效果，只求位置对）───────────────
    fp = font_manager.FontProperties(
        fname="/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
        size=11)

    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(H, 0)
    ax.axis("off")
    ax.imshow(img, interpolation="nearest", extent=[0, W, H, 0])

    ax.text(24, 30, "UI TEST 720P", color="white", fontproperties=fp,
            va="center")
    ax.text(20, 76, "WAVE", color=(0.25, 0.75, 1.0), fontproperties=fp,
            va="center")
    ax.text(764, 76, "LISSAJOUS", color=(1.0, 0.69, 0.25), fontproperties=fp,
            va="center")
    ax.text(764, 596, "INFO", color=(0.25, 1.0, 0.5), fontproperties=fp,
            va="center")

    p = os.path.join(OUTD, "ui_expected.png")
    fig.savefig(p, dpi=100)
    print("输出", p)

    # ── 数值自检 ───────────────────────────────────────────────
    print()
    print("数值自检：")
    print("  样点峰值      %d   (满刻度 32767 的 %.0f%%)"
          % (np.abs(samp).max(), 100 * np.abs(samp).max() / 32767))
    ys = [wave_y(s) for s in ring]
    print("  波形纵向范围  %d .. %d   跨度 %d px / 面板高 %d"
          % (min(ys), max(ys), max(ys) - min(ys), WAVE_Y1 - WAVE_Y0))
    print("  相图占点      %d / 65536  (%.1f%%)"
          % (bm.sum(), 100 * bm.sum() / 65536))


if __name__ == "__main__":
    main()
