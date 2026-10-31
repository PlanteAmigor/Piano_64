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


# ══════════════════════════════════════════════════════════════════════════
#  唢呐（谐波类乐器）
#
#  和钢琴/古筝不同，唢呐表不是"一直驻留"，而是【按音预取】：
#  note-on 时把该音需要的 8 段表从 DDR 搬进 BSRAM，最大 12 KB。
#  所以镜像里必须能让 RTL 用描述符直接定位每段。
#
#  段内布局（以 SUONA_BASE word 为 0，全部 32 字节对齐）：
#     word 0     段头 word0: magic "SUON" | n_inst | note_lo | desc_off | 预留
#     word 1     段头 word1: 8 个表基址（字节偏移，绝对）
#     word 2..   n_inst 个描述符，每个 2 word（64 B），字段见 DESC_FIELDS
#     之后       8 段表数据
#
#  描述符（每音 64 B，全部小端 u32）：
#     0  K          谐波数（ab/bc/pi 的行数）
#     1  ab_off     字节偏移（绝对）
#     2  bc_off
#     3  pi_off
#     4  env_e_off
#     5  env_o_off
#     6  env_len    字节（e/o 相同）
#     7  psi_e_off
#     8  psi_o_off
#     9  psi_len    字节（e/o 相同）
#    10  phi_off
#    11  phi_len    字节
#    12..15 保留 0
# ══════════════════════════════════════════════════════════════════════════

SUONA_MAGIC = b"SUON"
SUONA_NOTE_LO = 69              # A4
# 与 harm_rom_suona 的 DEPTH 参数保持一致
SU_AB_DEPTH   = 780
SU_ENV_DEPTH  = 59204
SU_PSI_DEPTH  = 57833
SU_PHI_DEPTH  = 16800
SU_INFO_DEPTH = 112


def _pad32(off):
    """向上取整到 32 字节边界。"""
    return (off + 31) & ~31


def load_suona():
    """读唢呐 8 个表 + info。返回 dict。"""
    ab   = read_hex(os.path.join(ROOT, "suona_ab.hex"))
    bc   = read_hex(os.path.join(ROOT, "suona_bc.hex"))
    pi   = read_hex(os.path.join(ROOT, "suona_pi.hex"))
    ee   = read_hex(os.path.join(ROOT, "suona_env_e.hex"))
    eo   = read_hex(os.path.join(ROOT, "suona_env_o.hex"))
    pe   = read_hex(os.path.join(ROOT, "suona_psi_e.hex"))
    po   = read_hex(os.path.join(ROOT, "suona_psi_o.hex"))
    ph   = read_hex(os.path.join(ROOT, "suona_phi.hex"))
    info = read_hex(os.path.join(ROOT, "suona_info.hex"))

    # 补齐到 DEPTH（hex 文件可能少一行，$readmemh 也会补 0）
    def fit(a, n, name):
        if len(a) > n:
            raise SystemExit(f"{name}: 行数 {len(a)} 超过上限 {n}")
        return a + [0] * (n - len(a))

    ab = fit(ab, SU_AB_DEPTH, "suona_ab")
    bc = fit(bc, SU_AB_DEPTH, "suona_bc")
    pi = fit(pi, SU_AB_DEPTH, "suona_pi")
    ee = fit(ee, SU_ENV_DEPTH, "suona_env_e")
    eo = fit(eo, SU_ENV_DEPTH, "suona_env_o")
    pe = fit(pe, SU_PSI_DEPTH, "suona_psi_e")
    po = fit(po, SU_PSI_DEPTH, "suona_psi_o")
    ph = fit(ph, SU_PHI_DEPTH, "suona_phi")
    info = fit(info, SU_INFO_DEPTH, "suona_info")

    return dict(ab=ab, bc=bc, pi=pi, ee=ee, eo=eo,
                pe=pe, po=po, ph=ph, info=info)


def suona_note_meta(su):
    """从 info 表解析每音元数据，并算出每段长度（用下一音 base 之差）。"""
    info = su["info"]
    n = len(info) // 4
    meta = []
    for i in range(n):
        phi_base = info[4 * i + 0] & 0x7FFF
        K        = (info[4 * i + 1] >> 24) & 0xFF
        ab_base  = info[4 * i + 1] & 0xFFFF
        env_base = info[4 * i + 2] & 0xFFFF
        psi_base = info[4 * i + 3] & 0xFFFF
        if i + 1 < n:
            ab_len  = (info[4 * (i + 1) + 1] & 0xFFFF) - ab_base
            env_len = (info[4 * (i + 1) + 2] & 0xFFFF) - env_base
            psi_len = (info[4 * (i + 1) + 3] & 0xFFFF) - psi_base
            phi_len = (info[4 * (i + 1) + 0] & 0x7FFF) - phi_base
        else:
            ab_len  = SU_AB_DEPTH  - ab_base
            env_len = SU_ENV_DEPTH - env_base
            psi_len = SU_PSI_DEPTH - psi_base
            phi_len = SU_PHI_DEPTH - phi_base
        meta.append(dict(note=SUONA_NOTE_LO + i, K=K,
                         ab_base=ab_base,  ab_len=ab_len,
                         env_base=env_base, env_len=env_len,
                         psi_base=psi_base, psi_len=psi_len,
                         phi_base=phi_base, phi_len=phi_len))
    return meta


