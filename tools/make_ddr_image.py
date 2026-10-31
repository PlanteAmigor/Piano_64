#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_ddr_image.py —— 生成 P64.BIN（DDR 上电镜像，由 SD 卡灌入 DDR3）

【为什么要有这个工具】
    总架构规定：DDR 只是"仓库"，掉电丢，上电由 SD 卡灌入。
    BSRAM 里的 add_param0..2.hex / gz_param0..2.hex 必须搬到 DDR，
    才能腾出 BSRAM 给更多声部和谐波预取缓冲。

【DDR 布局（单位 = 256 bit = 32 字节 = 1 个 DDR 用户口地址）】
    word 0                    32 B  文件头
    word PIANO_BASE ..        钢琴表  88 音 × 64 word
    word GZ_BASE    ..        古筝表  49 音 × 64 word
    （后面给唢呐谐波表预留）

    ★ 格式 v2（当前）：按分量交错，每 256 位字装 2 个完整分量，
      每分量 16 字节 {d0, d1, d2, 0}。所以每音 = 128/2 = 64 字。
      钢琴 1 .. 5632，古筝 5633 .. 8768，total_words = 8769。

    ⚠️ 历史教训（v1，已废弃）：v1 用「平面 / planar」布局，每音 48 字，
      即 bank0 的 128 个 d0（16 字）、bank1 的 128 个 d1（16 字）、
      bank2 的 128 个 d2（16 字）分三块放。
      代价：RTL 取一个音的 128 个分量要跨 3 个不相邻区、按 16 字跳转，
      极其繁琐易错。
      ★ 如果 SD 卡上留着 v1 的 P64.BIN 而 RTL 按 v2 读，症状是：
        钢琴音高音色全乱（读到别的音）、古筝完全没声（读到空白区）。
        串口 HT 会显示 000019B1（6577）而不是 00002241（8769）。
        看到这个数字就先怀疑 SD 卡文件是旧的。

【文件头（32 字节，全部小端）】
    偏移  长度  内容
     0     4    magic  b"P64I"
     4     1    version = 1
     5     1    n_inst  = 2（钢琴 / 古筝）
     6     2    保留 0
     8     4    total_words  含文件头
    12     4    checksum     = 其后全部字节按 32 位小端累加（自然溢出）
    16     4    piano_base_word
    20     4    piano_note_lo
    24     4    gz_base_word
    28     4    gz_note_lo

用法：
    python3 tools/make_ddr_image.py
    # 输出 P64.BIN（拷到 SD 卡根目录，文件名必须是 8.3 的 P64.BIN）
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # piano64_3/

NPART = 128
# ★ 格式 v2：按分量排布（取代 v1 的平面排布）
#   每个 256 位字装 2 个完整分量，每分量 16 字节 {d0, d1, d2, 0}
#   → 每音 64 个 256 位字。
#   好处：DDR 取表变成纯顺序流，一拍回来正好 2 个分量，
#         不需要跨拍解交错，也不需要中间缓冲。
COMP_PER_WORD  = 2
WORDS_PER_NOTE = NPART // COMP_PER_WORD        # 64

PIANO_NOTE_LO, PIANO_NOTE_HI = 21, 108   # 88 音
GZ_NOTE_LO,    GZ_NOTE_HI    = 38, 86    # 49 音


def read_hex(path):
    """读 $readmemh 格式：每行一个 8 位十六进制数（可带 0x 前缀）。"""
    out = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//"):
                continue
            # 允许 "0x1234ABCD" / "1234ABCD"
            if s.lower().startswith("0x"):
                s = s[2:]
            s = s.split()[0]
            try:
                v = int(s, 16)
            except ValueError:
                raise SystemExit(f"{path}:{ln}: 无法解析 {line!r}")
            if not (0 <= v <= 0xFFFFFFFF):
                raise SystemExit(f"{path}:{ln}: 超出 32 位 {s}")
            out.append(v)
    return out


def load_3bank(prefix, note_lo, note_hi, tag):
    """把 <prefix>0/1/2.hex 读成 [note][bank][part] 的三维列表。"""
    banks = []
    for b in range(3):
        fn = os.path.join(ROOT, f"{prefix}{b}.hex")
        if not os.path.exists(fn):
            raise SystemExit(f"缺少文件 {fn}")
        banks.append(read_hex(fn))

    nnote = note_hi - note_lo + 1
    expect = nnote * NPART
    for b, arr in enumerate(banks):
        if len(arr) != expect:
            raise SystemExit(
                f"{tag} bank{b}: 行数 {len(arr)} != 期望 {expect}"
                f"（{nnote} 音 × {NPART} 分量）")

    # data[note][bank] = [NPART] 个 32 位值
    data = []
    for n in range(nnote):
        data.append([banks[b][n * NPART:(n + 1) * NPART] for b in range(3)])
    return data, nnote


def pack_instrument(data, nnote):
    """按分量打包：每 256 位字 = 2 个分量，每分量 16 字节 {d0, d1, d2, 0}。

    data[n][b][k] = 第 n 音、第 b 个 bank、第 k 个分量的 32 位值。
    """
    out = bytearray()
    for n in range(nnote):
        d0 = data[n][0]
        d1 = data[n][1]
        d2 = data[n][2]
        for k in range(NPART):
            out += struct.pack("<III I", d0[k], d1[k], d2[k], 0)
    assert len(out) == nnote * NPART * 16 == nnote * WORDS_PER_NOTE * 32
    return bytes(out)


def words_of(blob):
    assert len(blob) % 32 == 0
    return len(blob) // 32


def main():
    piano, p_n = load_3bank("add_param", PIANO_NOTE_LO, PIANO_NOTE_HI, "piano")
    gz,    g_n = load_3bank("gz_param",  GZ_NOTE_LO,    GZ_NOTE_HI,    "guzheng")

    p_blob = pack_instrument(piano, p_n)     # 88*64 = 5632 word = 180224 B
    g_blob = pack_instrument(gz, g_n)        # 49*64 = 3136 word = 100352 B

    p_base = 1
    g_base = p_base + words_of(p_blob)
    total_words = g_base + words_of(g_blob)

    body = p_blob + g_blob

    # 校验和：body 按 32 位小端累加
    chk = 0
    for i in range(0, len(body), 4):
        chk = (chk + struct.unpack_from("<I", body, i)[0]) & 0xFFFFFFFF

    header = struct.pack(
        "<4sBBHIIIIII",
        b"P64I",          # magic
        2,                # version（v2 = 按分量排布）
        2,                # n_inst
        0,                # 保留
        total_words,      # total_words
        chk,              # checksum
        p_base,           # piano_base_word
        PIANO_NOTE_LO,
        g_base,           # gz_base_word
        GZ_NOTE_LO,
    )
    assert len(header) == 32, len(header)

    img = header + body
    out_path = os.path.join(ROOT, "..", "P64.BIN")
    out_path = os.path.normpath(out_path)
    with open(out_path, "wb") as f:
        f.write(img)

    print(f"piano   {p_n} 音  base_word={p_base:6d}  {words_of(p_blob):6d} word")
    print(f"guzheng {g_n} 音  base_word={g_base:6d}  {words_of(g_blob):6d} word")
    print(f"total   {total_words} word = {len(img)} B = {len(img)/1024:.1f} KiB")
    print(f"checksum 0x{chk:08X}")
    print(f"输出 {out_path}")


if __name__ == "__main__":
    main()
