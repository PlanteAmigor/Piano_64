#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_song_v3.py —— 生成 v3 帧流曲谱文件（.BIN），直接拷进 SD 卡根目录即可播

帧格式与队友 Android App / FPGA v3 协议【逐字节一致】：
    A5 5A 03 | type | seq | len:LE16 | payload | crc16:LE16

    type=1 BEGIN  payload 8 字节 : count:u16  duration_ms:u32  timbre:u8  flags:u8
    type=2 DATA   payload       : offset:u16 + N 个 8 字节事件（N ≤ 32）
    type=3 END    payload 2 字节: count:u16

    事件 8 字节 : start_ms:u32 | note:u8 | dur_ms:u16 | vel:u8
    CRC16 : CCITT-FALSE，poly 0x1021，init 0xFFFF，覆盖从 A5 到 payload 末尾

音色与能力（来自队友 BoardProtocol.kt，已核对）：
    0 钢琴  MIDI 21–108   8 声部
    1 古筝  MIDI 38–86    8 声部
    2 唢呐  MIDI 69–96    1 声部
    3 笛子  MIDI 67–91    1 声部

用法：
    python3 tools/gen_song_v3.py                    # 生成到 tools/generated/
    python3 tools/gen_song_v3.py --out /run/media/amigor/INSTRU
