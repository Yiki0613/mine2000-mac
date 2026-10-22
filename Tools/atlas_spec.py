#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
atlas_spec.py —— 独立核实 `tiles_144x81.bmp` 的 45 个图块规格

用途
----
生成 `docs/图集规格.md` 所需的对照表。本脚本**不依赖**既有的
`docs/research/tiles/manifest.json`，而是自己重新切图、重新统计像素，
以免「用旧结论验证旧结论」。

图集真实结构（实测）
------------------
图集 **不是** 均匀的 9×5 个 16×16 网格，而是 3 个不同规格的子图集纵向拼接：

    ┌ 区域 A ──────────────────────────┐ y = 0..31   高 32px
    │ A0 行: y=0..15   9 个 16×16 数字  │
    │ A1 行: y=16..31  9 个 16×16 图形  │
    └──────────────────────────────────┘
    ┌ 区域 B ──────────────────────────┐ y = 32..54  高 23px
    │ 11 个 13×23 七段 LED 数字 (0-9+空)│
    └──────────────────────────────────┘
    ┌ 区域 C ──────────────────────────┐ y = 55..80  高 26px
    │ 5 个 26×26 笑脸                   │
    └──────────────────────────────────┘

用法
----
    python3 atlas_spec.py [图集路径]
    默认读取 ../Sources/Mine2000/Resources/tiles_144x81.bmp
"""

import os
import sys
from collections import Counter

from PIL import Image

DEFAULT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "Sources", "Mine2000", "Resources", "tiles_144x81.bmp")
)

ATLAS_W, ATLAS_H = 144, 81

# 区域 A
A_ROWS = (0, 16)
A_COLS = 9
A_TILE = 16

# 区域 B
B_Y, B_H, B_W, B_COUNT = 32, 23, 13, 11

# 区域 C
C_Y, C_H, C_W, C_COUNT = 55, 26, 26, 5

# 常见 Windows 扫雷配色（RGB）
DIGIT_COLORS = {
    (0, 0, 255): "蓝（数字 1）",
    (0, 128, 0): "绿（数字 2）",
    (255, 0, 0): "红（数字 3）",
    (0, 0, 128): "深蓝（数字 4）",
    (128, 0, 0): "暗红（数字 5）",
    (0, 128, 128): "青（数字 6）",
    (0, 0, 0): "黑（数字 7）",
    (128, 128, 128): "灰（数字 8）",
}


def dominant_ink(crop):
    """返回图块中「非灰阶」的主色（若无则返回 None）。"""
    counts = Counter()
    for r, g, b in crop.getdata():
        if r == g == b:
            continue  # 灰阶（底板 / 描边 / 阴影）不算
        counts[(r, g, b)] += 1
    if not counts:
        return None
    return counts.most_common(1)[0][0]


def describe_region_a(im):
    rows = []
    for row_y in A_ROWS:
        for col in range(A_COLS):
            crop = im.crop((col * A_TILE, row_y,
                            col * A_TILE + A_TILE, row_y + A_TILE))
            colors = crop.getcolors(1 << 16)
            colors.sort(reverse=True)
            ink = dominant_ink(crop)
            rows.append({
                "row": (row_y // 16),
                "col": col,
                "rect": (col * A_TILE, row_y, A_TILE, A_TILE),
                "ncolors": len(colors),
                "ink": ink,
                "ink_desc": DIGIT_COLORS.get(ink, "—"),
                "top": colors[0][1] if colors else None,
            })
    return rows


def describe_region_b(im):
    out = []
    for i in range(B_COUNT):
        crop = im.crop((i * B_W, B_Y, i * B_W + B_W, B_Y + B_H))
        red = sum(1 for r, g, b in crop.getdata() if r > 150 and g < 100 and b < 100)
        out.append({"slot": i, "rect": (i * B_W, B_Y, B_W, B_H), "red_px": red})
    return out


def describe_region_c(im):
    out = []
    for i in range(C_COUNT):
        crop = im.crop((i * C_W, C_Y, i * C_W + C_W, C_Y + C_H))
        colors = crop.getcolors(1 << 16)
        colors.sort(reverse=True)
        yellow = sum(1 for r, g, b in crop.getdata() if r > 200 and g > 200 and b < 120)
        out.append({
            "slot": i,
            "rect": (i * C_W, C_Y, C_W, C_H),
            "yellow_px": yellow,
            "ncolors": len(colors),
        })
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    im = Image.open(path).convert("RGB")
    print(f"图集：{path}")
    print(f"尺寸：{im.size[0]}×{im.size[1]}（期望 {ATLAS_W}×{ATLAS_H}）")
    if im.size != (ATLAS_W, ATLAS_H):
        print("!! 尺寸与预期不符", file=sys.stderr)
        return 1

    print("\n=== 区域 A（16×16，9 列 × 2 行）===")
    for t in describe_region_a(im):
        ink = t["ink"]
        ink_s = "-".join(f"{v:02X}" for v in ink) if ink else "（无彩色）"
        print(f"  r{t['row']} c{t['col']}: 色数={t['ncolors']:>2} "
              f"主色={ink_s:<8} {t['ink_desc']}")

    print("\n=== 区域 B（13×23，11 槽）===")
    for t in describe_region_b(im):
        print(f"  slot {t['slot']:>2}: 亮红像素={t['red_px']:>3}")

    print("\n=== 区域 C（26×26，5 槽）===")
    for t in describe_region_c(im):
        print(f"  slot {t['slot']}: 黄色像素={t['yellow_px']:>4} 色数={t['ncolors']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
