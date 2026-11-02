#!/usr/bin/env python3
"""
fx_reverb_check.py —— 用与 RTL 完全相同的定点算法重算 fx_reverb，
                      与 iverilog 导出的 fx_reverb_out.txt 逐样点比对。

算法（与 src/fx/fx_reverb.v 一一对应）：
    单声道内核，8 条带阻尼梳状并联 → 4 级全通串联
    左右来自同一缓冲区，只是读位置差 23 样本（省一半内存）

用法：
    iverilog -g2012 -o <tmp>/tb_fx_reverb src/fx/fx_reverb.v tb_fx_reverb.v
    vvp <tmp>/tb_fx_reverb
    python tools/fx_reverb_check.py fx_reverb_out.txt
"""
import sys

LC     = 12288     # 8 段梳状打包后的总深度
LA     = 1792      # 4 段全通打包后的总深度
SPREAD = 23
COMB   = [1236, 1315, 1414, 1502, 1574, 1651, 1724, 1790]
AP     = [616, 488, 378, 249]
# ★ 环形长度取 L = D+1（读 ptr+1、写 ptr），避免综合出 read-before-write
COMB_L = [d + 1 for d in COMB]
AP_L   = [d + 1 for d in AP]
# 段基址 = 前面所有段长度之和（与 RTL 的 cbase/abase 一致）
CBASE  = [0, 1237, 2553, 3968, 5471, 7046, 8698, 10423]
ABASE  = [0, 617, 1106, 1485]
FB_Q8  = 225
GD_Q8  = 128
GW_Q8  = 140


def s16(v):
    v &= 0xFFFF
    return v - 65536 if v >= 32768 else v


def clamp16(v):
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return v


def model(n):
    cmem = [0] * LC
    cptr = [0] * 8
    cfs  = [0] * 8
    amem_l = [0] * LA
    amem_r = [0] * LA
    aptr = [0] * 4
    out = []

    for i in range(n):
        inl = 32767 if i == 0 else 0
        inr = 32767 if i == 0 else 0
        dry_l, dry_r = inl, inr

        # 单声道化 + 1/128 衰减（(l+r)>>1 再 >>6）
        xin = (inl + inr) >> 7

        acc_l = 0
        acc_r = 0
        for k in range(8):
            L = COMB_L[k]
            base = CBASE[k]
            pl = base + (cptr[k] + 1) % L
            pr = base + (cptr[k] + 24) % L       # +1（环） + 23（立体声抽头）
            rdl = s16(cmem[pl])
            rdr = s16(cmem[pr])
            fs = (rdl + cfs[k]) >> 1          # damp = 0.5
            cfs[k] = fs
            cmem[base + cptr[k]] = (xin + ((fs * FB_Q8) >> 8)) & 0xFFFF
            cptr[k] = (cptr[k] + 1) % L
            acc_l += rdl
            acc_r += rdr

        ap_l = acc_l
        ap_r = acc_r
        for a in range(4):
            L = AP_L[a]
            base = ABASE[a]
            rd = (aptr[a] + 1) % L
            rdl = s16(amem_l[base + rd])
            rdr = s16(amem_r[base + rd])
            amem_l[base + aptr[a]] = ((ap_l & 0xFFFF) + (rdl >> 1)) & 0xFFFF
            amem_r[base + aptr[a]] = ((ap_r & 0xFFFF) + (rdr >> 1)) & 0xFFFF
            aptr[a] = (aptr[a] + 1) % L
            ap_l = rdl - (ap_l >> 1)
            ap_r = rdr - (ap_r >> 1)

        ol = clamp16((dry_l * GD_Q8 + s16(ap_l & 0xFFFF) * GW_Q8) >> 8)
        orr = clamp16((dry_r * GD_Q8 + s16(ap_r & 0xFFFF) * GW_Q8) >> 8)
        out.append((ol, orr))

    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "fx_reverb_out.txt"
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

    m = model(n)

    bad = 0
    first_bad = None
    for i, (idx, l, r) in enumerate(rows):
        if l != m[i][0] or r != m[i][1]:
            bad += 1
            if first_bad is None:
                first_bad = (i, (l, r), m[i])

    nz = [(i, l, r) for i, l, r in rows if l != 0 or r != 0]
    print(f"RTL 非零点数：{len(nz)}")
    print("  前 8 个非零（样点, L, R）：")
    for v in nz[:8]:
        print(f"    n={v[0]:6d}  L={v[1]:7d}  R={v[2]:7d}")

    #  尾巴衰减检查：看最后 1/8 段的最大幅度
    tail = [max(abs(l), abs(r)) for i, l, r in rows[int(n * 7 / 8):]]
    print(f"\n最后 1/8 段最大幅度：{max(tail) if tail else 0}（应明显小于峰值）")

    if bad == 0:
        print(f"\n*** PASS：{n} 个样点全部 bit-exact ***")
        return 0
    print(f"\n*** FAIL：{bad}/{n} 个样点不一致 ***")
    print(f"  首个不一致：样点 {first_bad[0]}  RTL={first_bad[1]}  模型={first_bad[2]}")
    return 1


if __name__ == '__main__':
    sys.exit(main())
