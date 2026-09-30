#!/usr/bin/env python3
"""往 ESP 里新建一条记录（目前用于 FLST —— 给 WSFW 的交易列表选择器当结果容器）。

组顺序必须规范：实测 WSFW.esm 里 FLST 组排在 QUST 之后，而我们插件的组顺序是
NOTE TERM QUST，所以 FLST 组直接追加到文件末尾就是规范位置。

用法：
  python tools/add_record.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

GRUP_HDR = 24
REC_HDR = 24

# EditorID -> (签名, 原始 FormID（不含载入序数）, 组标签)
NEW_RECORDS = [
    ('SM_PickResult', b'FLST', 0x00000F9C),
]

LOAD_INDEX = 1          # 只有 1 个 master（Fallout4.esm），自身记录索引 = 1


def sub(sig, payload):
    return sig + struct.pack('<H', len(payload)) + payload


def build_flst(edid, raw_id):
    body = sub(b'EDID', edid.encode('ascii') + b'\0')
    head = bytearray(REC_HDR)
    head[0:4] = b'FLST'
    struct.pack_into('<I', head, 4, len(body))          # 数据长度
    struct.pack_into('<I', head, 8, 0)                  # flags
    struct.pack_into('<I', head, 12, (LOAD_INDEX << 24) | raw_id)
    return bytes(head) + body


def main():
    path = sys.argv[1]
    data = bytearray(open(path, 'rb').read())

    # 找文件里已有的 FormID，避免撞号
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
    for edid, sig, raw_id in NEW_RECORDS:
        assert raw_id not in used, 'FormID %06X 已被占用' % raw_id
        if sig == b'FLST':
            rec = build_flst(edid, raw_id)
        else:
            raise SystemExit('暂不支持创建 %s' % sig.decode())
        grup = bytearray(GRUP_HDR)
        grup[0:4] = b'GRUP'
        struct.pack_into('<I', grup, 4, GRUP_HDR + len(rec))     # 组大小含头部
        grup[8:12] = sig
        struct.pack_into('<I', grup, 12, 0)                      # groupType 0 = 记录类型组
        data += bytes(grup) + rec
        added.append('%s %s (%06X)' % (sig.decode(), edid, raw_id))

    open(path, 'wb').write(bytes(data))
    print('已追加 %d 条记录（文件 %d -> %d 字节）：' % (len(added), len(data) - sum(0 for _ in added), len(data)))
    for a in added:
        print('  ' + a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
