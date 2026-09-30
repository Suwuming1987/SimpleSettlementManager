#!/usr/bin/env python3
"""往 SimpleSettlementManager.esp 追加一个 GLOB 记录（全局变量），给插件和 Papyrus 共享热键值。

为什么要这个：配套插件需要知道"玩家把面板热键设成了哪个键"。Papyrus 通知插件的路
（vm->RegisterFunction）在这份 CommonLibF4 里没有，所以改用 FO4 的常规做法 ——
给一个 GLOB 记录赋值，插件每帧读它。

记录布局（FO4 的 GLOB）：
  EDID  编辑器 ID（ASCII，结尾 \\0）
  FNAM  值类型：'s' = short/int
  FLTV  值（float32；整数键码在这个范围里不会有精度问题）

组顺序：直接追加到文件末尾（和 FLST 一样的做法，实测可行）。

用法（**游戏必须关掉** —— 运行中 ESP 被占用）：
  python tools/add_glob.py "E:/Games/MO2/mods/SimpleSettlementManager/SimpleSettlementManager.esp"
"""
import io
import os
import struct
import sys

GRUP_HDR = 24
REC_HDR = 24
LOAD_INDEX = 1          # 只有 1 个 master（Fallout4.esm），自身记录索引 = 1

# 三个共享变量（插件与 Papyrus 之间的唯一通道）
RECORDS = [
    ('SM_HotkeyVK',  0x00000F9D, 121.0),   # 面板热键（虚拟键码；默认 F10）
    ('SM_PanelWant', 0x00000F9E, 0.0),     # 打开/关闭"请求"：1 = 请打开，0 = 请关闭（Papyrus 写，插件执行）
    ('SM_PanelOpen', 0x00000F9F, 0.0),     # 面板"状态"：1 = 开着，0 = 关着（插件写，Papyrus 读）
    ('SM_RenameReq', 0x00000FA0, 0.0),     # 改名"请求号"：Papyrus 每次改名 +1（插件看它变化）
    ('SM_RenameResult', 0x00000FA1, 0.0),  # 改名"结果"：0 = 待处理 / 1 = 成功 / 2 = 失败（插件写）
]
EDID = RECORDS[0][0]
RAW_ID = RECORDS[0][1]
INITIAL = RECORDS[0][2]


def sub(sig, payload):
    return sig + struct.pack('<H', len(payload)) + payload


def build_glob(edid, raw_id, value):
    body = sub(b'EDID', edid.encode('ascii') + b'\0')
    body += sub(b'FNAM', b's')
    body += sub(b'FLTV', struct.pack('<f', value))
    head = bytearray(REC_HDR)
    head[0:4] = b'GLOB'
    struct.pack_into('<I', head, 4, len(body))
    struct.pack_into('<I', head, 8, 0)
    struct.pack_into('<I', head, 12, (LOAD_INDEX << 24) | raw_id)
    return bytes(head) + body


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else \
        'E:/Games/MO2/mods/SimpleSettlementManager/SimpleSettlementManager.esp'

    data = bytearray(open(path, 'rb').read())
    used = set()
    pos = 24 + struct.unpack_from('<I', data, 4)[0]
    while pos + GRUP_HDR <= len(data):
        if data[pos:pos + 4] == b'GRUP':
            pos += GRUP_HDR
            continue
        rsize = struct.unpack_from('<I', data, pos + 4)[0]
        used.add(struct.unpack_from('<I', data, pos + 12)[0] & 0x00FFFFFF)
        pos += REC_HDR + rsize

    added = []
    for edid, raw_id, initial in RECORDS:
        if raw_id in used:
            print('GLOB %s (%06X) 已存在，跳过' % (edid, raw_id))
            continue
        rec = build_glob(edid, raw_id, initial)
        grup = bytearray(GRUP_HDR)
        grup[0:4] = b'GRUP'
        struct.pack_into('<I', grup, 4, GRUP_HDR + len(rec))
        grup[8:12] = b'GLOB'
        struct.pack_into('<I', grup, 12, 0)
        data += bytes(grup) + rec
        added.append('%s (%06X, 初值 %.0f)' % (edid, raw_id, initial))

    if not added:
        return 0
    if not os.path.exists(path + '.bak'):
        open(path + '.bak', 'wb').write(bytes(data))   # 备份（追加前的内容有 .bak 就够）
    open(path, 'wb').write(bytes(data))
    print('已追加 %d 条 GLOB → %d 字节：' % (len(added), len(data)))
    for a in added:
        print('  ' + a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
