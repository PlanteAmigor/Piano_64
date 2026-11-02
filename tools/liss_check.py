#!/usr/bin/env python3
"""liss_check.py —— 用真实 ROM 参数离线复算李萨如相图

目的：搞清楚「钢琴/古筝/笛子 相图糊成一坨」到底是
      余辉太长、还是信号本身就把相平面填满了。

数据源与 RTL 完全一致：
    add_param0.hex = inc  (相位增量)  f = inc*FS/2^32
    add_param1.hex = R1   (衰减指数)  tau = 2^32/(R1*FS)
    add_param2.hex = (a16<<16)|(phi8<<8)
合成式（见 gen_modal_rom.py 的注释）：
    s(t) = Σ a·e^(-t/tau)·cos(2πf t + φ)

用法：
    python3 tools/liss_check.py            # 生成 liss_check.png + 打印统计
"""
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

FS = 48828.125
NP = 128


def load(prefix):
    b = []
    for i in range(3):
        b.append(np.array([int(l, 16) for l in open(prefix + '%d.hex' % i) if l.strip()],
                          dtype=np.uint64))
    return b


def synth(b, midi, lo, tmax):
    i0 = (midi - lo) * NP
    inc = b[0][i0:i0 + NP].astype(np.float64)
    R1 = b[1][i0:i0 + NP].astype(np.float64)
    a16 = (b[2][i0:i0 + NP] >> np.uint64(16)).astype(np.float64)
    phi8 = ((b[2][i0:i0 + NP] >> np.uint64(8)) & np.uint64(0xFF)).astype(np.float64)
    f = inc * FS / 2.0 ** 32
    tau = 2.0 ** 32 / (np.maximum(R1, 1) * FS)
    a = a16 / 65536.0
    ph = phi8 / 256.0 * 2 * np.pi + np.pi / 2

    n = int(tmax * FS)
    t = np.arange(n) / FS
    s = np.zeros(n)
    for k in range(NP):
        if inc[k] == 0 or a[k] == 0:
            continue
        s += a[k] * np.exp(-t / tau[k]) * np.cos(2 * np.pi * f[k] * t + ph[k])
    return s, f, a


def agc(s, dec=4):
    """峰值跟随：瞬时攻击 / 每样点 -dec。
    ★ dec=4 是 RTL 里的绝对量（信号是 ±24000），所以这里先按峰值缩放到
      同一个量纲，否则峰值每样点就归零、输出变成 0/1 方波。"""
    s = s / max(np.abs(s).max(), 1e-12)
    d = dec / 24000.0
    pk = np.zeros_like(s)
    p = 0.0
    for i in range(len(s)):
        v = abs(s[i])
        if v >= p:
            p = v
        else:
            p = max(p - d, 0.0)
        pk[i] = p
    return np.where(pk > 1e-9, s / np.maximum(pk, 1e-12), 0.0)


def lpass(s, fc, order=2):
    """级联一阶低通（order 级）"""
    if fc is None:
        return s
    a = 1.0 - np.exp(-2 * np.pi * fc / FS)
    y = s.copy()
    for _ in range(order):
        z = 0.0
        out = np.empty_like(y)
        for i in range(len(y)):
            z += a * (y[i] - z)
            out[i] = z
        y = out
    return y


def portrait(s, delta=24, half=96):
    x = s[:len(s) - delta]
    y = s[delta:]
    return np.round(x * half + 128), np.round(y * half + 128)


def render(ax, xs, ys, title):
    ax.plot(xs, ys, '-', lw=0.45, color='#ff8020')
    ax.set_xlim(0, 256); ax.set_ylim(0, 256)
    ax.set_aspect('equal')
    ax.set_title(title, fontsize=8)
    ax.set_xticks([]); ax.set_yticks([])


def main():
    b = load('add_param')
    lo, hi = 21, 108
    cases = [(60, 'C4 piano'), (72, 'C5 piano')]
    fig, axs = plt.subplots(2, 6, figsize=(18, 6.4))

    W17 = int(0.017 * FS)     # L4 拖尾 17 ms
    W200 = int(0.200 * FS)    # L1 拖尾 200 ms

    for r, (midi, name) in enumerate(cases):
        s, f, a = synth(b, midi, lo, 0.35)
        f0 = 440.0 * 2 ** ((midi - 69) / 12.0)
        sig = a > a.max() * 0.01
        ratio = f[sig] / f0
        dev = np.abs(ratio - np.round(ratio))
        env = [np.abs(s[int(t * FS):int(t * FS) + 480]).max() for t in
               (0.005, 0.02, 0.05, 0.1, 0.2, 0.3)]
        print('%s (MIDI %d): f0=%.1f Hz, 分量 %d, f/f0 偏离 中位 %.4f 最大 %.4f'
              % (name, midi, f0, sig.sum(), np.median(dev), dev.max()))
        print('   包络 @5/20/50/100/200/300ms = %s (峰值 %.3f)' %
              (['%.3f' % (e / env[0]) for e in env], env[0]))

        seg0 = int(0.020 * FS)     # 起音后 20 ms（钢琴衰减很快，必须靠前）
        for c, (fc, ordv, w, ttl) in enumerate([
                (None, 0, W200, 'raw 200ms'),
                (None, 0, W17,  'raw 17ms'),
                (3000, 2, W17,  'LP3k 17ms'),
                (1000, 2, W17,  'LP1k 17ms'),
                (500, 4, W17,   'LP500 17ms'),
                (300, 4, W17,   'LP300 17ms')]):
            v = lpass(s, fc, ordv) if fc else s
            g = agc(v)[seg0:seg0 + w]
            xs, ys = portrait(g)
            render(axs[r][c], xs, ys, '%s  %s' % (name, ttl))

    plt.tight_layout()
    plt.savefig('liss_check.png', dpi=110)
    print('→ liss_check.png')


if __name__ == '__main__':
    main()
