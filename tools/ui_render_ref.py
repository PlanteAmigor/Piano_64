#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ui_render_ref.py —— HDMI UI 的「理论显示图」参考渲染（金标准）

严格按 hdmi_ui_top.v 的布局/索引公式画一遍，用来对比上板实际画面。
输出 .tmp/ui/ref.png
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUTD = os.path.join(ROOT, ".tmp", "ui")
os.makedirs(OUTD, exist_ok=True)

# ── 面板几何（与 RTL 完全一致）──────────────────────────────
P_STAT = (8, 8, 1272, 52)
P_WAVE = (8, 60, 744, 706)
P_LISS = (752, 60, 1264, 572)
P_INFO = (752, 580, 1264, 706)

C_EDGE = (0x80, 0x90, 0xA0)
C_WAVE = (0x30, 0xFF, 0x60)
C_LISS = (0xFF, 0x80, 0x20)
C_CROSS = (0x30, 0x38, 0x40)

# ── 合成音源（对应 ui_dds：sin + 0.5sin2 + 0.25sin3 @ 440Hz）──
FS = 75e6 / 1024
N = 8192
t = np.arange(N) / FS
f0 = 440.0
ph = 2 * np.pi * f0 * t
y = np.sin(ph) + 0.5 * np.sin(2 * ph) + 0.25 * np.sin(3 * ph)
y = y / np.abs(y).max() * 0.95
s = (y * 32767).astype(np.int64)

img = Image.new("RGB", (W, H), (0, 0, 0))
d = ImageDraw.Draw(img)

def rect(p, col=C_EDGE):
    d.rectangle([p[0], p[1], p[2] - 1, p[3] - 1], outline=col)

for p in (P_STAT, P_WAVE, P_LISS, P_INFO):
    rect(p)

# ── 波形：736 像素显示 1024 点，画「上一列 → 当前列」竖线 ──
WAVE_N = 1024
win = s[:WAVE_N].copy()
def wave_y(v):
    return 323 - (int(v) * 300 >> 15)

for lx in range(1, 736):
    i0 = (lx - 1) * 89 >> 6
    i1 = lx * 89 >> 6
    y0 = wave_y(win[i0]); y1 = wave_y(win[i1])
    lo, hi = min(y0, y1) - 1, max(y0, y1) + 1
    d.line([P_WAVE[0] + lx, P_WAVE[1] + lo, P_WAVE[0] + lx, P_WAVE[1] + hi], fill=C_WAVE)

# ── 相图 256×256：X=s[n], Y=s[n-24]，2×2 放大 ──
bit = np.zeros((256, 256), dtype=bool)
D = 24
for n in range(D, min(N, 4000)):
    x = int(s[n] >> 8) + 128
    yy = int(s[n - D] >> 8) + 128
    if 0 <= x < 256 and 0 <= yy < 256:
        bit[yy, x] = True
big = Image.fromarray((bit * 255).astype(np.uint8)).resize((512, 512), Image.NEAREST).convert("RGB")
col = Image.new("RGB", (512, 512), C_LISS)
mask = big.convert("L").point(lambda v: 255 if v else 0)
img.paste(col, (P_LISS[0], P_LISS[1]), mask)
# 中心十字
d.line([P_LISS[0] + 256, P_LISS[1], P_LISS[0] + 256, P_LISS[3]], fill=C_CROSS)
d.line([P_LISS[0], P_LISS[1] + 256, P_LISS[2], P_LISS[1] + 256], fill=C_CROSS)

# ── 文字（同一份 DejaVuSansMono-Bold 13px，与字库一致）──
F = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 13)
def put(x, y, txt, col):
    # 逐字符 8px 步进，与 RTL 的 8×16 单元一致
    for i, ch in enumerate(txt):
        d.text((x + i * 8, y), ch, font=F, fill=col)

put(24,  20, "UI TEST 720P", (255, 255, 255))
put(20,  72, "WAVE",        (0x40, 0xC0, 0xFF))
put(764, 72, "LISSAJOUS",   (0xFF, 0xB0, 0x40))
put(764, 592, "INFO",       (0x40, 0xFF, 0x80))

p = os.path.join(OUTD, "ref.png")
img.save(p)
print("输出", p)

# 数值自检
print("样点峰值 %d / 最小 %d" % (s.max(), s.min()))
print("波形 y 范围 %d .. %d" % (min(wave_y(v) for v in win), max(wave_y(v) for v in win)))
print("相图点亮像素 %d / 65536" % bit.sum())
