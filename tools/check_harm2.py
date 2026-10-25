#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_harm2.py —— 校验 npz2hex_harm2.py 的打包【无损】

做法：把新旧两套 hex 各自解码成「每个谐波的 (env, A, phi_a, dm, Ψ行)」，然后用
完全相同的浮点公式重建波形，逐样点对比。打包只是重新分组比特，理应 0 误差。

用法：
    python3 check_harm2.py --old ../../.tmp/tables_harm --new ../../.tmp/tables_harm2 \\
        --prefix dizi --midi 67
"""
import argparse
import os
import sys

import numpy as np

FS = 48828.0
NT, NT2, NT3 = 600, 300, 150
PSI_E = PSI_O = NT2 // 2 + 1
ENV_E = ENV_O = NT3 // 2 + 1


def rd(p):
    return np.array([int(x, 16) for x in open(p).read().split()], dtype=np.int64)


def sx16(v):
    v = np.asarray(v, dtype=np.int64) & 0xFFFF
    return np.where(v >= 0x8000, v - 0x10000, v)


def sx8(v):
    v = np.asarray(v, dtype=np.int64) & 0xFF
    return np.where(v >= 0x80, v - 0x100, v)


def u_table(tab):
    p = os.path.join(tab, 'harm_u.hex')
    if not os.path.exists(p):
        p = os.path.join(os.environ.get('HARM_OLD_TAB', ''), 'harm_u.hex')
    return rd(p).astype(np.uint64)


def decode_old(tab, prefix, midi, lo):
    d = rd(os.path.join(tab, '%s_param.hex' % prefix))
    b = rd(os.path.join(tab, '%s_base.hex' % prefix))
    base = int(b[midi - lo])
    K = int(d[base] & 0xFF)
    npsi = int((d[base] >> 8) & 0xFF)
    oA = base + 2
    oPA, oDM, oSC, oPI = oA + K, oA + 2 * K, oA + 3 * K, oA + 4 * K
    oPHI = oA + 5 * K
    oPSI = oPHI + 2 * NT
    oENV = oPSI + npsi * NT2
    out = dict(
        K=K, npsi=npsi,
        A=sx16(d[oA:oA + K]), hPA=sx16(d[oPA:oPA + K]), DM=sx16(d[oDM:oDM + K]),
        SC=d[oSC:oSC + K] & 0xFFFF, PI=d[oPI:oPI + K] & 0xFFFF,
        PHI=(d[oPHI:oPHI + NT] | (d[oPHI + NT:oPHI + 2 * NT] << 16)),
        PSI=np.array([sx16(d[oPSI + r * NT2:oPSI + (r + 1) * NT2]) for r in range(npsi)]),
        ENV=np.array([sx8(d[oENV + m * NT3:oENV + (m + 1) * NT3]) for m in range(K)]),
    )
    return out


def decode_new(tab, prefix, midi, lo):
    idx = midi - lo
    ab = rd(os.path.join(tab, '%s_ab.hex' % prefix))
    bc = rd(os.path.join(tab, '%s_bc.hex' % prefix))
    pi = rd(os.path.join(tab, '%s_pi.hex' % prefix))
    pe = rd(os.path.join(tab, '%s_psi_e.hex' % prefix))
    po = rd(os.path.join(tab, '%s_psi_o.hex' % prefix))
    ee = rd(os.path.join(tab, '%s_env_e.hex' % prefix))
    eo = rd(os.path.join(tab, '%s_env_o.hex' % prefix))
    ph = rd(os.path.join(tab, '%s_phi.hex' % prefix))
    ba = rd(os.path.join(tab, '%s_base_ab.hex' % prefix))
    bp = rd(os.path.join(tab, '%s_base_pi.hex' % prefix))
    bpe = rd(os.path.join(tab, '%s_base_psi_e.hex' % prefix))
    bee = rd(os.path.join(tab, '%s_base_env_e.hex' % prefix))
    bph = rd(os.path.join(tab, '%s_base_phi.hex' % prefix))

    nb = rd(os.path.join(tab, '%s_base_bc.hex' % prefix))
    npe = rd(os.path.join(tab, '%s_base_psi_o.hex' % prefix))
    neo = rd(os.path.join(tab, '%s_base_env_o.hex' % prefix))
    assert ba[idx] == nb[idx] and bpe[idx] == npe[idx] and bee[idx] == neo[idx]

    aw = ab[ba[idx]:]
    K = int(np.argmax(np.cumsum(np.ones(200)) > 1e9)) if False else None
    # K 从「下一个音的基址」推出来
    if idx + 1 < len(ba):
        K = int(ba[idx + 1] - ba[idx])
    else:
        K = int(len(ab) - ba[idx])
    b0 = ba[idx]
    A = sx16(ab[b0:b0 + K])
    hPA = sx16((ab[b0:b0 + K] >> np.int64(16)) & 0xFFFF)
    b1 = bc[ba[idx]:ba[idx] + K]
    DM = sx16(b1 & 0xFFFF)
    SC = (b1 >> np.int64(16)) & 0xFFFF
    psi_off = pi[bp[idx]:bp[idx] + K]

    # Ψ：从 psi_off 反推行数
    npsi = 0
    for v in psi_off:
        npsi = max(npsi, int(v) // PSI_E + (0 if (int(v) % PSI_E) == 0 else 1))
    # 更稳：扫 base_psi_e 的下一行差
    if idx + 1 < len(bpe):
        rows = int((bpe[idx + 1] - bpe[idx]) // PSI_E) - 1
    else:
        rows = int((len(pe) - bpe[idx]) // PSI_E) - 1
    npsi = rows

    PSI = np.zeros((max(npsi, 1), NT2), dtype=np.int64)
    for r in range(npsi):
        e = pe[bpe[idx] + r * PSI_E: bpe[idx] + (r + 1) * PSI_E]
        o = po[bpe[idx] + r * PSI_O: bpe[idx] + (r + 1) * PSI_O]
        row = np.zeros(NT2, dtype=np.int64)
        row[0::2] = e[:NT2 // 2]
        row[1::2] = o[:NT2 // 2]
        PSI[r] = sx16(row)

    ENV = np.zeros((K, NT3), dtype=np.int64)
    for m in range(K):
        e = ee[bee[idx] + m * ENV_E: bee[idx] + (m + 1) * ENV_E]
        o = eo[bee[idx] + m * ENV_O: bee[idx] + (m + 1) * ENV_O]
        row = np.zeros(NT3, dtype=np.int64)
        row[0::2] = e[:NT3 // 2]
        row[1::2] = o[:NT3 // 2]
        ENV[m] = sx8(row)

    return dict(K=K, npsi=npsi, A=A, hPA=hPA, DM=DM, SC=SC,
                PI=(psi_off // PSI_E),   # 折回行号，方便和旧表比
                PHI=ph[bph[idx]:bph[idx] + NT], PSI=PSI, ENV=ENV)


def wave(tab_old, tab_new, prefix, midi, lo, n=2048):
    """按同一浮点公式重建两种解码的波形"""
    ut = u_table(tab_new)
    idx = np.arange(n)
    ui = (idx >> 4).astype(np.int64)
    uf = (idx & 0xF).astype(np.uint64)
    u = (ut[ui] + (((ut[ui + 1] - ut[ui]) * uf) >> np.uint64(4))).astype(np.float64) / float(1 << 32)
    t = idx / FS
    res = []
    for dec in (decode_old, decode_new):
        tb = tab_old if dec is decode_old else tab_new
        o = dec(tb, prefix, midi, lo)
        K = o['K']
        Phi = np.interp(u, np.linspace(0, 1, NT), o['PHI'] / float(1 << 19))
        s = np.zeros(n)
        for m in range(K):
            pi = int(o['PI'][m])
            psi = (np.interp(u, np.linspace(0, 1, NT2), o['PSI'][pi] / 4096.0)
                   if pi < len(o['PSI']) else np.zeros(n))
            env = np.interp(u, np.linspace(0, 1, NT3), o['ENV'][m]) / 127.0 * o['SC'][m] / 32768.0
            s += env * (o["A"][m] / 4096.0) * np.sin(
                2 * np.pi * (m * Phi + o['DM'][m] / 1000.0 * t + psi + o['hPA'][m] / 65536.0))
        res.append(32767 * s)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--old', required=True)
    ap.add_argument('--new', required=True)
    ap.add_argument('--prefix', default='dizi')
    ap.add_argument('--lo', type=int, default=67)
    ap.add_argument('--midis', default='67,72,79,85,91')
    a = ap.parse_args()

    worst = 0.0
    os.environ['HARM_OLD_TAB'] = a.old
    for mi in [int(x) for x in a.midis.split(',')]:
        wo, wn = wave(a.old, a.new, a.prefix, mi, a.lo)
        d = wo - wn
        rms_o = np.sqrt((wo ** 2).mean())
        rms_d = np.sqrt((d ** 2).mean())
        snr = 20 * np.log10(rms_o / rms_d) if rms_d > 0 else float('inf')
        worst = max(worst, rms_d)
        print('MIDI %2d  rms(旧)=%9.1f  rms(差)=%12.3e  SNR=%s'
              % (mi, rms_o, rms_d, ('∞（完全一致）' if rms_d == 0 else '%.1f dB' % snr)))
    print('\n结论：%s' % ('✓ 打包无损，新旧解码逐点一致' if worst == 0 else '✗ 有差异，需排查'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
