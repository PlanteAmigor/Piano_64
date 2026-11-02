#!/usr/bin/env python3
"""
fx_delay_check.py —— 用与 RTL 完全相同的定点算法重算 fx_delay，
                     与 iverilog 导出的 fx_delay_out.txt 逐样点比对。

算法（与 tools/fx_sim.py 的 delay() 一致）：
    jl = i % DLEN_L ; jr = i % DLEN_R
    yl = bl[jl] ; yr = br[jr]                  # 先读
    bl[jl] = clamp16(x[i] + (yr*FB)>>8)        # 后写（同地址），交叉反馈
    br[jr] = clamp16(x[i] + (yl*FB)>>8)
    out = clamp16((x[i]*GD + 湿*GW) >> 8)

用法：
    iverilog -g2012 -o <tmp>/tb_fx_delay src/fx/fx_delay.v tb_fx_delay.v
    vvp <tmp>/tb_fx_delay          # 在含可写目录下运行
    python tools/fx_delay_check.py fx_delay_out.txt
"""
import sys

DLEN_L = 16384
DLEN_R = 12207
FB_Q8  = 97
GD_Q8  = 128
GW_Q8  = 141


def clamp16(x):
    if x > 32767:
        return 32767
    if x < -32768:
        return -32768
    return x


def model(nsamp, imp_at=0, imp_val=32767):
    bl = [0] * DLEN_L
    br = [0] * DLEN_R
    jl = jr = 0
    ol = [0] * nsamp
    orr = [0] * nsamp
    for i in range(nsamp):
        x = imp_val if i == imp_at else 0
        yl = bl[jl]
        yr = br[jr]
        # 先读后写；交叉反馈
        bl[jl] = clamp16(x + ((yr * FB_Q8) >> 8))
        br[jr] = clamp16(x + ((yl * FB_Q8) >> 8))
        ol[i]  = clamp16((x * GD_Q8 + yl * GW_Q8) >> 8)
        orr[i] = clamp16((x * GD_Q8 + yr * GW_Q8) >> 8)
        jl += 1
        if jl == DLEN_L:
            jl = 0
        jr += 1
        if jr == DLEN_R:
            jr = 0
    return ol, orr


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "fx_delay_out.txt"
    rows = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) == 3:
                try:
                    rows.append((int(p[0]), int(p[1]), int(p[2])))
                except ValueError:
                    pass

    n = len(rows)
    print(f"读入 {n} 个样点：{path}")
    if n == 0:
        print("*** FAIL：没有读到数据 ***")
        return 1

    ml, mr = model(n)

    bad = 0
    first_bad = None
    for i, (idx, l, r) in enumerate(rows):
        if l != ml[i] or r != mr[i]:
            bad += 1
            if first_bad is None:
                first_bad = (i, (l, r), (ml[i], mr[i]))

    nz = [(i, l, r) for i, l, r in rows if l != 0 or r != 0]
    print(f"RTL 非零点数：{len(nz)}")
    print("  前 10 个非零（样点, L, R）：")
    for v in nz[:10]:
        print(f"    n={v[0]:6d}  L={v[1]:7d}  R={v[2]:7d}")

    #  回声位置自检：左首次回声应出现在 DLEN_L 附近
    echoes_l = [i for i, l, r in rows[:DLEN_L + 200] if l != 0]
    print(f"\n左声道首次非零样点：{echoes_l[:5]}（期望含 0 和 ≈{DLEN_L}）")

    if bad == 0:
        print(f"\n*** PASS：{n} 个样点全部 bit-exact ***")
        return 0
    print(f"\n*** FAIL：{bad}/{n} 个样点不一致 ***")
    print(f"  首个不一致：样点 {first_bad[0]}  RTL={first_bad[1]}  模型={first_bad[2]}")
    return 1


if __name__ == '__main__':
    sys.exit(main())