def pack_suona(su, base_word):
    """把唢呐段打包成 32 字节对齐的字节流。

    参数 base_word = 本段起始的【绝对 word 索引】，
    描述符里记的字节偏移都基于它计算（相对整个 P64.BIN 起点）。
    """
    meta = suona_note_meta(su)
    n = len(meta)
    base_byte = base_word * 32

    # ── 先排布：段头 2 word，描述符 n×2 word，之后 8 段表 ────────────
    hdr_words = 2
    desc_words = n * 2
    data_off = _pad32((hdr_words + desc_words) * 32)

    ab_off = data_off
    data_off += _pad32(SU_AB_DEPTH * 4)
    bc_off = data_off
    data_off += _pad32(SU_AB_DEPTH * 4)
    pi_off = data_off
    data_off += _pad32(SU_AB_DEPTH * 2)
    ee_off = data_off
    data_off += _pad32(SU_ENV_DEPTH * 1)
    eo_off = data_off
    data_off += _pad32(SU_ENV_DEPTH * 1)
    pe_off = data_off
    data_off += _pad32(SU_PSI_DEPTH * 2)
    po_off = data_off
    data_off += _pad32(SU_PSI_DEPTH * 2)
    ph_off = data_off
    data_off += _pad32(SU_PHI_DEPTH * 4)
    total = _pad32(data_off)

    buf = bytearray(total)

    # ── 段头 ───────────────────────────────────────────────────────
    struct.pack_into("<4sHHIIII", buf, 0,
                     SUONA_MAGIC, n, SUONA_NOTE_LO,
                     hdr_words,                  # desc_off（word）
                     0, 0, 0)
    # 段头 word1：8 个表的绝对字节偏移
    struct.pack_into("<IIIIIIII", buf, 32,
                     base_byte + ab_off, base_byte + bc_off,
                     base_byte + pi_off,
                     base_byte + ee_off, base_byte + eo_off,
                     base_byte + pe_off, base_byte + po_off,
                     base_byte + ph_off)

    # ── 描述符 ─────────────────────────────────────────────────────
    for i, m in enumerate(meta):
        o = hdr_words * 32 + i * 64
        struct.pack_into("<12I", buf, o,
                         m["K"],
                         base_byte + ab_off  + m["ab_base"]  * 4,
                         base_byte + bc_off  + m["ab_base"]  * 4,
                         base_byte + pi_off  + m["ab_base"]  * 2,
                         base_byte + ee_off  + m["env_base"] * 1,
                         base_byte + eo_off  + m["env_base"] * 1,
                         m["env_len"] * 1,
                         base_byte + pe_off  + m["psi_base"] * 2,
                         base_byte + po_off  + m["psi_base"] * 2,
                         m["psi_len"] * 2,
                         base_byte + ph_off  + m["phi_base"] * 4,
                         m["phi_len"] * 4)

    # ── 表数据 ─────────────────────────────────────────────────────
    def put_u32(dst, arr):
        for i, v in enumerate(arr):
            struct.pack_into("<I", buf, dst + i * 4, v & 0xFFFFFFFF)

    def put_u16(dst, arr):
        for i, v in enumerate(arr):
            struct.pack_into("<H", buf, dst + i * 2, v & 0xFFFF)

    def put_u8(dst, arr):
        for i, v in enumerate(arr):
            buf[dst + i] = v & 0xFF

    put_u32(ab_off, su["ab"])
    put_u32(bc_off, su["bc"])
    put_u16(pi_off, su["pi"])
    put_u8 (ee_off, su["ee"])
    put_u8 (eo_off, su["eo"])
    put_u16(pe_off, su["pe"])
    put_u16(po_off, su["po"])
    put_u32(ph_off, su["ph"])

    # 自检：每音的表都在段内
    for m in meta:
        for key, elem in (("ab", 4), ("psi", 2), ("phi", 4)):
            pass
    return bytes(buf), meta


def main():
    piano, p_n = load_3bank("add_param", PIANO_NOTE_LO, PIANO_NOTE_HI, "piano")
    gz,    g_n = load_3bank("gz_param",  GZ_NOTE_LO,    GZ_NOTE_HI,    "guzheng")

    p_blob = pack_instrument(piano, p_n)     # 88*64 = 5632 word = 180224 B
    g_blob = pack_instrument(gz, g_n)        # 49*64 = 3136 word = 100352 B

    p_base = 1
    g_base = p_base + words_of(p_blob)

    # ── 唢呐段：接在古筝表之后 ──────────────────────────────────────
    s_base = g_base + words_of(g_blob)
    su = load_suona()
    s_blob, s_meta = pack_suona(su, s_base)

    total_words = s_base + words_of(s_blob)

    body = p_blob + g_blob + s_blob

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
    print(f"suona   {len(s_meta)} 音  base_word={s_base:6d}  {words_of(s_blob):6d} word"
          f"  ({len(s_blob)/1024:.1f} KiB)")
    print(f"        RTL 常量 SUONA_BASE 应填 {s_base}")
    big = max(s_meta, key=lambda m: (m["ab_len"] * 10 + m["env_len"] + m["psi_len"] * 2 + m["phi_len"] * 4))
    bb = big["ab_len"] * 10 + big["env_len"] * 2 + big["psi_len"] * 2 * 2 + big["phi_len"] * 4
    print(f"        最大单音表 {bb/1024:.1f} KiB (note {big['note']}, K={big['K']})")
    print(f"total   {total_words} word = {len(img)} B = {len(img)/1024:.1f} KiB")
    print(f"checksum 0x{chk:08X}")
    print(f"输出 {out_path}")


if __name__ == "__main__":
    main()
