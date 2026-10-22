#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tiles_inspect.py —— Mine2000 格子图集（tiles_144x81.bmp）结构分析工具

═══════════════════════════════════════════════════════════════════════════
重要修正（相对早期"9×5 个 16×16 图块"的错误假设）
═══════════════════════════════════════════════════════════════════════════
经像素级实测 + 反汇编交叉验证，图集的真实结构是 **3 个不同规格的子图集纵向拼接**，
而不是均匀的 9 列 × 5 行 16×16 网格：

  ┌ 区域 A ──────────────────────────┐ y = 0..31   高 32px
  │ A0 行: y=0..15   9 个 16×16 数字/符号 │
  │ A1 行: y=16..31  9 个 16×16 图形    │
  └──────────────────────────────────┘
  ┌ 区域 B ──────────────────────────┐ y = 32..54  高 23px
  │ 11 个 13×23 七段 LED 数字 (0-9 + 空白)│
  └──────────────────────────────────┘
  ┌ 区域 C ──────────────────────────┐ y = 55..80  高 26px
  │ 5 个 26×26 笑脸                     │
  └──────────────────────────────────┘

证据：
  * 区域 B：反汇编 0x403660 附近的 BitBlt 使用 `nWidth=0xd(13)`、`nHeight=0x17(23)`、
    `ySrc=0x20(32)`、`xSrc = 13*k` —— 13px 步进，与像素实测的七段字形完全一致。
  * 区域 C：反汇编 0x403890 附近使用 `nWidth=0x1a(26)`、`nHeight=0x1a(26)`、
    `ySrc=0x37(55)`、`xSrc ∈ {0, 0x34(52), 0x4e(78), 0x68(104)}` —— 26px 步进。
  * 区域 A：反汇编 0x4036xx 用 `shl eax,4`（×16）按列偏移推算，16px 步进。
  * 七段数字经"点亮段"几何检测严格解码为 0,1,2,3,4,5,6,7,8,9,空白（11 槽）。

用法：
  python3 tiles_inspect.py [图集路径] [输出目录]
  默认图集：../Sources/Mine2000/Resources/tiles_144x81.bmp
  默认输出：../docs/research/tiles
