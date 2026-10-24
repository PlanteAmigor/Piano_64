#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_modal_rom.py —— 从【模态模型】公式表生成 add_voice 的 5-bank 参数 ROM

模型（公式表里的定义）：
    s(t) = Σ_k a_k · e^(−t/τ_k) · cos(2π f_k t + φ_k)

对应到本工程的 5-bank 格式（RTL 是通用的，这里只是把 w 固定成 1）：

    bank0 = inc[31:0]             相位增量 = round(f · 2^32 / fs)
    bank1 = R1[31:0]              ★ 满 32 位（模态模型 w≡1，低 8 位让给 R1）
                                  R1 = round(2^32 / (τ · fs))
    bank2 = { a16[15:0], phi8[7:0], 8'b0 }
                                  a16  = round(a · A_SCALE)
                                  phi8 = round((φ − π/2)/2π · 256)   ★ 见下
    ★ 只占 3 个 bank：R2/Rr 全是死数据（w≡1 让 e2 恒等 e1；两个音色都 ATK=0）
    bank4 = Rr                    起音项，ATK=0 时不用，填 1

为什么 R1 必须是 32 位：
    新表的 τ 最小到 0.5 ms → R1 = 2^32/(0.5ms·48828) ≈ 1.76e8
    24 位上限只有 1.68e7，会截断 10 倍，衰减直接变慢。

用法：
    python3 gen_modal_rom.py --table <公式表.md> --note-lo 21 --prefix add_param --scale 3000
"""
import argparse, math, os, re, sys

FS = 48828.125
NPART_DEFAULT = 64          # 可用 --npart 覆盖（128 / 256 ...）
LIM24 = (1 << 24) - 1
LIM32 = (1 << 32) - 1

# 表行： | # | f (Hz) | τ (ms) | a | dB | φ (°) |
ROW = re.compile(
    r'^\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|'
    r'\s*([-\d.]+)\s*\|\s*([-\d.]+)\s*\|\s*$', re.M)
HEAD = re.compile(r'MIDI\s+(\d+)')
# ★ 笛子表的段头格式是 '### M067　G4'（没有 MIDI 字样）→ 补一个兼容正则
HEAD_M = re.compile(r'^\s*###\s*M(\d+)', re.M)


def parse(path):
    """返回 {midi: [(f, tau_s, a, phase_rad), ...]}，按表里的顺序（幅度降序）"""
    notes = {}
    for sec in re.split(r'\n### ', open(path, encoding='utf-8').read())[1:]:
        head = sec.split('\n')[0]
        m = HEAD.search(head) or HEAD_M.search('### ' + head)
        rows = ROW.findall(sec)
        if not m or not rows:
            continue
        notes[int(m.group(1))] = [
            (float(r[1]), float(r[2]) * 1e-3, float(r[3]), math.radians(float(r[5])))
            for r in rows]
    return notes


def clamp(x, lo, hi):
    return max(lo, min(hi, int(x)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--table', required=True)
    ap.add_argument('--note-lo', type=int, required=True, help='最小 MIDI 音号')
    ap.add_argument('--prefix', required=True, help='输出前缀，如 add_param / gz_param')
    ap.add_argument('--scale', type=float, default=None, help='A_SCALE；不填只做标定建议')
    ap.add_argument('--outdir', default='.')
    ap.add_argument('--normalize', type=int, default=0,
                    help='逐音峰值归一化到该值（0=不归一化）。'
                         '新表的 a 是每音绝对幅度，录音电平没统一，各音能差 24 dB')
    ap.add_argument('--npart', type=int, default=NPART_DEFAULT,
                    help='每音取前多少个模态（默认 %d）' % NPART_DEFAULT)
    a = ap.parse_args()
    NPART = a.npart
    if NPART < 1:
        print('  ✗ --npart 必须 ≥ 1')
        return 1

    notes = parse(a.table)
    midis = sorted(notes)
    nnote = len(midis)
    steps = [midis[i] - midis[i-1] for i in range(1, nnote)]
    print('解析: %d 音  MIDI %d..%d' % (nnote, midis[0], midis[-1]))
    if any(s != 1 for s in steps):
        print('  ✗ 音号不连续，缺: %s' % [m for m in range(midis[0], midis[-1]+1) if m not in notes])
        return 1
    if midis[0] != a.note_lo:
        print('  ✗ 最小音号 %d ≠ note_lo %d' % (midis[0], a.note_lo))
        return 1

    used = {m: notes[m][:NPART] for m in midis}

    # ── 逐音峰值归一化 ──────────────────────────────────────────
    #   合成一小段找实际波形峰值。窗口 2400 点(49ms)够覆盖 A0 的 36ms 周期。
    #   （试过按能量 Σa²τ 归一化：解析快，但古筝逐音峰值波动 27 dB，更差）
    NPK = 2400
    if a.normalize > 0:
        print('  逐音峰值归一化 → 目标 %d' % a.normalize)
        gains = {}
        for m in midis:
            modes = used[m]; pk = 0.0
            for i2 in range(NPK):
                t = i2 / FS; v = 0.0
                for f, tau, amp, ph in modes:
                    v += amp * math.exp(-t / tau) * math.cos(2 * math.pi * f * t + ph)
                if abs(v) > pk: pk = abs(v)
            gains[m] = a.normalize / pk if pk > 1e-9 else 0.0
        gv = [g for g in gains.values() if g > 0]
        print('    增益范围 %.4f .. %.4f（%.1f dB 跨度）'
              % (min(gv), max(gv), 20 * math.log10(max(gv) / min(gv))))
        used = {m: [(f, tau, amp * gains[m], ph) for (f, tau, amp, ph) in used[m]]
                for m in midis}
        print('    归一化后 a 最大 = %.4f' % max(r[2] for v in used.values() for r in v))

    nmode = sum(len(v) for v in used.values())
    maxa = max(r[2] for v in used.values() for r in v)
    print('  取前 %d 模态/音，共 %d 个（原表共 %d）'
          % (NPART, nmode, sum(len(v) for v in notes.values())))
    empty = [m for m in midis if len(used[m]) < NPART]
    if empty:
        print('  ⚠ 模态数不足 %d 的音: %s（将补零）' % (NPART, empty))
    print('  前%d模态里 a 最大 = %.4f  → A_SCALE 上限 = %d（16 位）'
          % (NPART, maxa, int(65535 / maxa)))

    # τ 检查
    taus = [r[1] for v in used.values() for r in v]
    n_over = sum(1 for t in taus if 2**32 / (t * FS) > LIM32)
    print('  τ 范围 %.4f .. %.1f ms；R1 需要 %d..%d 位'
          % (min(taus)*1e3, max(taus)*1e3,
             math.ceil(math.log2(2**32/(max(taus)*FS))),
             math.ceil(math.log2(2**32/(min(taus)*FS)))))
    print('  32 位溢出: %d 个 %s' % (n_over, '✓' if n_over == 0 else '✗'))

    if a.scale is None:
        if a.normalize > 0:
            a.scale = 65535.0 / maxa * 0.98           # 自动填满 16 位（★ 必须浮点）
            print('  自动 A_SCALE = %d' % a.scale)
        else:
            print('\n没给 --scale，只做标定建议。')
            return 0
    S = a.scale
    if maxa * S > 65535:
        print('  ✗ A_SCALE=%.0f 会让 a16 溢出（%.0f > 65535）' % (S, maxa*S))
        return 1

    banks = [[], [], []]
    amax16 = 0
    for m in midis:
        for k in range(NPART):
            if k < len(used[m]):
                f, tau, amp, ph = used[m][k]
                inc = clamp(round(f * (1 << 32) / FS), 1, LIM32)
                R1  = clamp(round((1 << 32) / (tau * FS)), 1, LIM32)
                R2  = min(R1, LIM24)
                # ★★ 相位 90° 修正（这个坑从最早的版本就埋着）
                #    公式表定义的模型是  s = Σ a·e^(−t/τ)·cos(2πft + φ)
                #    但 add_sine.hex 是【sin】表，RTL 实际算 cos(…+φ)?
                #    sin(θ+φ) = cos(θ+φ−90°)，所以生成时必须把 φ 减去 π/2。
                #    不修正的后果：相当于对每个模态做希尔伯特变换，
                #    拟合出来的相位抵消关系被破坏 → 波形不对、逐音峰值乱跳
                #    （实测 1860~5245，而正确时是 3904~3977）。
                phi8 = int(round((ph - math.pi / 2) / (2 * math.pi) * 256)) & 0xFF
                a16 = clamp(round(amp * S), 0, 65535)
            else:
                inc, R1, R2, phi8, a16 = 0, 1, 1, 0, 0
            banks[0].append(inc)
            banks[1].append(R1)                    # R1 满 32 位
            banks[2].append((a16 << 16) | (phi8 << 8))
            amax16 = max(amax16, a16)

    print('\n  A_SCALE=%.0f → a16 最大 %d / 65535 (%.1f%%)' % (S, amax16, 100*amax16/65535))
    for i, b in enumerate(banks):
        fn = os.path.join(a.outdir, '%s%d.hex' % (a.prefix, i))
        with open(fn, 'w') as f:
            for v in b:
                f.write('%08X\n' % v)
        print('  写出 %s  (%d 行)' % (fn, len(b)))
    print('  总 %d 字 × %d bank × 32bit = %.0f kbit ≈ %d 块 BSRAM/声部'
          % (len(banks[0]), len(banks), len(banks[0])*len(banks)*32/1000,
             math.ceil(len(banks[0])*len(banks)*32/18432)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
