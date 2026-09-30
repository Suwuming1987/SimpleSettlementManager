#!/usr/bin/env python3
"""给记录补插缺失的子记录（例如全息卡带缺的 PTRN / YNAM / ZNAM）。

子记录顺序必须符合引擎期望的规范顺序，所以按"插在哪个子记录之后"来定位。
UTF-8 与长度重建机制同其他工具；压缩记录与 XXXX 一律拒绝处理。

用法：
  python tools/add_subrecords.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

REC_HDR = 24
GRUP_HDR = 24

# 记录 EditorID -> [(插在这个子记录之后, 新子记录, 数据)]
# 参照原版 CommonHolotape(NOTE 0021C986)：
#   EDID, OBND, PTRN(000995A5), FULL, MODL, MODT, YNAM(000BBFA8), ZNAM(000BBFA9), DNAM, DATA, SNAM
INSERTS = {
    'SM_Holotape': [
        (b'OBND', b'PTRN', struct.pack('<I', 0x000995A5)),   # 预览变换（哔哔小子预览要用）
        (b'MODT', b'YNAM', struct.pack('<I', 0x000BBFA8)),   # 拾取音效
        (b'MODT', b'ZNAM', struct.pack('<I', 0x000BBFA9)),   # 放下音效
    ],
}
# 注意：多个插入点用同一个锚点时，按列表顺序依次插在该锚点之后
#（所以 YNAM/ZNAM 都锚在 MODT 上，结果顺序是 MODT, YNAM, ZNAM ✓）


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


def rebuild_record(data, pos, changes):
    size = struct.unpack_from('<I', data, pos + 4)[0]
    flags = struct.unpack_from('<I', data, pos + 8)[0]
    if flags & 0x00040000:
        raise SystemExit('✗ 有压缩记录，本工具不处理')
    head = bytearray(data[pos:pos + REC_HDR])
    body = data[pos + REC_HDR:pos + REC_HDR + size]
    edid = edid_of(body)
    inserts = INSERTS.get(edid, [])
    before = len(changes)

    out = bytearray()
    q = 0
    present = set()
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            raise SystemExit('✗ 记录里有 XXXX 扩展子记录，本工具不处理')
        val = body[q + 6:q + 6 + n]
        present.add(s)
        out += s + struct.pack('<H', len(val)) + val
        for after, sig, payload in inserts:
            if s == after:
                out += sig + struct.pack('<H', len(payload)) + payload
                changes.append('%s: 在 %s 后插入 %s = %s' % (
                    edid, after.decode(), sig.decode(), payload.hex()))
        q += 6 + n

    if inserts:
        assert len(changes) - before == len(inserts), \
            '%s 的插入点没全找到（记录结构变了？）' % edid
        for _, sig, _ in inserts:
            if sig in present:
                raise SystemExit('✗ %s 已经有 %s 了，无需插入（已退出，未写文件）' % (edid, sig.decode()))

    struct.pack_into('<I', head, 4, len(out))
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
        print('无需修改')
        return 0

    open(path, 'wb').write(bytes(out))
    print('已插入 %d 处（文件 %d -> %d 字节）：' % (len(changes), len(data), len(out)))
    for c in changes:
        print('  ' + c)
    return 0


if __name__ == '__main__':
    sys.exit(main())
