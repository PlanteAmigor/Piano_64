#!/usr/bin/env python3
"""谐波引擎表（dizi / suona）的频谱 + 相图对比。

谐波引擎的信号是   s(t) = Σ_m A_m·env_m(t)·sin(2π (m·f0 + DM_m)·t + Ψ_m + PA_m)
因为各分量都是 m·f0 的整数倍（+很小失谐），轨迹是一条【闭合曲线】，
所以重点看：
  - 有多少个谐波的幅度是同一量级（>10% 最大值）
  - DM_m 有多大（Hz）—— 决定图形多久散开
"""
import os, sys, numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

FS = 48828.125
PSI_E = 151
ENV_E = 76
D = os.path.dirname(os.path.abspath(__file__))
R = os.path.dirname(D)


def rd(name):
    p = os.path.join(R, name) if not os.path.isabs(name) else name
    with open(p) as f:
        return np.array([int(l, 16) for l in f if l.strip()], dtype=np.uint64)


def s16(v):
    v = v.astype(np.int64) & 0xFFFF
    return np.where(v >= 0x8000, v - 0x10000, v)


def note_info(pre, ni):
    info = rd('%s_info.hex' % pre)
    ab, bc = rd('%s_ab.hex' % pre), rd('%s_bc.hex' % pre)
    ph = rd('%s_phi.hex' % pre)
    pe, po = rd('%s_psi_e.hex' % pre), rd('%s_psi_o.hex' % pre)
    w0, w1, w2, w3 = info[ni * 4:ni * 4 + 4]
    phi_b, ab_b, env_b, psi_b = int(w0 & 0xFFFF), int(w1 & 0xFFFF), int(w2 & 0xFFFF), int(w3 & 0xFFFF)
    K = int((w1 >> 24) & 0xFF)
    A = s16(ab[ab_b:ab_b + K])
    PA = s16(ab[ab_b:ab_b + K] >> 16)
    DM = s16(bc[ab_b:ab_b + K])            # 0.001 Hz
    SC = s16(bc[ab_b:ab_b + K] >> 16)
    inc = int(ph[phi_b])
    f0 = inc * FS / 2.0 ** 32
    pi_off = rd('%s_pi.hex' % pre)[ab_b:ab_b + K]
    PSi = np.zeros(K)
    for m in range(K):
        r = int(pi_off[m]) // PSI_E
        src = pe if (m % 2 == 0) else po
        PSi[m] = s16(src[r * PSI_E:r * PSI_E + 1])[0] / 4096.0   # Q3.12
    return dict(A=A, PA=PA, DM=DM, SC=SC, f0=f0, PSi=PSi, K=K)


def synth(d, t):
    A = d['A'] / 32768.0
    f = (np.arange(1, d['K'] + 1)) * d['f0'] + d['DM'] * 0.001
    pa = d['PA'] / 16384.0 * 2 * np.pi
    ps = d['PSi'] * 2 * np.pi
    s = np.zeros_like(t)
    for m in range(d['K']):
        if abs(A[m]) < 1e-5:
            continue
        s += A[m] * np.cos(2 * np.pi * f[m] * t + pa[m] + ps[m])
    return s


def lpf(s, fc, order=2):
    from scipy.signal import butter, lfilter
    b, a = butter(order, fc / (FS / 2))
    return lfilter(b, a, s)


def agc(s, dec=4):
    s = s / max(np.abs(s).max(), 1e-12)
    d = dec / 24000.0
    pk = np.zeros_like(s)
    p = 0.0
    for i in range(len(s)):
        v = abs(s[i])
        p = v if v >= p else max(p - d, 0.0)
        pk[i] = p
    return np.where(pk > 1e-9, s / np.maximum(pk, 1e-12), 0.0)


def portrait(s, delta=24, half=96):
    g = agc(s)
    x, y = g[:-delta], g[delta:]
    return np.round(x * half + 128), np.round(y * half + 128)


def main():
    tmax = 0.35
    seg = int(0.020 * FS)
    rows, cols = [], []
    names = []
    for pre in ('dizi', 'suona'):
        info = rd('%s_info.hex' % pre)
        nnotes = info.size // 4
        for ni in (nnotes // 2,):
            d = note_info(pre, ni)
            A = np.abs(d['A'])
            big = np.nonzero(A > A.max() * 0.10)[0]
            print('%-6s note#%d  f0=%.2f Hz  K=%d  幅度>10%%的谐波数=%d  %s'
                  % (pre, ni, d['f0'], d['K'], len(big), (big + 1)[:12]))
            print('        A/Amax 前8 = %s' % np.round(A[big[:8]] / A.max(), 3))
            print('        DM(Hz) 前8 = %s   |DM|中位=%.3f 最大=%.3f'
                  % (np.round(d['DM'][big[:8]] * 0.001, 3),
                     np.median(np.abs(d['DM'])) * 0.001, np.abs(d['DM']).max() * 0.001))
            t = np.arange(int(tmax * FS)) / FS
            s = synth(d, t)
            env = []
            for ms in (5, 20, 50, 100, 200, 300):
                i = int(ms * 1e-3 * FS)
                env.append(np.sqrt(np.mean(s[max(i - 240, 0):i] ** 2)))
            print('       RMS @5/20/50/100/200/300ms = %s' %
                  [('%.3f' % (e / env[0])) for e in env])
            names.append('%s note#%d f0=%.0f' % (pre, ni, d['f0']))
            cols.append([('raw 200ms', s, int(0.20 * FS)),
                         ('raw 17ms', s, int(0.017 * FS)),
                         ('LP3k 17ms', lpf(s, 3000), int(0.017 * FS)),
                         ('LP1k 17ms', lpf(s, 1000), int(0.017 * FS)),
                         ('LP500 17ms', lpf(s, 500), int(0.017 * FS))])

    fig, axs = plt.subplots(len(cols), 5, figsize=(16, 3.1 * len(cols)))
    for r, row in enumerate(cols):
        for c, (lab, sig, w) in enumerate(row):
            xs, ys = portrait(sig[seg:seg + w])
            ax = axs[r][c]
            ax.plot(xs, ys, '-', lw=0.45, color='#ff8020')
            ax.set_xlim(0, 256); ax.set_ylim(0, 256)
            ax.set_aspect('equal'); ax.set_xticks([]); ax.set_yticks([])
            ax.set_title('%s  %s' % (names[r], lab), fontsize=8)
    plt.tight_layout()
    out = os.path.join(R, 'liss_harm.png')
    plt.savefig(out, dpi=110)
    print('→', out)


if __name__ == '__main__':
    main()
