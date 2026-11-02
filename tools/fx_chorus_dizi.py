#!/usr/bin/env python3
"""
fx_chorus_dizi.py —— 用【真实笛子素材】跑 CHORUS 各参数，暴露持续音上的问题

为什么必须单独做笛子版
----------------------
钢琴乐句是短衰减音，音高调制被包络掩蔽了；笛子是持续单音，
湿声被持续移调的缺陷在它身上才会彻底暴露 —— 用户上板反馈的
"笛子合唱音乱跳"就是这个问题。

素材
----
  data/_ref/ChineeWinds/wav/CWS_DiZi_1_FF/*.wav   （44.1 kHz，真实笛子强奏长音）
  重采样到 48828.125 Hz（FPGA 的 fs），线性插值。

参数与 tools/fx_chorus_range.py 完全一致（直接 import 复用）。

输出（out/fx_dizi/）
--------------------
  0_dry.wav / 1_chorus_strong.wav / a1..a4 / b1 / b2 / c1   （命名同 range 版）
"""
import os
import sys
import math
import wave
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import fx_chorus_range as R          # 复用参数表与定点流水线

SRC_DIR = os.path.join(os.path.dirname(ROOT), 'data', '_ref',
                       'ChineeWinds', 'wav', 'CWS_DiZi_1_FF')
OUTDIR  = os.path.join(ROOT, 'out', 'fx_dizi')
FS_OUT  = 48828.125
FS_IN   = 44100.0

#  乐句：A4 长音 3s → D5 长音 2s → A4 长音 3s（持续音为主）
PHRASE = [('A4_M00.wav', 3.0), ('D5_M00.wav', 2.0), ('A4_M00.wav', 3.0)]
XFADE  = 0.03          # 30 ms 交叉淡化


def read_wav_mono(path):
    """读 PCM wav，返回 float 列表（-1..1）"""
    with wave.open(path, 'rb') as w:
        nch = w.getnchannels()
        sw  = w.getsampwidth()
        n   = w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        vals = struct.unpack('<%dh' % (len(raw) // 2), raw)
        scale = 1.0 / 32768.0
    elif sw == 3:
        vals = []
        for i in range(0, len(raw), 3):
            v = raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16)
            if v & 0x800000:
                v -= 0x1000000
            vals.append(v)
        scale = 1.0 / 8388608.0
    elif sw == 4:
        vals = struct.unpack('<%di' % (len(raw) // 4), raw)
        scale = 1.0 / 2147483648.0
    else:
        raise RuntimeError('不支持的位深 %d' % sw)
    #  多声道取第一声道
    mono = [vals[i] * scale for i in range(0, len(vals), nch)]
    return mono


def resample(x, fs_in=FS_IN, fs_out=FS_OUT):
    """线性插值重采样"""
    n_out = int(len(x) * fs_out / fs_in)
    ratio = fs_in / fs_out
    out = [0.0] * n_out
    last = len(x) - 1
    for i in range(n_out):
        p = i * ratio
        i0 = int(p)
        if i0 >= last:
            out[i] = x[last]
            continue
        fr = p - i0
        out[i] = x[i0] * (1 - fr) + x[i0 + 1] * fr
    return out


def build_phrase():
    cache = {}
    segs = []
    for fn, dur in PHRASE:
        if fn not in cache:
            cache[fn] = resample(read_wav_mono(os.path.join(SRC_DIR, fn)))
        src = cache[fn]
        want = int(dur * FS_OUT)
        #  取样本的稳定段（跳过前 10% 起音，避免力度不均）并循环/截断到 want
        start = int(len(src) * 0.10)
        body = src[start:]
        if len(body) < want:
            rep = (want // max(len(body), 1)) + 1
            body = body * rep
        segs.append(body[:want])

    #  交叉淡化拼接
    xf = int(XFADE * FS_OUT)
    out = list(segs[0])
    for seg in segs[1:]:
        n = min(xf, len(out), len(seg))
        for i in range(n):
            a = i / n
            out[len(out) - n + i] = out[len(out) - n + i] * (1 - a) + seg[i] * a
        out += seg[n:]
    return out


def write_wav16(path, l, r):
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(int(round(FS_OUT)))
        blob = bytearray()
        for a, b in zip(l, r):
            blob += struct.pack('<hh',
                                max(-32768, min(32767, int(a))),
                                max(-32768, min(32767, int(b))))
        w.writeframes(bytes(blob))


def main():
    os.makedirs(OUTDIR, exist_ok=True)

    if not os.path.isdir(SRC_DIR):
        print(f"找不到笛子素材目录：{SRC_DIR}")
        return 1

    print("合成笛子乐句 ...")
    xf = build_phrase()
    pk = max(abs(v) for v in xf) or 1.0
    x = [int(round(v * 0.79 * 32767 / pk)) for v in xf]
    print(f"素材 {len(x)} 样点 = {len(x)/FS_OUT:.2f} s，峰值 {max(abs(v) for v in x)}\n")

    write_wav16(os.path.join(OUTDIR, '0_dry.wav'), x, x)

    for fn, dms, rate, gd, gw, roff, desc in R.CASES:
        c = R.cents(dms, rate)
        print(f"{fn:24s} {desc:38s} 移调 {c:5.1f} 音分 ...")
        l, r = R.run(x, dms, rate, gd, gw, roff)
        write_wav16(os.path.join(OUTDIR, fn), l, r)

    print(f"\n完成，文件在 {OUTDIR}")
    for f in sorted(os.listdir(OUTDIR)):
        print(f"  {f}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