"""

import argparse
import os
import struct
import sys

# ─────────────────────────────────────────────────────────────────────
#  协议常量
# ─────────────────────────────────────────────────────────────────────
VERSION = 3
BEGIN, DATA, END = 1, 2, 3
MAX_EVENTS = 2048  # piano64_3 event RAM capacity
MAX_PAYLOAD = 258
EVENTS_PER_FRAME = 32

TIMBRES = {
    0: ("钢琴", 21, 108, 8),
    1: ("古筝", 38, 86, 8),
    2: ("唢呐", 69, 96, 1),
    3: ("笛子", 67, 91, 1),
}


def crc16(data: bytes) -> int:
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def make_frame(ftype: int, payload: bytes, seq: int) -> bytes:
    assert len(payload) <= MAX_PAYLOAD, "payload 超过 258 字节"
    head = bytes([0xA5, 0x5A, VERSION, ftype, seq & 0xFF]) + struct.pack("<H", len(payload))
    body = head + payload
    return body + struct.pack("<H", crc16(body))


# ─────────────────────────────────────────────────────────────────────
#  音名 → MIDI
# ─────────────────────────────────────────────────────────────────────
_PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def nn(name: str) -> int:
    """'C4' → 60，'F#3' → 54，'Bb4' → 70"""
    p = _PC[name[0].upper()]
    i = 1
    while i < len(name) and name[i] in "#b":
        p += 1 if name[i] == "#" else -1
        i += 1
    return p + (int(name[i:]) + 1) * 12


# ─────────────────────────────────────────────────────────────────────
#  曲谱构建
# ─────────────────────────────────────────────────────────────────────
class Song:
    def __init__(self, name: str, timbre: int):
        self.name = name
        self.timbre = timbre
        self.events = []                                    # (start, note, dur, vel)

    def add(self, start: int, note: int, dur: int, vel: int = 90):
        self.events.append((int(start), int(note), int(dur), int(vel)))

    def line(self, start: int, notes, step: int, dur: int, vel: int = 90):
        """把一串音名/数字按固定步长排成旋律，0 表示休止"""
        for i, nt in enumerate(notes):
            if nt == 0:
                continue
            pitch = nn(nt) if isinstance(nt, str) else int(nt)
            self.add(start + i * step, pitch, dur, vel)
        return start + len(notes) * step

    def validate(self) -> int:
        label, low, high, voices = TIMBRES[self.timbre]
        if not self.events:
            raise SystemExit(f"[{self.name}] 没有音符")
        if len(self.events) > MAX_EVENTS:
            raise SystemExit(f"[{self.name}] 事件数 {len(self.events)} > {MAX_EVENTS}")
        self.events.sort(key=lambda e: (e[0], e[1]))
        for s, n, d, v in self.events:
            if not (low <= n <= high):
                raise SystemExit(f"[{self.name}] 音高 {n} 超出{label}音域 {low}–{high}")
            if not (1 <= d <= 65535):
                raise SystemExit(f"[{self.name}] 时长 {d} 非法")
            if not (1 <= v <= 127):
                raise SystemExit(f"[{self.name}] 力度 {v} 非法")
        peak = self.peak_voices()
        if peak > voices:
            raise SystemExit(f"[{self.name}] 峰值 {peak} 声部 > {label} 支持 {voices}")
        return peak

    def peak_voices(self) -> int:
        edges = []
        for s, _, d, _ in self.events:
            edges.append((s, 1))
            edges.append((s + d, -1))
        edges.sort(key=lambda e: (e[0], e[1]))              # 同一时刻先结束再开始
        cur = peak = 0
        for _, delta in edges:
            cur += delta
            peak = max(peak, cur)
        return peak

    def duration_ms(self) -> int:
        return max(s + d for s, _, d, _ in self.events)

    def encode(self) -> bytes:
        peak = self.validate()
        label = TIMBRES[self.timbre][0]
        total = self.duration_ms()

        begin = struct.pack("<HIBB", len(self.events), total, self.timbre, 0)
        out = bytearray(make_frame(BEGIN, begin, 0))

        for i in range(0, len(self.events), EVENTS_PER_FRAME):
            chunk = self.events[i:i + EVENTS_PER_FRAME]
            pay = bytearray(struct.pack("<H", i))
            for s, n, d, v in chunk:
                pay += struct.pack("<IBHB", s, n, d, v)
            out += make_frame(DATA, bytes(pay), (i // EVENTS_PER_FRAME) + 1)

        out += make_frame(END, struct.pack("<H", len(self.events)), 0xFF)
        print(f"  {self.name:<10} {label}  {len(self.events):>4} 事件  "
              f"{total:>6} ms  峰值 {peak} 声部  {len(out):>5} 字节")
        return bytes(out)


# ─────────────────────────────────────────────────────────────────────
#  曲目
# ─────────────────────────────────────────────────────────────────────
def song_piano() -> Song:
    """《小星星》4 声部：旋律 + 三度和声 + 低八度 + 低音根音（音域 36–83）"""
    s = Song("小星星-钢琴", 0)
    step, dur = 450, 400

    #  V0 旋律 C4 起
    mel = ["C4", "C4", "G4", "G4", "A4", "A4", "G4", "F4", "F4", "E4", "E4", "D4", "D4", "C4"]
    #  V1 三度上（C 大调内）
    third = ["E4", "E4", "B4", "B4", "C5", "C5", "B4", "A4", "A4", "G4", "G4", "F4", "F4", "E4"]

    s.line(0, mel, step, dur, vel=100)
    s.line(0, third, step, dur, vel=78)
    s.line(0, [nn(x) - 12 for x in mel], step, dur, vel=86)     # 低八度
    #  V3 低音：每 3 个音换一次根音（C2 / F2 / G2）
    for bar, root in enumerate(["C2", "F2", "G2", "C2", "C2"]):
        s.add(bar * step * 3, nn(root), step * 3 - 60, vel=72)
    return s


def song_guzheng() -> Song:
    """《茉莉花》3 声部：旋律 + 低八度 + 低音（音域 48–76）"""
    s = Song("茉莉花-古筝", 1)
    step, dur = 480, 440

    mel = ["E4", "E4", "G4", "A4", "C5", "C5", "A4", "G4",
           "G4", "A4", "G4", "E4", "D4", 0, 0]
    s.line(0, mel, step, dur, vel=98)
    s.line(0, [nn(x) - 12 if x else 0 for x in mel], step, dur, vel=80)
    for bar, root in enumerate(["C3", "F3", "G3", "C3"]):
        s.add(bar * step * 4, nn(root), step * 4 - 80, vel=70)
    return s


def song_suona() -> Song:
    """《小星星》单声部，移调到唢呐音域（72–81，限 69–96）"""
    s = Song("小星星-唢呐", 2)
    step, dur = 420, 380
    mel = ["C5", "C5", "G5", "G5", "A5", "A5", "G5", "F5", "F5", "E5", "E5", "D5", "D5", "C5"]
    s.line(0, mel, step, dur, vel=110)
    return s


def song_dizi() -> Song:
    """《茉莉花》单声部，移调到笛子音域（69–77，限 67–91）"""
    s = Song("茉莉花-笛子", 3)
    step, dur = 460, 420
    mel = ["A4", "A4", "C5", "D5", "F5", "F5", "D5", "C5",
           "C5", "D5", "C5", "A4", "G4", 0, 0]
    s.line(0, mel, step, dur, vel=104)
    return s


SONGS = [
    ("SONG01.BIN", song_piano),
    ("SONG02.BIN", song_guzheng),
    ("SONG03.BIN", song_suona),
    ("SONG04.BIN", song_dizi),
]


# ─────────────────────────────────────────────────────────────────────
#  自检：把生成的字节流重新解回来，确认和原始事件表一致
# ─────────────────────────────────────────────────────────────────────
def verify(blob: bytes, expect: list):
    p, got, hdr = 0, [], {}
    while p < len(blob):
        assert blob[p] == 0xA5 and blob[p + 1] == 0x5A, "帧头错误"
        assert blob[p + 2] == VERSION, "版本错误"
        ftype, _seq = blob[p + 3], blob[p + 4]
        ln = blob[p + 5] | (blob[p + 6] << 8)
        pay = blob[p + 7:p + 7 + ln]
        crc = blob[p + 7 + ln] | (blob[p + 8 + ln] << 8)
        assert crc == crc16(blob[p:p + 7 + ln]), f"CRC 错误 @ {p}"
        if ftype == BEGIN:
            hdr["count"], hdr["dur"], hdr["timbre"] = struct.unpack("<HIB", pay[:7])
        elif ftype == DATA:
            off = pay[0] | (pay[1] << 8)
            for k in range((ln - 2) // 8):
                e = pay[2 + k * 8: 10 + k * 8]
                got.append((struct.unpack("<I", e[0:4])[0], e[4],
                            struct.unpack("<H", e[5:7])[0], e[7]))
            assert off == len(got) - (ln - 2) // 8, "offset 不连续"
        p += 9 + ln

    assert hdr["count"] == len(expect), f"count 不符 {hdr['count']} != {len(expect)}"
    assert got == expect, "事件表回读不一致"
    assert hdr["dur"] == max(s + d for s, _, d, _ in expect), "duration 不符"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "generated"),
                    help="输出目录（可直接给 SD 卡挂载点）")
    args = ap.parse_args()

    if not os.path.isdir(args.out):
        os.makedirs(args.out)
    print(f"输出目录: {args.out}\n")

    for fname, builder in SONGS:
        s = builder()
        blob = s.encode()
        verify(blob, s.events)                              # 生成即自检
        path = os.path.join(args.out, fname)
        with open(path, "wb") as f:
            f.write(blob)
        print(f"        → {path}")

    print("\n全部通过：帧 CRC / count / duration / 事件回读 一致")


if __name__ == "__main__":
    main()
