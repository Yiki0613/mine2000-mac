#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
m2k_inspect.py —— `.m2k` / hiscore.dat 成绩档结构分析工具

用途
----
打印成绩档的记录布局，用于验证 `Sources/Mine2000/Model/Score/M2KCodec.swift`
中的编解码实现是否与原版一致。

用法
----
    python3 m2k_inspect.py [成绩档路径]
    默认读取当前目录下的 hiscore.dat（原版随安装包提供，本仓库不含）

结构（实测结论）
----------------
文件总长 **325 字节** = **25 条记录 × 13 字节**（整除，无尾部余字节）。

早前报告的「27 条 × 12 字节 + 1 字节尾部 = 325」在算术上同样成立，
但**周期分析证明不是**：整个文件以 13 字节为周期严格重复（25 个周期），
若按 12 字节切分则第 2 条记录会错位 1 字节。

单条记录 13 字节的字段布局：

    ┌──────────┬────────────────────┬──────────────┐
    │ 名字长度  │ Shift-JIS 名字       │ 分数 (uint16) │
    │  1 字节  │ 长度字节指定的字节数  │   2 字节 LE  │
    └──────────┴────────────────────┴──────────────┘

    合计 = 1 + 名字长度 + 2 = 13 → 名字长度固定为 10。

默认档（MSI 内嵌）的每条记录内容完全相同：
    长度 = 0x08，名字 = Shift-JIS「名前なし氣」（8 字节 / 4 个日文字符），
    分数 = 0xFFFF = 65535（表示「无成绩」的哨兵值）。
"""

import os
import sys

DEFAULT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "原始文件", "解包产物", "hiscore.dat")
)

RECORD_SIZE = 13
NAME_LENGTH = 10
NO_SCORE = 0xFFFF


def find_period(data: bytes, limit: int = 64) -> int:
    """找出能整除文件长度的最小周期。"""
    for period in range(1, limit + 1):
        if len(data) % period != 0:
            continue
        if all(data[i] == data[i % period] for i in range(len(data))):
            return period
    return 0


def decode_name(raw: bytes) -> str:
    try:
        return raw.decode("shift_jis")
    except UnicodeDecodeError:
        return raw.decode("shift_jis", errors="replace")


def analyze(path: str) -> None:
    if not os.path.exists(path):
        print(f"[错误] 找不到文件: {path}")
        sys.exit(1)

    data = open(path, "rb").read()
    print(f"文件: {path}")
    print(f"长度: {len(data)} 字节")
    print()

    period = find_period(data)
    if period:
        print(f"周期分析: 最小周期 = {period} 字节 → {len(data)}/{period} = {len(data)//period} 条记录")
    else:
        print("周期分析: 未找到严格重复周期（可能不是默认档）")
    print()

    record_size = RECORD_SIZE
    count = len(data) // record_size
    print(f"按 {record_size} 字节记录切分（{count} 条）:")
    print("-" * 78)
    print(f"{'#':>3} {'长度':>4} {'名字':<14} {'分数':>8}  原始字节")
    print("-" * 78)
    for i in range(count):
        rec = data[i * record_size:(i + 1) * record_size]
        nlen = rec[0]
        name_raw = rec[1:1 + nlen]
        score_raw = rec[1 + nlen:]
        score = int.from_bytes(score_raw, "little") if len(score_raw) == 2 else -1
        name = decode_name(name_raw)
        print(f"{i:>3} {nlen:>4} {name:<14} {score:>8}  {rec.hex(' ')}")

    print("-" * 78)
    first = data[:record_size]
    print(f"首条记录: 长度字节={first[0]}, 名字字节数={NAME_LENGTH}, "
          f"分数字节={first[1+first[0]:].hex(' ')}")
    if len(first) == RECORD_SIZE:
        score = int.from_bytes(first[1 + first[0]:], "little")
        print(f"         → 名字 = {decode_name(first[1:1+first[0]])!r}")
        print(f"         → 分数 = {score}" + ("（哨兵值，表示无成绩）" if score == NO_SCORE else ""))


if __name__ == "__main__":
    analyze(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH)
