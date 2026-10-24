#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
model_additive.py —— add_voice.v 的【逐位精确】Python 模型

用途有两个：
  1. 和 iverilog 仿出来的 tb_add_voice.out 逐样点对比 → 证明 RTL 写对了
  2. 快速试听/试参数：RTL 要跑 1024 个主时钟才出一个样点，iverilog 跑 1 秒
     音频要好几分钟；这个模型几秒就跑完，音质/包络可以立刻听。

用法：
    python3 tools/model_additive.py --note 60 --n 400 --cmp tb_add_voice.out
    python3 tools/model_additive.py --note 21 --n 24000 --wav /tmp/a0.wav
"""

import argparse
import math
import os
import struct
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)

FS = 50000000 / 16 / 64          # 48828.125 Hz
NSINE = 1024
NPART = 64
NOTE_LO = 21


# ══════════════════════════════════════════════════════════════════════
#  读 ROM
# ══════════════════════════════════════════════════════════════════════
# 音色表文件名前缀 / 音域 / 有没有起音项
TIMBRES = {
    "piano":  dict(prefix="add_param", note_lo=21, nnote=88, atk=0),
    "gz":     dict(prefix="gz_param",  note_lo=38, nnote=49, atk=0),  # 新表：D2..D6，无起音项
}
CUR = "piano"


def load_rom(timbre="piano"):
    global CUR
    CUR = timbre
    pre = TIMBRES[timbre]["prefix"]

    def rd(name):
        with open(os.path.join(PROJ, name)) as f:
            return [int(l.strip(), 16) for l in f if l.strip()]
    b0, b1, b2 = (rd("%s%d.hex" % (pre, i)) for i in range(3))
    b3 = b2                 # 兼容旧字段名
    b4 = [1] * len(b0)      # Rr 不再存（ATK=0），恒 1
    sine = rd("add_sine.hex")
    return b0, b1, b2, b3, b4, sine


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def sgn(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x & (1 << (bits - 1)) else x


def sat16(x):
    return max(-32768, min(32767, x))


# ══════════════════════════════════════════════════════════════════════
#  一个声部
# ══════════════════════════════════════════════════════════════════════
class Voice:
    def __init__(self, rom, note, release_tau=0.30, timbre="piano"):
        self.b0, self.b1, self.b2, self.b3, self.b4, self.sine = rom
        self.tb = TIMBRES[timbre]
        self.set_note(note)
        self.R_REL = max(1, round((1 << 32) / (release_tau * FS)))

    def set_note(self, note):
        self.note = note
        base = (note - self.tb["note_lo"]) * NPART
        self.p = []
        for k in range(NPART):
            i = base + k
            w = self.b1[i]
            v = self.b2[i]
            self.p.append(dict(
                inc=self.b0[i],
                w8=255,                          # ★ 模态模型 w≡1
                R1=w & 0xFFFFFFFF,               # ★ R1 满 32 位
                phi8=(v >> 8) & 0xFF,            # bank2 = {a16, phi8, 8'b0}
                R2=(w & 0xFFFFFF),               # RTL 里 R2 绑的是 R1 低 24 位
                a16=(v >> 16) & 0xFFFF,
                Rr=1,
            ))
        # 装载初值（起音项 er 从 0 开始；ATK=0 时直接给满刻度）
        FULL = 0xFFFFFFFF
        self.ph = [(q["phi8"] << 24) & 0xFFFFFFFF for q in self.p]
        self.e1 = [q["a16"] << 16 for q in self.p]
        self.e2 = [q["a16"] << 16 for q in self.p]
        self.er = [0 if self.tb["atk"] else FULL for q in self.p]

    def is_silent(self, thr=1 << 16):
        """包络已经衰到 16bit 输出为 0（对应 RTL 的 idle）"""
        return (all(e < thr for e in self.e1) and all(e < thr for e in self.e2))

    def atk_on(self):
        return self.tb["atk"]

    def sample(self, gate=True):
        """算一个输出样点（32 个分量串行相加），返回 16bit 有符号"""
        acc = 0
        for k in range(NPART):
            q = self.p[k]
            ph_n = (self.ph[k] + q["inc"]) & 0xFFFFFFFF
            i = (ph_n >> 22) & (NSINE - 1)
            frac = (ph_n >> 12) & 0x3FF
            word = self.sine[i]
            s0 = s16(word & 0xFFFF)
            s1 = s16((word >> 16) & 0xFFFF)
            ds = s1 - s0
            itp = ds * frac
            sv = s0 + (itp >> 10)                       # 算术右移
            amp1 = self.e1[k] >> 16
            amp2 = self.e2[k] >> 16
            dif = amp1 - amp2
            wt = dif * q["w8"]
            amp = amp2 + (wt >> 8)

            # ★ 起音上升项：ampr = amp × (er >> 16) >> 16
            if self.tb["atk"]:
                ampr = ((amp * (self.er[k] >> 16)) >> 16) & 0xFFFF
            else:
                ampr = amp & 0xFFFF

            pr = sv * ampr
            acc += pr >> 16                             # 算术右移

            R1 = self.R_REL if not gate else q["R1"]
            R2 = self.R_REL if not gate else q["R2"]
            d1 = ((self.e1[k] >> 8) * R1 + (1 << 23)) >> 24
            d2 = ((self.e2[k] >> 8) * R2 + (1 << 23)) >> 24
            self.e1[k] = self.e1[k] - d1
            self.e2[k] = self.e2[k] - d2

            # er ← er + (2^32 − er)·Rr/2^32
            if self.tb["atk"]:
                rem = (0x100000000 - self.er[k]) & 0x1FFFFFFFF
                dr = ((rem >> 8) * q["Rr"] + (1 << 23)) >> 24
                self.er[k] = (self.er[k] + dr) & 0xFFFFFFFF
            else:
                self.er[k] = 0xFFFFFFFF

            self.ph[k] = ph_n
        return sat16(acc)


# ══════════════════════════════════════════════════════════════════════
#  主程序
# ══════════════════════════════════════════════════════════════════════
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timbre", default="piano", choices=["piano", "gz"])
    ap.add_argument("--note", type=int, default=60)
    ap.add_argument("--n", type=int, default=400, help="输出样点数")
    ap.add_argument("--cmp", default=None, help="和 iverilog 的输出文件逐样点对比")
    ap.add_argument("--wav", default=None)
    ap.add_argument("--release", type=int, default=-1, help="第几个样点松开")
    a = ap.parse_args()

    rom = load_rom(a.timbre)
    v = Voice(rom, a.note, timbre=a.timbre)

    out = [v.sample(gate=(a.release < 0 or i < a.release)) for i in range(a.n)]

    if a.cmp:
        ref = [int(x) for x in open(a.cmp) if x.strip()]
        n = min(len(ref), len(out))
        # 找对齐：RTL 前面有 2 个样点的装载静音
        best, boff = None, 0
        for off in range(0, 6):
            if n - off <= 0:
                continue
            diff = sum(1 for i in range(n - off) if ref[i + off] != out[i])
            if best is None or diff < best:
                best, boff = diff, off
        print("★ 逐样点对比：RTL 偏移 %d 个样点，%d 个里 %d 个不一致"
              % (boff, n - boff, best))
        bad = [(i + boff, ref[i + boff], out[i]) for i in range(n - boff)
               if ref[i + boff] != out[i]]
        for r in bad[:10]:
            print("   样点 %d: RTL=%d 模型=%d" % r)
        if best == 0:
            print("   ✅ 完全一致")
        return

    if a.wav:
        peak = max(1, max(abs(x) for x in out))
        with wave.open(a.wav, "w") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(round(FS)))
            w.writeframes(struct.pack("<%dh" % len(out), *out))
        print("写出 %s  (%d 样点, %.3f s, 峰值 %d)" % (a.wav, len(out), len(out) / FS, peak))

    # 摘要
    peak = max(abs(x) for x in out)
    print("音色=%s  note=%d  n=%d  峰值=%d (%.1f dBFS)  末样点=%d"
          % (a.timbre, a.note, a.n, peak, 20 * math.log10(max(peak, 1) / 32768), out[-1]))


if __name__ == "__main__":
    main()