"""

import json
import os
import sys
from collections import Counter

from PIL import Image, ImageDraw, ImageFont

# ---------------- 图集规格常量 ----------------
ATLAS_W, ATLAS_H = 144, 81

# 区域 A：9 列 × 16px，两行
A_COLS, A_TILE = 9, 16
A_ROW0_Y, A_ROW1_Y = 0, 16
A_ROW0_H = A_ROW1_H = 16

# 区域 B：11 个 13×23 七段数字
B_COUNT, B_W, B_H, B_Y = 11, 13, 23, 32

# 区域 C：5 个 26×26 笑脸
C_COUNT, C_W, C_H, C_Y = 5, 26, 26, 55


def load_font(size=13):
    """尽量取一个能显示中文/ASCII 的字体，取不到就退回默认位图字体。"""
    for path in (
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()


# ---------------- 区域 A 语义表（依据像素实测 + 目视核对） ----------------
# 索引 = 列号 0..8
A_ROW0_LABELS = {
    0: "空白底板（1px 浅灰描边，非格子）",
    1: "数字 1（蓝）",
    2: "数字 2（绿）",
    3: "数字 3（红）",
    4: "数字 4（深蓝）",
    5: "数字 5（暗红）",
    6: "数字 6（青）",
    7: "数字 7（黑）",
    8: "数字 8（灰）",
}

A_ROW1_LABELS = {
    0: "未翻开格（灰色 3D 凸起，浅灰面板 + 白/灰描边）",
    1: "红旗（未翻开格 + 红旗）",
    2: "地雷（未翻开格 + 黑地雷）",
    3: "地雷+红底高亮（踩雷瞬间）",
    4: "插旗地雷 X（旗插错时显示）",
    5: "未使用（纯白）",
    6: "未使用（纯白）",
    7: "未使用（纯白）",
    8: "未使用（纯白）",
}

# 区域 C 语义表：依据像素实测（黄色像素 x 段 6-20/32-46/58-72/84-98/111-125）
C_LABELS = [
    "笑脸 1：正常（微笑，眼睛为两点）",
    "笑脸 2：胜利（戴墨镜）",
    "笑脸 3：踩雷失败（X 眼，皱眉）",
    "笑脸 4：惊讶（张嘴 O 形）",
    "笑脸 5：正常（与笑脸 1 略有差异的备用变体）",
]


def seven_segment_decode(block, ox, oy):
    """用七段几何中心点检测，解码一个 13×23 LED 数字字形。

    返回点亮段字符串（abcdefg 顺序），无法识别时返回 None。
    """
    px = block.load()
    w, h = block.size

    def lit(x, y):
        if not (0 <= x < w and 0 <= y < h):
            return False
        r, g, b = px[x, y]
        return r >= 200 and g < 60 and b < 60

    # 七段中心点（相对字形左上角），坐标由槽 0（数字 0）的实测掩码反推
    centers = {
        "a": (6, 2),
        "b": (11, 6),
        "c": (11, 17),
        "d": (6, 20),
        "e": (1, 17),
        "f": (1, 6),
        "g": (6, 11),
    }
    on = ""
    for name, (cx, cy) in centers.items():
        hits = 0
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if lit(cx + dx, cy + dy):
                    hits += 1
        if hits >= 6:
            on += name
    return "".join(c for c in "abcdefg" if c in on)


SEG_TO_DIGIT = {
    "abcdef": "0",
    "bc": "1",
    "abdeg": "2",
    "abcdg": "3",
    "bcfg": "4",
    "acdfg": "5",
    "acdefg": "6",
    "abc": "7",
    "abcdefg": "8",
    "abcdfg": "9",
}


def analyze(atlas_path, out_dir):
    if not os.path.exists(atlas_path):
        print(f"[错误] 找不到图集: {atlas_path}")
        sys.exit(1)

    os.makedirs(out_dir, exist_ok=True)
    atlas = Image.open(atlas_path).convert("RGB")

    print(f"图集: {atlas_path}")
    print(f"尺寸: {atlas.width} × {atlas.height}")
    print()
    print("=" * 78)
    print("真实结构（3 个不同规格子图集纵向拼接）")
    print("=" * 78)
    print(f"  区域 A  y=0..31   9 列 × 2 行 × 16×16   格子图块")
    print(f"  区域 B  y=32..54  11 个 × 13×23          七段 LED 数字")
    print(f"  区域 C  y=55..80  5 个 × 26×26           笑脸")
    print()

    font = load_font(12)
    font_big = load_font(16)

    manifest = {
        "atlas": os.path.basename(atlas_path),
        "atlasSize": [atlas.width, atlas.height],
        "regions": {
            "A": {
                "y": 0, "height": 32, "cols": 9, "tile": 16,
                "row0": {"y": A_ROW0_Y, "labels": A_ROW0_LABELS},
                "row1": {"y": A_ROW1_Y, "labels": A_ROW1_LABELS},
            },
            "B": {"y": B_Y, "height": B_H, "count": B_COUNT, "w": B_W, "h": B_H,
                  "kind": "seven-segment-led"},
            "C": {"y": C_Y, "height": C_H, "count": C_COUNT, "w": C_W, "h": C_H,
                  "kind": "face"},
        },
    }

    # ---------------- 区域 A：导出每块 + 拼图 ----------------
    print("-" * 78)
    print("区域 A（16×16 格子图块）")
    print("-" * 78)
    for row, (y0, labels) in enumerate(
        ((A_ROW0_Y, A_ROW0_LABELS), (A_ROW1_Y, A_ROW1_LABELS))
    ):
        for col in range(A_COLS):
            x0 = col * A_TILE
            block = atlas.crop((x0, y0, x0 + A_TILE, y0 + A_TILE))
            name = f"A{row}_{col}.png"
            block.resize((A_TILE * 8, A_TILE * 8), Image.NEAREST).save(
                os.path.join(out_dir, name)
            )
            colors = Counter(block.getdata())
            print(f"  A{row} 列{col} (x={x0:3d},y={y0:2d})  色数={len(colors):2d}  {labels[col]}")

    # 区域 A 拼图（2 行 × 9 列，带标注）
    zoom = 8
    cw, ch = A_TILE * zoom, A_TILE * zoom
    lab_h = 34
    sheet = Image.new("RGB", (A_COLS * (cw + 8) + 8, 2 * (ch + lab_h + 8) + 34), (28, 28, 32))
    d = ImageDraw.Draw(sheet)
    d.text((8, 8), "区域 A：格子图块（16×16，9 列 × 2 行）", font=font_big, fill=(240, 240, 240))
    for row, (y0, labels) in enumerate(
        ((A_ROW0_Y, A_ROW0_LABELS), (A_ROW1_Y, A_ROW1_LABELS))
    ):
        for col in range(A_COLS):
            x0 = col * A_TILE
            px0 = 8 + col * (cw + 8)
            py0 = 34 + row * (ch + lab_h + 8)
            sheet.paste(atlas.crop((x0, y0, x0 + A_TILE, y0 + A_TILE)).resize((cw, ch), Image.NEAREST), (px0, py0))
            d.rectangle([px0 - 1, py0 - 1, px0 + cw, py0 + ch], outline=(90, 90, 100))
            d.text((px0, py0 + ch + 3), f"A{row}·{col}", font=font, fill=(255, 220, 120))
            d.text((px0, py0 + ch + 17), labels[col][:14], font=font, fill=(180, 190, 210))
    sheet_a = os.path.join(out_dir, "_region_A.png")
    sheet.save(sheet_a)

    # ---------------- 区域 B：七段数字 ----------------
    print()
    print("-" * 78)
    print("区域 B（13×23 七段 LED 数字）")
    print("-" * 78)
    b_labels = []
    for k in range(B_COUNT):
        x0 = k * B_W
        block = atlas.crop((x0, B_Y, x0 + B_W, B_Y + B_H))
        block.resize((B_W * 8, B_H * 8), Image.NEAREST).save(
            os.path.join(out_dir, f"B_{k}.png")
        )
        segs = seven_segment_decode(block, x0, B_Y)
        digit = SEG_TO_DIGIT.get(segs)
        label = f"数字 {digit}" if digit else ("空白" if not segs else f"未知(段={segs})")
        b_labels.append(label)
        print(f"  B 槽{k:2d} (x={x0:3d},y={B_Y:2d})  点亮段={segs or '(无)':9s} → {label}")
    manifest["regions"]["B"]["labels"] = b_labels

    zoom = 6
    cw, ch = B_W * zoom, B_H * zoom
    sheet = Image.new("RGB", (B_COUNT * (cw + 6) + 6, ch + 40), (28, 28, 32))
    d = ImageDraw.Draw(sheet)
    d.text((6, 6), "区域 B：七段 LED 数字（13×23 × 11）", font=font_big, fill=(240, 240, 240))
    for k in range(B_COUNT):
        x0 = k * B_W
        px0 = 6 + k * (cw + 6)
        sheet.paste(atlas.crop((x0, B_Y, x0 + B_W, B_Y + B_H)).resize((cw, ch), Image.NEAREST), (px0, 26))
        d.text((px0, 26 + ch + 2), b_labels[k], font=font, fill=(255, 220, 120))
    sheet_b = os.path.join(out_dir, "_region_B.png")
    sheet.save(sheet_b)

    # ---------------- 区域 C：笑脸 ----------------
    print()
    print("-" * 78)
    print("区域 C（26×26 笑脸）")
    print("-" * 78)
    for k in range(C_COUNT):
        x0 = k * C_W
        block = atlas.crop((x0, C_Y, x0 + C_W, C_Y + C_H))
        block.resize((C_W * 6, C_H * 6), Image.NEAREST).save(
            os.path.join(out_dir, f"C_{k}.png")
        )
        # 统计黄色像素包围盒，用于确认笑脸在 26×26 格内的实际位置
        ys = [y for y in range(C_H) for x in range(C_W) if block.getpixel((x, y)) == (255, 255, 0)]
        xs = [x for y in range(C_H) for x in range(C_W) if block.getpixel((x, y)) == (255, 255, 0)]
        bbox = (min(xs), min(ys), max(xs), max(ys)) if xs else None
        print(f"  C 槽{k} (x={x0:3d},y={C_Y:2d})  黄色包围盒={bbox}  {C_LABELS[k]}")
    manifest["regions"]["C"]["labels"] = C_LABELS

    zoom = 5
    cw, ch = C_W * zoom, C_H * zoom
    sheet = Image.new("RGB", (C_COUNT * (cw + 6) + 6, ch + 40), (28, 28, 32))
    d = ImageDraw.Draw(sheet)
    d.text((6, 6), "区域 C：笑脸（26×26 × 5）", font=font_big, fill=(240, 240, 240))
    for k in range(C_COUNT):
        x0 = k * C_W
        px0 = 6 + k * (cw + 6)
        sheet.paste(atlas.crop((x0, C_Y, x0 + C_W, C_Y + C_H)).resize((cw, ch), Image.NEAREST), (px0, 26))
        d.text((px0, 26 + ch + 2), C_LABELS[k][:10], font=font, fill=(255, 220, 120))
    sheet_c = os.path.join(out_dir, "_region_C.png")
    sheet.save(sheet_c)

    # ---------------- 总览 + 清单 ----------------
    manifest_path = os.path.join(out_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print()
    print("=" * 78)
    print("输出")
    print("=" * 78)
    print(f"  区域 A 拼图 : {sheet_a}")
    print(f"  区域 B 拼图 : {sheet_b}")
    print(f"  区域 C 拼图 : {sheet_c}")
    print(f"  单块 PNG    : {out_dir}")
    print(f"  索引清单    : {manifest_path}")
    print()
    print(f"总计图块数 = 9×2 + 11 + 5 = {9*2 + 11 + 5}（≠ 45，原 9×5 假设有误）")


if __name__ == "__main__":
    HERE = os.path.dirname(os.path.abspath(__file__))
    default_atlas = os.path.normpath(os.path.join(HERE, "..", "Sources", "Mine2000", "Resources", "tiles_144x81.bmp"))
    default_out = os.path.normpath(os.path.join(HERE, "..", "docs", "research", "tiles"))
    analyze(
        sys.argv[1] if len(sys.argv) > 1 else default_atlas,
        sys.argv[2] if len(sys.argv) > 2 else default_out,
    )
