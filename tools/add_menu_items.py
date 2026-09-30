#!/usr/bin/env python3
"""给终端记录追加菜单项（不用开 Creation Kit）。

终端记录的菜单项结构（实测）：
    ... BSIZ, ISIZ(=项数, 4 字节), [ITXT(文字), ANAM(类型, 1 字节), ITID(ID, 2 字节), UNAM(显示文字)] × N
所以追加项 = 把 ISIZ 计数 +1，并在最后一项之后追加这四个子记录。

用法：
  python tools/add_menu_items.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

REC_HDR = 24
GRUP_HDR = 24

TARGET_EDID = 'SM_MainMenu'
ANAM_DISPLAY_TEXT = 8

# 要追加的菜单项：(Item ID, Item Text, Display Text)
# 已追加过的不要再列在这里（工具会断言 ID 不重复）。
NEW_ITEMS = [
    (7, '居民：<Token.SMTest>', '（判定实验：看这行是否显示居民名）'),
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


def rebuild_record(data, pos, changes, log):
    size = struct.unpack_from('<I', data, pos + 4)[0]
    flags = struct.unpack_from('<I', data, pos + 8)[0]
    if flags & 0x00040000:
        raise SystemExit('✗ 有压缩记录，本工具不处理')
    head = bytearray(data[pos:pos + REC_HDR])
    body = data[pos + REC_HDR:pos + REC_HDR + size]
    if edid_of(body) != TARGET_EDID:
        return bytes(head) + bytes(body)

    subs = sub_list(body)
    item_count = sum(1 for s, _ in subs if s == b'ITID')
    count_idx = next((i for i, (s, _) in enumerate(subs) if s == b'ISIZ'), None)
    assert count_idx is not None, '找不到 ISIZ'
    cur_count = struct.unpack_from('<I', subs[count_idx][1], 0)[0]
    assert cur_count == item_count, 'ISIZ(%d) 与实际项数(%d) 不一致，拒绝修改' % (cur_count, item_count)
    assert subs[-1][0] in ITEM_SUBS, '最后一项子记录是 %s，不是菜单项字段，拒绝追加' % subs[-1][0].decode()

    existing_ids = {struct.unpack_from('<H', v, 0)[0] for s, v in subs if s == b'ITID'}
    for iid, _, _ in NEW_ITEMS:
        assert iid not in existing_ids, 'Item ID %d 已存在，拒绝修改' % iid

    out = bytearray()
    for idx, (s, v) in enumerate(subs):
        if idx == count_idx:
            new_count = cur_count + len(NEW_ITEMS)
            out += s + struct.pack('<H', 4) + struct.pack('<I', new_count)
            log.append('ISIZ 计数 %d -> %d' % (cur_count, new_count))
        else:
            out += s + struct.pack('<H', len(v)) + v

    for iid, itext, utext in NEW_ITEMS:
        for sig, payload in ((b'ITXT', itext.encode('utf-8') + b'\0'),
                             (b'ANAM', bytes([ANAM_DISPLAY_TEXT])),
                             (b'ITID', struct.pack('<H', iid)),
                             (b'UNAM', utext.encode('utf-8') + b'\0')):
            out += sig + struct.pack('<H', len(payload)) + payload
        log.append('追加菜单项 ID=%d  %s' % (iid, itext))

    struct.pack_into('<I', head, 4, len(out))
    return bytes(head) + bytes(out)


def rebuild_grup(data, pos, changes, log):
    hdr = bytearray(data[pos:pos + GRUP_HDR])
    total = struct.unpack_from('<I', data, pos + 4)[0]
    content = bytearray()
    q = pos + GRUP_HDR
    end = pos + total
    while q + GRUP_HDR <= end:
        if data[q:q + 4] == b'GRUP':
            sub = rebuild_grup(data, q, changes, log)
            content += sub
            q += len(sub)
        else:
            rsize = struct.unpack_from('<I', data, q + 4)[0]
            content += rebuild_record(data, q, changes, log)
            q += REC_HDR + rsize
    struct.pack_into('<I', hdr, 4, len(content) + GRUP_HDR)
    return bytes(hdr) + bytes(content)


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    tes4 = struct.unpack_from('<I', data, 4)[0]
    out = bytearray(data[:GRUP_HDR + tes4])
    pos = GRUP_HDR + tes4
    changes, log = [], []
    while pos + GRUP_HDR <= len(data):
        if data[pos:pos + 4] != b'GRUP':
            raise SystemExit('✗ 顶层出现非 GRUP 结构')
        out += rebuild_grup(data, pos, changes, log)
        pos += struct.unpack_from('<I', data, pos + 4)[0]

    if not log:
        print('没有目标记录')
        return 1

    open(path, 'wb').write(bytes(out))
    print('已更新 %s（文件 %d -> %d 字节）：' % (TARGET_EDID, len(data), len(out)))
    for l in log:
        print('  ' + l)
    return 0


if __name__ == '__main__':
    sys.exit(main())
