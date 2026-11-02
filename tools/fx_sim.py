#!/usr/bin/env python3
"""三种效果器（REVERB / DELAY / CHORUS）的立体声参考仿真。

目的：先用 CPU 定死参数、听感确认，再照这个写 RTL。

素材：out/piano/B_模态_<音名>K512_3s.wav（fs=48828 Hz, 16bit, mono）
      —— 就是模态表合成的音色，和 FPGA 输出一致。
输出：out/fx/fx_<效果>.wav（立体声 16bit 48828 Hz）

★ 所有延迟长度都取【整数样本】，所有增益都取【定点可实现】的值，
  参数可以直接搬到 RTL。
"""
import os
import wave
import numpy as np

FS = 48828.0          # 与 FPGA 的 fs 一致（50 MHz / 16 / 64）
D = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(D))          # /mnt/project/InstruementSound
SRC = os.path.join(ROOT, 'out', 'piano')
OUT = os.path.join(ROOT, 'out', 'fx')


# ─────────────────────────── 素材 ───────────────────────────
def read_note(name):
    p = os.path.join(SRC, 'B_模态_%sK512_3s.wav' % name)
    w = wave.open(p)
    n = w.getnframes()
    a = np.frombuffer(w.readframes(n), dtype='<i2').astype(np.float64) / 32768.0
    w.close()
    return a


def build_phrase():
    """C4-E4-G4-C5 分解和弦 + C 大三和弦。
       ★ 每个音只取 1 s 并 50 ms 淡出：钢琴原素材是 3 s，如果照搬，
         效果器的尾巴会被干声盖住，根本听不出区别。"""
    seq = [('C4', 0.00, 1.00), ('E4', 0.25, 1.00), ('G4', 0.50, 1.00), ('C5', 0.75, 1.00)]
    chord = [('C4', 1.10, 0.55), ('E4', 1.10, 0.55), ('G4', 1.10, 0.55), ('C5', 1.10, 0.45)]
    cache = {}
    total = int(6.0 * FS)          # 音到 2.1 s 全部结束，留 3.9 s 听尾巴
    out = np.zeros(total)
    nlen = int(1.0 * FS)
    fade = int(0.05 * FS)
    for name, when, gain in seq + chord:
        if name not in cache:
            a = read_note(name)[:nlen].copy()
            a[-fade:] *= np.linspace(1.0, 0.0, fade)
            cache[name] = a
        a = cache[name] * gain
        i = int(when * FS)
        m = min(len(a), total - i)
        out[i:i + m] += a[:m]
    return out


# ─────────────────────────── 工具 ───────────────────────────
def write_wav(path, L, R, gain=1.0):
    """按给定增益写立体声 16bit WAV（不自动归一化，方便四个文件互相对比）。"""
    L = np.clip(L * gain, -1, 1)
    R = np.clip(R * gain, -1, 1)
    li = (L * 32767).astype('<i2')
    ri = (R * 32767).astype('<i2')
    st = np.empty(len(L) * 2, dtype='<i2')
    st[0::2] = li
    st[1::2] = ri
    w = wave.open(path, 'wb')
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(int(round(FS)))
    w.writeframes(st.tobytes())
    w.close()
    rms = np.sqrt(((L ** 2 + R ** 2) / 2).mean())
    tail = np.sqrt(((L[int(3.5 * FS):] ** 2 + R[int(3.5 * FS):] ** 2) / 2).mean())
    body = np.sqrt(((L[int(1.1 * FS):int(2.1 * FS)] ** 2 + R[int(1.1 * FS):int(2.1 * FS)] ** 2) / 2).mean())
    print('  → %-20s 峰值 %.2f  RMS %.4f  3.5s 后尾巴 %.4f (主体 %.4f 的 %.0f%%)'
          % (os.path.basename(path), max(np.abs(L).max(), np.abs(R).max()), rms, tail, body,
             100 * tail / max(body, 1e-9)))


def rms(a):
    return float(np.sqrt((a ** 2).mean()))


def level_match(dry, wet, ratio):
    """把湿声缩放到 wet RMS = ratio × dry RMS，避免每个效果音量跳变。"""
    r = rms(wet)
    return wet * (ratio * rms(dry) / r) if r > 1e-9 else wet


# ─────────────────────────── 1. 混响（Freeverb）───────────────────────────
# Freeverb 原始参数是 44.1 kHz，按 48828/44100 = 1.1072 缩放并取整。
# 取整后的长度就是 RTL 里要用的延迟值，直接照抄。
REV_COMB = [1236, 1315, 1414, 1502, 1574, 1651, 1724, 1790]
REV_AP = [616, 488, 378, 249]
REV_SPREAD = 23              # 右声道比左声道每个延迟多 23 样本 → 立体声
REV_FB = 0.88                # 反馈系数（尾巴长度）≈ 1.4 s 的 RT60
REV_DAMP = 0.40              # 阻尼（高音衰减更快）
REV_WET = 0.45


def _comb_damped(x, Dlen, fb, damp):
    """带阻尼的梳状滤波器：
         y[n] = x[n] + fb*((1-damp)*y[n-Dlen] + damp*y[n-Dlen-1])
       输出取 y[n-Dlen]。"""
    n = len(x)
    a1 = fb * (1.0 - damp)
    a2 = fb * damp
    y = np.zeros(n)
    out = np.zeros(n)
    for i in range(n):          # ★ 从 0 开始：原来从 Dlen 起会把前面 Dlen
        v = x[i]                #   个输入样本直接丢掉（开头音头被吃）
        if i >= Dlen:
            v += a1 * y[i - Dlen]
            out[i] = y[i - Dlen]
        if i >= Dlen + 1:
            v += a2 * y[i - Dlen - 1]
        y[i] = v
    return out


