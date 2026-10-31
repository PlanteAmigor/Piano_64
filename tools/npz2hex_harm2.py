#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
npz2hex_harm2.py —— 谐波表【多 bank 打包版】，为 4 声部全流水引擎服务

## 为什么重做

旧版（npz2hex_harm.py）是一个 16 位 ROM，9 个字段九次串行读 → 16 拍/谐波
→ 一个样点(1024 拍)只放得下 1 个声部。

新版把表拆成【互相独立、可并行读】的几个 bank，并消除依赖读：

    ROM0  ab   32bit  {A, phi_a}                     1 读/谐波
    ROM1  bc   32bit  {dm, env_scale}                1 读/谐波
    ROM2  pi   16bit  psi_off（已预乘成字偏移）        1 读/谐波
    ROM3e psi_e 16bit Ψ 偶数点                        1 读/谐波
    ROM3o psi_o 16bit Ψ 奇数点                        1 读/谐波
    ROM4e env_e  8bit Env 偶数点                       1 读/谐波
    ROM4o env_o  8bit Env 奇数点                       1 读/谐波
    ROM5  sin  32bit  {sin[i+1], sin[i]}   （全局）    1 读/谐波
    ROM6  phi  32bit  Φ                    （每音）   2 读/样点
    ROM7  u    32bit  u(t)                 （全局）   2 读/样点

★ psi_off 直接存「行号×步长」的**字偏移**，不再是 psi_idx 行号：
  这样 Ψ 的地址不用等 psi_idx 读回来再算，**没有依赖读**，所有 bank 同拍发地址。
  没有 Ψ 的谐波指向每音末尾那条**全零行**（额外 1 行，300 字），RTL 不用判 0xFFFF。

★ Ψ / Env 拆奇偶两个 bank：
  插值要相邻两点 (j, j+1)。若存成一个 bank 就要两次读，流水线吞吐减半。
  拆成奇/偶后 j 和 j+1 分别落在两个 bank 里，各读一次就行：
      addr_e = (j+1)>>1     addr_o = j>>1
      j 偶：first=env_e[addr_e]  second=env_o[addr_o]
      j 奇：first=env_o[addr_o]  second=env_e[addr_e]
  每行末尾多补 1 个字，保证 j 取到最大值时 addr_e 不越界。

## 输出文件

    <pre>_ab.hex        32bit  每音 K 个
    <pre>_bc.hex        32bit  每音 K 个
    <pre>_pi.hex        16bit  每音 K 个
    <pre>_psi_e.hex     16bit  每音 (npsi+1)×PSI_E 个
    <pre>_psi_o.hex     16bit  同上
    <pre>_env_e.hex      8bit  每音 K×ENV_E 个（写成 2 位十六进制）
    <pre>_env_o.hex      8bit  同上
    <pre>_phi.hex        32bit  每音 NT 个
    <pre>_bank_base.hex  32bit  每音 1 个：{ab(8) | pi(8) | psi_row(8) | env_row(8)}
                               —— 只用于核对，RTL 另用四个基址表

★ 每个 bank 的基址清单写在 <pre>_base_*.hex（每音一行），RTL 用 $readmemh 直接查。

用法：
    export TMPDIR=$PWD/.tmp
    python3 npz2hex_harm2.py --dir ../../out/dizi/谐波 --pattern 'harm_DiZi_M*.npz' \\
        --prefix dizi --outdir ../../.tmp/tables_harm2
