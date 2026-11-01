#!/usr/bin/env python3
"""
gen_spec_cqt.py —— 生成 32 段常数-Q 频谱分析的 ROM 表

输出（生成到 piano64_3/ 根目录，与 add_sine.hex 同级）：
    spec_ar.hex    32 项  24 位有符号  cos(2πf/fs)   Q1.23
    spec_ai.hex    32 项  24 位有符号 −sin(2πf/fs)   Q1.23
    spec_inc.hex   32 项  24 位无符号  2^24 / N_k    （窗相位步进）
    spec_l2n.hex   32 项  16 位无符号  log2(N_k)     Q8.8
    spec_win.hex  256 项  16 位无符号  Hann 窗        Q1.15

参数与 tools/goertzel_cqt_model.py 完全一致（N_MULT=2, Hann）。
"""

import numpy as np

FS = 48828.125
F_LO, F_HI = 40.0, 16000.0
NBAND = 32
N_MULT = 3

RATIO = (F_HI / F_LO) ** (1.0 / (NBAND - 1))
FC = F_LO * RATIO ** np.arange(NBAND)
NK = np.maximum(np.round(FS / (FC * (RATIO - 1.0))).astype(int) * N_MULT, 12)

OUT = "."


def q24(v):
    """Q1.23，24 位有符号，±1.0"""
    r = int(round(v * 2**23))
    return max(-2**23, min(2**23 - 1, r))


def hexs(v, w):
    return f"{v & ((1 << w) - 1):0{w//4}x}"


# ── AR / AI ────────────────────────────────────────────────────
ar = [q24(np.cos(2 * np.pi * f / FS)) for f in FC]
ai = [q24(-np.sin(2 * np.pi * f / FS)) for f in FC]
# ── INC = 2^24 / N_k ───────────────────────────────────────────
inc = [int(round(2**24 / n)) for n in NK]
# ── L2N = log2(N) × 256 ────────────────────────────────────────
l2n = [int(round(np.log2(n) * 256)) for n in NK]

open(f"{OUT}/spec_ar.hex", "w").write("\n".join(hexs(v, 24) for v in ar) + "\n")
open(f"{OUT}/spec_ai.hex", "w").write("\n".join(hexs(v, 24) for v in ai) + "\n")
open(f"{OUT}/spec_inc.hex", "w").write("\n".join(hexs(v, 24) for v in inc) + "\n")
open(f"{OUT}/spec_l2n.hex", "w").write("\n".join(hexs(v, 16) for v in l2n) + "\n")

# ── Hann 窗 256 点 Q1.15 ───────────────────────────────────────
win = [int(round(32767 * (0.5 - 0.5 * np.cos(2 * np.pi * i / 256))))
       for i in range(256)]
open(f"{OUT}/spec_win.hex", "w").write("\n".join(hexs(v, 16) for v in win) + "\n")

# ── log2 尾数表：m = 0..255 → log2(1 + m/256) × 256 (Q8.8) ────
logt = [int(round(np.log2(1.0 + i / 256.0) * 256)) for i in range(256)]
open(f"{OUT}/spec_log.hex", "w").write("\n".join(hexs(v, 16) for v in logt) + "\n")

# ── 打印核对表 ─────────────────────────────────────────────────
print(f"{'段':>3} {'中心Hz':>9} {'N_k':>6} {'N_eff':>8} {'cos':>10} {'-sin':>10} "
      f"{'INC':>8} {'log2N':>7}")
for k in range(NBAND):
    print(f"{k:>3} {FC[k]:>9.1f} {NK[k]:>6} {2**24/inc[k]:>8.1f} "
          f"{ar[k]/2**23:>10.6f} {ai[k]/2**23:>10.6f} "
          f"{inc[k]:>8} {l2n[k]/256:>7.2f}")
print(f"\nΣN_k = {NK.sum()}   Hann 峰值 = {max(win)}")
print("已生成 spec_ar/ai/inc/l2n/win.hex")