def _allpass(x, Dlen, g=0.5):
    """Schroeder 全通：缓冲 = x + g*缓出，输出 = -g*x + 缓出。"""
    n = len(x)
    buf = np.zeros(Dlen)
    y = np.zeros(n)
    for i in range(n):
        j = i % Dlen
        b = buf[j]
        buf[j] = x[i] + g * b
        y[i] = b - g * x[i]
    return y


def reverb(x):
    mono = x * 0.5           # 单声道输入进混响，两个声道内部各自扩散
    chans = []
    for ch in (0, 1):
        off = 0 if ch == 0 else REV_SPREAD
        acc = np.zeros(len(x))
        for d in REV_COMB:
            acc += _comb_damped(mono, d + off, REV_FB, REV_DAMP)
        for d in REV_AP:
            acc = _allpass(acc, d + off)
        chans.append(acc * 0.25)
    return chans[0], chans[1]      # 纯湿声，干湿混合交给 main


# ─────────────────────────── 2. 延迟（立体声回声）───────────────────────────
DLY_L_MS = 375
DLY_R_MS = 250
DLY_FB = 0.38
DLY_WET = 0.45


def delay(x):
    """左右不同延迟时间 + 交叉反馈 → 打乒乓的立体声回声。
       L 延迟 375 ms、R 延迟 250 ms（48828 Hz 下的整数样本）。"""
    dl = int(DLY_L_MS * FS / 1000)
    dr = int(DLY_R_MS * FS / 1000)
    n = len(x)
    bl = np.zeros(dl)
    br = np.zeros(dr)
    ol = np.zeros(n)
    orr = np.zeros(n)
    for i in range(n):
        jl = i % dl
        jr = i % dr
        yl = bl[jl]
        yr = br[jr]
        # 交叉反馈：左的回声喂右，右的喂左 → 乒乓感
        bl[jl] = x[i] + DLY_FB * yr
        br[jr] = x[i] + DLY_FB * yl
        ol[i] = yl
        orr[i] = yr
    return ol, orr                # 纯湿声


# ─────────────────────────── 3. 合唱 ───────────────────────────
CHO_BASE_MS = 12.0
CHO_DEPTH_MS = 3.5
CHO_RATE = 0.6               # Hz
CHO_WET = 0.5


def _chorus_voice(x, t, phase):
    """单路调制延迟：延迟 = base + depth*sin(2π f t + phase)，线性插值。"""
    n = len(x)
    d = (CHO_BASE_MS + CHO_DEPTH_MS * np.sin(2 * np.pi * CHO_RATE * t + phase)) * FS / 1000.0
    idx = np.arange(n) - d
    out = np.zeros(n)
    i0 = np.floor(idx).astype(np.int64)
    fr = idx - i0
    ok = (i0 >= 0) & (i0 + 1 < n)
    out[ok] = (1 - fr[ok]) * x[i0[ok]] + fr[ok] * x[i0[ok] + 1]
    return out


def chorus(x):
    t = np.arange(len(x)) / FS
    # 左右 LFO 相位差 90°：一路在升、一路在降 → 真正的立体声展宽
    vl = _chorus_voice(x, t, 0.0)
    vr = _chorus_voice(x, t, np.pi / 2)
    return vl, vr                 # 纯湿声


# ─────────────────────────── main ───────────────────────────
def main():
    os.makedirs(OUT, exist_ok=True)
    x = build_phrase()
    x = x / max(np.abs(x).max(), 1e-9) * 0.55
    print('素材 fs=%.0f Hz，乐句 6.0 s（音到 2.1 s 结束，留 3.9 s 尾巴）\n' % FS)

    mixes = {'dry': (x, x)}

    wl, wr = reverb(x)
    mixes['reverb'] = _mix(x, wl, wr, 1.10)

    wl, wr = delay(x)
    mixes['delay'] = _mix(x, wl, wr, 1.10)

    wl, wr = chorus(x)
    mixes['chorus'] = _mix(x, wl, wr, 0.90)

    # 统一增益，让四个文件能直接 A/B
    pk = max(max(np.abs(L).max(), np.abs(R).max()) for L, R in mixes.values())
    G = 0.95 / pk

    print('[0] 干声（参考）')
    write_wav(os.path.join(OUT, 'fx_dry.wav'), *mixes['dry'], gain=G)
    print('\n[1] 混响 REVERB  梳状 %s  全通 %s  反馈 %.2f 阻尼 %.2f 立体声展宽 %d 样本'
          % (REV_COMB, REV_AP, REV_FB, REV_DAMP, REV_SPREAD))
    write_wav(os.path.join(OUT, 'fx_reverb.wav'), *mixes['reverb'], gain=G)
    print('\n[2] 延迟 DELAY  左 %d ms / 右 %d ms  反馈 %.2f  交叉反馈（乒乓）'
          % (DLY_L_MS, DLY_R_MS, DLY_FB))
    write_wav(os.path.join(OUT, 'fx_delay.wav'), *mixes['delay'], gain=G)
    print('\n[3] 合唱 CHORUS  基延 %.1f ms 深度 ±%.1f ms %.1f Hz  左右 LFO 相差 90°'
          % (CHO_BASE_MS, CHO_DEPTH_MS, CHO_RATE))
    write_wav(os.path.join(OUT, 'fx_chorus.wav'), *mixes['chorus'], gain=G)

    print('\n完成，文件在 %s' % OUT)


def _mix(x, wl, wr, ratio):
    """把左右湿声按同一个系数缩放到 ratio×干声RMS，加到干声上。"""
    r = np.sqrt((rms(wl) ** 2 + rms(wr) ** 2) / 2)
    k = ratio * rms(x) / r if r > 1e-9 else 0.0
    return x + wl * k, x + wr * k


if __name__ == '__main__':
    main()
