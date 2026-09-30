#!/usr/bin/env python3
"""整体替换终端记录的菜单项列表（不用开 Creation Kit）。

终端记录的菜单项区块结构（实测）：
    ... ISIZ(项数, 4 字节) , [ITXT(文字), ANAM(类型), ITID(ID, 2 字节), UNAM(显示文字)] × N
本工具保留 ISIZ 之前的所有子记录，丢弃旧的菜单项，按 ITEMS 重建，并同步 ISIZ 计数。

用法：
  python tools/set_menu_items.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

REC_HDR = 24
GRUP_HDR = 24

TARGET_EDID = 'SM_MainMenu'
ANAM_DISPLAY_TEXT = 8

# 新的菜单项列表：(Item ID, Item Text, Display Text)
ITEMS = [
    (7, '打开管理面板', '（PrismaUI 面板）'),
]

ITEM_SUBS = {b'ITXT', b'ANAM', b'ITID', b'UNAM'}


def edid_of(body):
    q = 0
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            q += 10
            continue
        if s == b'EDID':
            return body[q + 6:q + 6 + n].split(b'\0')[0].decode('latin-1')
        q += 6 + n
    return ''


def sub_list(body):
    out, q = [], 0
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            raise SystemExit('✗ 记录里有 XXXX 扩展子记录，本工具不处理')
        out.append((s, body[q + 6:q + 6 + n]))
        q += 6 + n
    return out


def rebuild_record(data, pos, changes):
    size = struct.unpack_from('<I', data, pos + 4)[0]
    flags = struct.unpack_from('<I', data, pos + 8)[0]
    if flags & 0x00040000:
        raise SystemExit('✗ 有压缩记录，本工具不处理')
    head = bytearray(data[pos:pos + REC_HDR])
    body = data[pos + REC_HDR:pos + REC_HDR + size]
    if edid_of(body) != TARGET_EDID:
        return bytes(head) + bytes(body)

    subs = sub_list(body)
    isiz = next((i for i, (s, _) in enumerate(subs) if s == b'ISIZ'), None)
    assert isiz is not None, '找不到 ISIZ'
    old_count = struct.unpack_from('<I', subs[isiz][1], 0)[0]
    old_items = sum(1 for s, _ in subs if s == b'ITID')

    out = bytearray()
    for i, (s, v) in enumerate(subs):
        if i == isiz:
            out += s + struct.pack('<H', 4) + struct.pack('<I', len(ITEMS))
        elif s in ITEM_SUBS and i > isiz:
            continue                       # 丢掉旧菜单项
        else:
            out += s + struct.pack('<H', len(v)) + v

    for iid, itext, utext in ITEMS:
        for sig, payload in ((b'ITXT', itext.encode('utf-8') + b'\0'),
                             (b'ANAM', bytes([ANAM_DISPLAY_TEXT])),
                             (b'ITID', struct.pack('<H', iid)),
                             (b'UNAM', utext.encode('utf-8') + b'\0')):
            out += sig + struct.pack('<H', len(payload)) + payload
        changes.append('菜单项 ID=%d  %s' % (iid, itext))

    struct.pack_into('<I', head, 4, len(out))
    print('  原：ISIZ=%d，实际项数=%d' % (old_count, old_items))
    return bytes(head) + bytes(out)


def rebuild_grup(data, pos, changes):
    hdr = bytearray(data[pos:pos + GRUP_HDR])
    total = struct.unpack_from('<I', data, pos + 4)[0]
    content = bytearray()
    q = pos + GRUP_HDR
    end = pos + total
    while q + GRUP_HDR <= end:
        if data[q:q + 4] == b'GRUP':
            sub = rebuild_grup(data, q, changes)
            content += sub
            q += len(sub)
        else:
            rsize = struct.unpack_from('<I', data, q + 4)[0]
            content += rebuild_record(data, q, changes)
            q += REC_HDR + rsize
    struct.pack_into('<I', hdr, 4, len(content) + GRUP_HDR)
    return bytes(hdr) + bytes(content)


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    tes4 = struct.unpack_from('<I', data, 4)[0]
    out = bytearray(data[:GRUP_HDR + tes4])
    pos = GRUP_HDR + tes4
    changes = []
    while pos + GRUP_HDR <= len(data):
        if data[pos:pos + 4] != b'GRUP':
            raise SystemExit('✗ 顶层出现非 GRUP 结构')
        out += rebuild_grup(data, pos, changes)
        pos += struct.unpack_from('<I', data, pos + 4)[0]

    if not changes:
        print('没有目标记录')
        return 1
    open(path, 'wb').write(bytes(out))
    print('已重写 %s 的菜单项（文件 %d -> %d 字节）：' % (TARGET_EDID, len(data), len(out)))
    for c in changes:
        print('  ' + c)
    return 0


if __name__ == '__main__':
    sys.exit(main())