"""
import argparse
import glob
import os
import re
import sys

import numpy as np

FS = 48828.0
WARP_T0, WARP_D, WARP_ALPHA = 0.06, 3.0, 0.6

NT = 600          # Φ 表点数
NT2 = 300         # Ψ 表点数
NT3 = 150         # Env 表点数

PSI_E = NT2 // 2 + 1      # 151（多补 1 个防越界）
PSI_O = NT2 // 2 + 1
ENV_E = NT3 // 2 + 1      # 76
ENV_O = NT3 // 2 + 1

SC_A, SC_PA, SC_DM, SC_PS = 4096.0, 65536.0, 1000.0, 8192.0
#  ★ A 用 Q4.11（±8.0）而不是 Q3.13（±4.0）：
#    dizi 最大 A = 4.48、suona 最大 A = 6.83，Q3.13 会把 9 个音的谐波削顶
#    （旧表 npz2hex_harm.py 的 SC_A=8192 就有这个病）。
#    精度代价很小：1/4096 的量化误差，比 int8 包络的 1/127 小 32 倍。
#    ⚠️ 改了 SC_A 必须同步：RTL 输出 acc 的定标从 >>>20 改成 >>>19
SC_PHI = float(1 << 19)
SC_ENV = 32768.0

MIDI_RE = re.compile(r'_M(\d+)')


def warp_u(t):
    return ((1 - WARP_ALPHA) * t / WARP_D
            + WARP_ALPHA * np.log1p(t / WARP_T0) / np.log1p(WARP_D / WARP_T0))


def split_eo(row, stride_e, stride_o):
    """一行 → (偶数点, 奇数点)，末尾各补一个防越界"""
    even = row[0::2]
    odd = row[1::2]
    even = np.append(even, even[-1] if len(even) else 0)
    odd = np.append(odd, odd[-1] if len(odd) else 0)
    assert len(even) <= stride_e and len(odd) <= stride_o, (len(even), len(odd))
    e = np.zeros(stride_e, dtype=np.int64); e[:len(even)] = even
    o = np.zeros(stride_o, dtype=np.int64); o[:len(odd)] = odd
    return e, o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True)
    ap.add_argument('--pattern', default='harm_*_M*.npz')
    ap.add_argument('--prefix', required=True)
    ap.add_argument('--outdir', required=True)
    # ★★ 逐音峰值归一化（笛子必须开，唄呐已经≈1.0可以不开）
    #    模型重建信号 xh 的峰值就是「引擎满刻度」的倍数：
    #      唄呐 28 音峰值中位 1.001、最大 1.151 → 已经是归一化的
    #      笛子 25 音峰值中位 1.385、最大 3.198 → 直接上板会顶进软限幅
    #        （ G4: mix 峰值 26193 ×2 = 52386 → 被压到 32192，1.6:1 压缩）
    #    这里把每个音的 A 整体除以其峰值，和唄呐对齐。
    ap.add_argument('--norm', action='store_true',
                    help='逐音把 A 缩放到峰值=1.0（推荐用于 dizi）')
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.dir, a.pattern)))
    if not files:
        print('✗ 没匹配到文件: %s/%s' % (a.dir, a.pattern))
        return 1
    notes = {}
    for fn in files:
        m = MIDI_RE.search(os.path.basename(fn))
        if m:
            notes[int(m.group(1))] = fn
    midis = sorted(notes)

    # ── 第一遍：算每个音的字数，分配各 bank 的基址 ─────────────────
    bins = {k: [] for k in ('ab', 'bc', 'pi', 'psi_e', 'psi_o', 'env_e', 'env_o', 'phi')}
    bases = {k: [] for k in bins}
    meta = {}
    for mi in midis:
        d = np.load(notes[mi], allow_pickle=True)
        K = int(len(d['dm']))
        npsi = int((np.asarray(d['phm_mask']) != 0).sum())
        meta[mi] = (K, npsi)

    tot = {k: 0 for k in bins}
    for mi in midis:
        K, npsi = meta[mi]
        for k, n in (('ab', K), ('bc', K), ('pi', K),
                     ('psi_e', (npsi + 1) * PSI_E), ('psi_o', (npsi + 1) * PSI_O),
                     ('env_e', K * ENV_E), ('env_o', K * ENV_O), ('phi', NT)):
            bases[k].append(tot[k])
            tot[k] += n

    data = {k: np.zeros(tot[k], dtype=np.uint64) for k in bins}

    # ── 第二遍：逐音填充 ──────────────────────────────────────────
    print('%-6s %4s %5s %8s %10s %7s %7s %8s' % ('MIDI', 'K', 'npsi', 'phi_max', 'a_max', 'psi_max', 'env_max', 'gain'))
    for i, mi in enumerate(midis):
        d = np.load(notes[mi], allow_pickle=True)
        K, npsi = meta[mi]
        c = np.asarray(d['c'], dtype=np.float64)
        am, bm = c[:K], c[K:2 * K]
        A = np.hypot(am, bm)
        # ★ 峰值归一化：A 是线性幅度，整体缩一个因子不改变音色/相位
        gain = 1.0
        if a.norm:
            xh = np.asarray(d['xh'], dtype=np.float64)
            pk  = float(np.abs(xh).max())
            gain = (1.0 / pk) if pk > 0 else 1.0
            A = A * gain
        phi_c = np.arctan2(bm, am) / (2 * np.pi)
        dm = np.asarray(d['dm'], dtype=np.float64)
        tau_u = np.asarray(d['u'], dtype=np.float64)
        phi = np.asarray(d['phi'], dtype=np.float64)
        phm = np.asarray(d['phm'], dtype=np.float64)
        env = np.asarray(d['env'], dtype=np.float64)
        mask = np.asarray(d['phm_mask'], dtype=np.float64)

        # 起振项预乘进 Env（和旧版一致）
        _tt = np.linspace(0, WARP_D, 400000)
        _uu = warp_u(_tt)
        t_at_tab = np.interp(np.arange(NT3) / max(NT3 - 1, 1), _uu, _tt)
        env = env * (1.0 - np.exp(-t_at_tab[None, :] / tau_u[:, None]))

        def q(v, sc, lo, hi):
            return np.round(np.clip(v * sc, lo, hi)).astype(np.int64)

        # ROM0 {A, phi_a}
        aq = q(A, SC_A, -32768, 32767) & 0xFFFF
        paq = q(phi_c, SC_PA, -32768, 32767) & 0xFFFF
        w = bases['ab'][i]
        data['ab'][w:w + K] = aq | (paq << 16)

        # ROM1 {dm, env_scale}
        env_sc = np.abs(env).max(axis=1)
        dq = q(dm, SC_DM, -32768, 32767) & 0xFFFF
        sq = q(env_sc, SC_ENV, 0, 65535) & 0xFFFF
        w = bases['bc'][i]
        data['bc'][w:w + K] = dq | (sq << 16)

        # ROM2 psi_off：行号 × 步长；无 Ψ 的谐波指向全零行（第 npsi 行）
        psi_off = np.full(K, npsi * PSI_E, dtype=np.int64)
        rows = np.where(mask != 0)[0]
        for r_i, r in enumerate(rows):
            psi_off[r] = r_i * PSI_E
        w = bases['pi'][i]
        data['pi'][w:w + K] = psi_off & 0xFFFF

        # ROM3e/3o Ψ（奇偶拆开）；最后一行全零
        we = bases['psi_e'][i]
        wo = bases['psi_o'][i]
        for r_i, r in enumerate(rows):
            row = phm[r] * mask[r]
            qq = q(row, SC_PS, -32768, 32767) & 0xFFFF
            e, o = split_eo(qq.astype(np.int64), PSI_E, PSI_O)
            data['psi_e'][we + r_i * PSI_E: we + (r_i + 1) * PSI_E] = e.astype(np.uint64) & 0xFFFF
            data['psi_o'][wo + r_i * PSI_O: wo + (r_i + 1) * PSI_O] = o.astype(np.uint64) & 0xFFFF
        # 全零行（r_i = npsi）已经是 0，不用写

        # ROM4e/4o Env（8 位，奇偶拆开）
        we = bases['env_e'][i]
        wo = bases['env_o'][i]
        for m in range(K):
            sm = env_sc[m]
            if sm < 1e-9:
                qv = np.zeros(NT3, dtype=np.int64)
            else:
                qv = np.round(np.clip(env[m] / sm * 127.0, -127, 127)).astype(np.int64) & 0xFF
            e, o = split_eo(qv, ENV_E, ENV_O)
            data['env_e'][we + m * ENV_E: we + (m + 1) * ENV_E] = e.astype(np.uint64) & 0xFF
            data['env_o'][wo + m * ENV_O: wo + (m + 1) * ENV_O] = o.astype(np.uint64) & 0xFF

        # ROM6 Φ：32 位 Q13.19 绝对圈，一个字一个点
        ph32 = np.round(np.clip(phi, 0.0, 8191.0) * SC_PHI).astype(np.uint64) & 0xFFFFFFFF
        w = bases['phi'][i]
        data['phi'][w:w + NT] = ph32

        psi_max = float(max((np.abs(phm[r] * mask[r]).max() for r in rows), default=0.0))
        print('%-6d %4d %5d %8.1f %10.3f %7.3f %7.3f %8.3f'
              % (mi, K, npsi, np.abs(phi).max(), np.abs(A).max(), psi_max,
                 np.abs(env).max(), gain))

    # ── 写出 ──────────────────────────────────────────────────────
    os.makedirs(a.outdir, exist_ok=True)
    widths = {'ab': 8, 'bc': 8, 'pi': 4, 'psi_e': 4, 'psi_o': 4,
              'env_e': 2, 'env_o': 2, 'phi': 8}
    for k in ('ab', 'bc', 'pi', 'psi_e', 'psi_o', 'env_e', 'env_o', 'phi'):
        p = os.path.join(a.outdir, '%s_%s.hex' % (a.prefix, k))
        with open(p, 'w') as f:
            for v in data[k]:
                f.write(('%0' + str(widths[k]) + 'X\n') % int(v))
    for k in ('ab', 'bc', 'pi', 'psi_e', 'psi_o', 'env_e', 'env_o', 'phi'):
        p = os.path.join(a.outdir, '%s_base_%s.hex' % (a.prefix, k))
        with open(p, 'w') as f:
            for b in bases[k]:
                f.write('%08X\n' % int(b))

    # 每音信息（RTL 开机取一次）：4 字/音
    #   ★ phi_base 必须在第 0 个字：前置第 3 拍就要用它算 Φ 地址，
    #     排在第 4 个字的话数据到得太晚（踩过：只有第一个音对）
    #   w0 = phi_base  w1 = {K[31:24], npsi[23:16], ab_base[15:0]}
    #   w2 = env_base  w3 = psi_base
    p = os.path.join(a.outdir, '%s_info.hex' % a.prefix)
    with open(p, 'w') as f:
        for i, mi in enumerate(midis):
            K, npsi = meta[mi]
            ab_b = bases['ab'][i]
            assert ab_b == bases['bc'][i] == bases['pi'][i]
            assert bases['psi_e'][i] == bases['psi_o'][i]
            assert bases['env_e'][i] == bases['env_o'][i]
            assert ab_b < 65536 and bases['env_e'][i] < 65536
            assert bases['psi_e'][i] < 65536 and bases['phi'][i] < 65536
            f.write('%08X\n' % (bases['phi'][i] & 0xFFFF))
            f.write('%08X\n' % ((ab_b & 0xFFFF) | ((npsi & 0xFF) << 16) | ((K & 0xFF) << 24)))
            f.write('%08X\n' % (bases['env_e'][i] & 0xFFFF))
            f.write('%08X\n' % (bases['psi_e'][i] & 0xFFFF))
    print('  info       %d 字（%d 音 × 4）= 每音 K/npsi + 4 个 bank 基址'
          % (4 * len(midis), len(midis)))

    print('\n写出到 %s/' % a.outdir)
    nbit = {k: 0 for k in bins}
    for k in bins:
        wd = {'ab': 32, 'bc': 32, 'pi': 16, 'psi_e': 16, 'psi_o': 16,
              'env_e': 8, 'env_o': 8, 'phi': 32}[k]
        nbit[k] = len(data[k]) * wd
        print('  %-6s %7d 字 × %2d bit = %8.1f Kbit = %5.1f 块'
              % (k, len(data[k]), wd, nbit[k] / 1024.0, nbit[k] / 18432.0))
    tot_bit = sum(nbit.values())
    print('  %-6s %38.1f Kbit = %5.1f 块 (%.0f%%)'
          % ('合计', tot_bit / 1024.0, tot_bit / 18432.0, tot_bit / 6120e3 * 100))
    print('  再加 u 表 28 块 + sin 表 1 块 → %.0f 块 = %.0f%%'
          % (tot_bit / 18432.0 + 29, (tot_bit + 29 * 18432) / 6120e3 * 100))
    return 0


if __name__ == '__main__':
    sys.exit(main())
