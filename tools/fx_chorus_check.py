#!/usr/bin/env python3
"""
fx_chorus_check.py —— 用与 RTL 完全相同的定点算法重算 fx_chorus，
                     并与 iverilog 导出的 fx_chorus_out.txt 逐样点比对。

比对要求 bit-exact。这样位宽/符号/时序任何一处搞错都会立刻暴露，
而不是靠"听起来差不多"。

用法：
    iverilog -g2012 -o <tmp>/tb_fx_chorus src/fx/fx_chorus.v tb_fx_chorus.v
    vvp <tmp>/tb_fx_chorus
    python tools/fx_chorus_check.py fx_chorus_out.txt
"""
import sys
import math

# ── 与 RTL 同源的常数 ────────────────────────────────────────────────
# ── 与 RTL 同源的常数（★ 改动 fx_chorus.v 的参数时必须同步这里）──────
ABUF      = 1024
BASE_Q8   = 150000
DEPTH_Q8  = 25000      # 2.0ms 调制深度（13.0 音分）
LFO_STEP  = 52777
GD_Q8     = 149
GW_Q8     = 149
PH_QUARTER = 0x4000_0000

# 与 add_sine.hex 完全一致：1024 点，round(32767*sin(2*pi*i/1024))
SIN10 = [round(32767 * math.sin(2 * math.pi * i / 1024)) for i in range(1024)]


def sin_of(p):
    """与 RTL 等价：add_sine_lut（1024 点）+ 10 位线性插值

    对应 RTL：
        sin_addr <= p[31:22];  lfo_fr <= p[21:12];
        sin_dout = { table[i+1], table[i] }
        lfo_v    = table[i] + ((table[i+1]-table[i]) * fr) >> 10
    """
    p &= 0xFFFFFFFF
    i  = (p >> 22) & 0x3FF
    fr = (p >> 12) & 0x3FF
    s0 = SIN10[i]
    s1 = SIN10[(i + 1) & 0x3FF]
    return s0 + (((s1 - s0) * fr) >> 10)


def soft_lim(x):
    """与 RTL 的 clamp16() 等价：硬钳位（无乘法）

    ★ 原来这里是二次软限幅 d*d，但时序报告显示
      u_fx_chorus/mx_*_s0/Q → out_*_s0/D 是全设计最差路径之一，
      在真硅片上撑不住 20 ns，导致上板出现毛刺（模型却完全干净）。
      改用硬钳位；增益结构保证引擎实际峰值下永不触发（见 RTL 文件头 ④）。
    """
    if x > 32767:
        return 32767
    if x < -32768:
        return -32768
    return x


def model(nsamp, imp_at=0, imp_val=32767):
    """定点模型：与 RTL 的 6 拍状态机数学等价（纯顺序计算）"""
    mem_l = [0] * ABUF
    mem_r = [0] * ABUF
    wr = 0
    ph = 0
    out_l = [0] * nsamp
    out_r = [0] * nsamp

    for n in range(nsamp):
        s = imp_val if n == imp_at else 0
        dry_l = s
        dry_r = s

        # 延迟量与地址（用当前 ph / wr，与 RTL st1 一致）
        for ch in (0, 1):
            p = ph if ch == 0 else (ph + PH_QUARTER) & 0xFFFFFFFF
            sv = sin_of(p)
            term = (DEPTH_Q8 * sv) >> 15           # Python >> 是算术右移（对负数是向下取整）
            dq8 = BASE_Q8 + term
            dint = (dq8 >> 8) & 0x3FF
            frac = dq8 & 0xFF
            ada = (wr - dint) & (ABUF - 1)
            adb = (ada - 1) & (ABUF - 1)
            a = mem_l[ada] if ch == 0 else mem_r[ada]
            b = mem_l[adb] if ch == 0 else mem_r[adb]
            ip = a + (((b - a) * frac) >> 8)
            mx = ((dry_l if ch == 0 else dry_r) * GD_Q8 + ip * GW_Q8) >> 8
            if ch == 0:
                out_l[n] = soft_lim(mx)
            else:
                out_r[n] = soft_lim(mx)

        # 写当前样本 + 指针前进（RTL 在 st1 写、st5 前进，等效于本样点写本槽）
        mem_l[wr] = imp_val if n == imp_at else 0
        mem_r[wr] = imp_val if n == imp_at else 0
        wr = (wr + 1) & (ABUF - 1)
        ph = (ph + LFO_STEP) & 0xFFFFFFFF

    return out_l, out_r


def delay_seq(nsamp):
    """算出每样点的延迟量（样本），用来检查 LFO 是否平滑"""
    ds = []
    ph = 0
    for _ in range(nsamp):
        sv = sin_of(ph)
        dq8 = BASE_Q8 + ((DEPTH_Q8 * sv) >> 15)
        ds.append(dq8 / 256.0)
        ph = (ph + LFO_STEP) & 0xFFFFFFFF
    return ds


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "fx_chorus_out.txt"
    rows = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) == 3:
                rows.append((int(p[0]), int(p[1]), int(p[2])))

    n = len(rows)
    print(f"读入 {n} 个样点：{path}")
    ml, mr = model(n)

    bad = 0
    first_bad = None
    for i, (idx, l, r) in enumerate(rows):
        if idx != i:
            print(f"  [警告] 第 {i} 行序号是 {idx}")
        if l != ml[i] or r != mr[i]:
            bad += 1
            if first_bad is None:
                first_bad = (i, (l, r), (ml[i], mr[i]))

    #  把非零点打出来，便于人眼确认"延迟确实在 415..756 之间且被调制"
    nz = [(i, l) for i, l, r in rows if l != 0]
    print(f"RTL 输出非零点数：{len(nz)}")
    if nz:
        print("  前 8 个非零（样点号, 值）：", nz[:8])
    nzm = [(i, ml[i]) for i in range(n) if ml[i] != 0]
    print(f"模型非零点数：{len(nzm)}")
    if nzm:
        print("  前 8 个非零：", nzm[:8])

    if bad == 0:
        print(f"\n*** PASS：{n} 个样点全部 bit-exact ***")
        rc = 0
    else:
        print(f"\n*** FAIL：{bad}/{n} 个样点不一致 ***")
        print(f"  首个不一致：样点 {first_bad[0]}  RTL={first_bad[1]}  模型={first_bad[2]}")
        rc = 1

    # ── 延迟平滑度：这一项才是"滋滋声"的量化指标 ──────────────────
    #  延迟量每样点最多只能变化 ~1.01 个样本（LFO 的最大斜率
    #  644 样本/秒 ÷ 48828 样点/秒）。若出现远大于此的跳变，
    #  就是阶梯状 LFO，听感即周期性咔哒。
    ds = delay_seq(min(n, 12000))
    jumps = [abs(ds[i + 1] - ds[i]) for i in range(len(ds) - 1)]
    mx = max(jumps) if jumps else 0.0
    print(f"\n延迟范围 {min(ds):.3f} .. {max(ds):.3f} 样本"
          f"（{min(ds)/48.828125:.2f} .. {max(ds)/48.828125:.2f} ms）")
    print(f"相邻样点延迟最大跳变：{mx:.4f} 样本"
          f"（理论上限 ≈ 1.02，即纯音高偏移）")
    if mx > 1.5:
        print("  *** 延迟存在阶梯跳变 → LFO 查表没插值，会有周期性咔哒 ***")
        rc = 1
    else:
        print("  LFO 平滑，无阶梯跳变 ✓")

    return rc


if __name__ == '__main__':
    sys.exit(main())
