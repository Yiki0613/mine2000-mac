#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立解析 mine2000.EXE 的 RT_MENU 128，输出完整菜单树（ID + 标志）。

不依赖既有报告的结论，直接从 PE 资源字节出发，
用「经验文法」逐条验证：找出能 100% 消费 398 字节的解析规则。

用法
----
    python3 menu_parse.py <mine2000.EXE 路径>

需要 `pefile`：`python3 -m pip install pefile`
"""
import os
import struct
import sys

try:
    import pefile
except ImportError:
    sys.exit("缺少依赖 pefile，请先运行：python3 -m pip install pefile")


def _resolve_exe():
    """优先取命令行参数；否则在常见位置找一找，找不到就提示用法。"""
    if len(sys.argv) > 1:
        return sys.argv[1]
    for candidate in (
        "mine2000.EXE",
        "原始文件/解包产物/mine2000.EXE",
        os.path.expanduser("~/Downloads/mine2000.EXE"),
    ):
        if os.path.exists(candidate):
            return candidate
    sys.exit("用法: python3 menu_parse.py <mine2000.EXE 路径>")


EXE = _resolve_exe()

# 观察到的标志位（与实机枚举一致）
MF_POPUP = 0x0010
F_GRAYED = 0x0080
F_DISABLED = 0x0002


def load_menu():
    pe = pefile.PE(EXE)
    for t in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if t.struct.Id != 4:      # RT_MENU
            continue
        for n in t.directory.entries:
            if n.struct.Id != 128:
                continue
            for l in n.directory.entries:
                return pe.get_data(l.data.struct.OffsetToData, l.data.struct.Size)
    raise SystemExit('MENU 128 not found')


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]
        self.p += 2
        return v

    def string(self):
        """读 NUL 结尾的 UTF-16LE 串。"""
        start = self.p
        while True:
            if self.p + 2 > len(self.d):
                raise ValueError('EOF in string')
            if self.d[self.p] == 0 and self.d[self.p + 1] == 0:
                s = self.d[start:self.p].decode('utf-16-le')
                self.p += 2
                return s
            self.p += 2


def parse(data):
    """返回 (树, 消费字节数)。

    规则（由字节反推）：
      每项 = WORD flags
        flags & 0x0010 (POPUP) → 后面是 [NUL 结尾串]，然后是子菜单，
                                 子菜单以 WORD 0x0000 结束
        否则                   → WORD id，然后 [NUL 结尾串]
      flags == 0x0000 且无 id → 分隔线
    """
    r = Reader(data)
    r.p = 4          # 前 4 字节：版本 + 头长度

    def items(end):
        out = []
        while r.p < end:
            flags = r.u16()
            if flags == 0x0000:
                # 可能是分隔线，也可能是子菜单结束标记
                # 规则：后面若紧跟 0x0000 则是「分隔线 + 结束标记」？
                # 经验：分隔线 = flags 0x0000 且下一个 WORD 是 0x0000
                out.append(('SEP', None, None, flags, None))
                continue
            if flags & MF_POPUP:
                text = r.string()
                sub = items(end)
                out.append(('POPUP', None, text, flags, sub))
            else:
                mid = r.u16()
                text = r.string()
                out.append(('ITEM', mid, text, flags, None))
        return out

    tree = items(len(data))
    return tree, r.p


def show(nodes, indent=0):
    for kind, mid, text, flags, sub in nodes:
        tag = []
        if flags & F_GRAYED:
            tag.append('GRAYED')
        if flags & F_DISABLED:
            tag.append('DISABLED')
        if flags & MF_POPUP:
            tag.append('POPUP')
        t = '|'.join(tag) or '-'
        if kind == 'SEP':
            print('%s---- separator' % ('  ' * indent))
            continue
        if kind == 'POPUP':
            print('%s[POPUP] "%s"  flags=0x%04x (%s)' % ('  ' * indent, text, flags, t))
            show(sub, indent + 1)
        else:
            print('%sid=%-6d "%s"  flags=0x%04x (%s)' % ('  ' * indent, mid, text, flags, t))


if __name__ == '__main__':
    data = load_menu()
    print('MENU 128 长度 = %d 字节' % len(data))
    tree, consumed = parse(data)
    show(tree)
    print('解析消费 = %d / %d' % (consumed, len(data)))
