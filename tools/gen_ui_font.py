#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_ui_font.py —— 生成 HDMI UI 用的点阵字库（.hex，供 $readmemh）

## 为什么用点阵字库而不是矢量字体
FPGA 里画文字就是「查位图 + 按像素输出」，最省的做法是预先烘成位图放进 BSRAM。
BSRAM 读是同步的，一个像素拍查一次，正好和 1280×720 的像素流对齐。

## 产物
    ui_font_cn.hex   16×16 汉字点阵（每字 16 行 × 16 bit）
    ui_font_asc.hex  8×16 ASCII 点阵（每字 16 行 × 8 bit，实际存成 16 bit）

## 字符表（顺序即 ROM 索引，RTL 必须用同一份顺序！）
中文（16×16）：
    钢 琴 古 筝 唢 呐 笛 子 音 名 移 调 力 度 复 八 度 分 量 秒 延 迟 帧
ASCII（8×16）：0-9 A-Z 空格 . : / % + - x ( ) [ ] < > = # * , !

用法：
    cd /mnt/project/InstruementSound
    .venv/bin/python piano64_3/tools/gen_ui_font.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # InstruementSound/
OUTD = os.path.join(ROOT, "piano64_3", "src", "hdmi", "ui")

CN_FONT = "/usr/share/fonts/truetype/LXGWWenKai-Medium.ttf"
ASC_FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

CN = "钢琴古筝唢呐笛子音名移调力度复八分量秒延迟帧"
ASC = ("0123456789"
       "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
       " .:/%+-x()[]<>=#*,!")


def render(ch, font, w, h, thresh=110):
    """单字渲染成 (h 行, w 位) 的位图，返回 [int] 列表，每行 w 个 bit（bit0 = 最左）"""
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    # 以「字身框」居中：先取 bounding box 再贴到中心
    bbox = d.textbbox((0, 0), ch, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (w - tw) // 2 - bbox[0]
    y = (h - th) // 2 - bbox[1]
    d.text((x, y), ch, fill=255, font=font)

    px = img.load()
    rows = []
    for yy in range(h):
        v = 0
        for xx in range(w):
            if px[xx, yy] >= thresh:
                v |= (1 << xx)          # bit0 = 最左，方便 RTL 做 px-i
        rows.append(v)
    return rows


def write_hex(path, items, comment):
    with open(path, "w", encoding="ascii") as f:
        f.write("\n".join("%04X" % v for v in items) + "\n")
    print("  %-22s %4d 字 × %d 行 = %5d 行   %s"
          % (os.path.basename(path), len(items) // 16, 16, len(items), comment))


def main():
    os.makedirs(OUTD, exist_ok=True)

    cn_font = ImageFont.truetype(CN_FONT, 16)
    asc_font = ImageFont.truetype(ASC_FONT, 13)

    # ── 中文 16×16 ────────────────────────────────────────────────
    cn_rows = []
    print("中文 16×16：", CN)
    for ch in CN:
        cn_rows += render(ch, cn_font, 16, 16)
    write_hex(os.path.join(OUTD, "ui_font_cn.hex"), cn_rows,
              "索引 %d..%d" % (0, len(CN) - 1))

    # ── ASCII 8×16（存 16 位，高位补 0）────────────────────────────
    asc_rows = []
    print("ASCII 8x16：", ASC)
    for ch in ASC:
        for r in render(ch, asc_font, 8, 16):
            asc_rows.append(r & 0xFF)
    write_hex(os.path.join(OUTD, "ui_font_asc.hex"), asc_rows,
              "索引 %d..%d" % (0, len(ASC) - 1))

    # ── 打印索引表，RTL 侧要照抄 ─────────────────────────────────
    print()
    print("★ RTL 侧索引必须与此一致：")
    print("  CN : " + " ".join("%d=%s" % (i, c) for i, c in enumerate(CN)))
    print("  ASC: " + " ".join("%d=%s" % (i, c) for i, c in enumerate(ASC)))
    print()
    print("BSRAM 估算：")
    print("  中文 %d 字 × 16 行 × 16bit = %d bit = %.1f 块(18Kb)"
          % (len(CN), len(CN) * 16 * 16, len(CN) * 16 * 16 / 18432))
    print("  ASCII %d 字 × 16 行 × 16bit = %d bit = %.1f 块"
          % (len(ASC), len(ASC) * 16 * 16, len(ASC) * 16 * 16 / 18432))


if __name__ == "__main__":
    main()
