#!/usr/bin/env python3
"""把 ESP 里"显示文本"子记录的 GBK 中文改写成 UTF-8。

背景：CK 按系统 ANSI 代码页（本机 GBK）写字符串，而游戏按 UTF-8 读 ——
CK 里直接打的中文进游戏会变乱码。已实测：能正常工作的中文 mod 里，记录字符串是 UTF-8。

本工具只动白名单里的"显示文本"子记录（FULL/NAM0/WNAM/BTXT/ITXT/UNAM/DESC/RNAM），
且只处理"能按 GBK 解出中文、但按 UTF-8 解不出来"的值（这正是 GBK 中文的特征，不会误伤 ASCII）。
UTF-8 比 GBK 长，所以会重建记录/GRUP 的长度字段；压缩记录与 XXXX 一律拒绝处理。

用法：
  python tools/fix_text_encoding.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

TEXT_SUBS = {b'FULL', b'NAM0', b'WNAM', b'BTXT', b'ITXT', b'UNAM', b'DESC', b'RNAM'}

GRUP_HDR = 24
REC_HDR = 24


def convert(value):
    """返回 (新值, 是否转换)"""
    body = value.split(b'\0')[0]
    if not body or not any(b > 0x7f for b in body):
        return value, False
    try:
        body.decode('utf-8')
        return value, False            # 本来就是合法 UTF-8，不动
    except UnicodeDecodeError:
        pass
    try:
        text = body.decode('gbk')
    except UnicodeDecodeError:
        return value, False            # 既不是 UTF-8 也不是 GBK，不动
    new_body = text.encode('utf-8')
    tail = value[len(body):]           # 保留结尾的 \0
    return new_body + tail, True


def rebuild_record(data, pos, changes):
    size = struct.unpack_from('<I', data, pos + 4)[0]
    flags = struct.unpack_from('<I', data, pos + 8)[0]
    if flags & 0x00040000:
        raise SystemExit('✗ 有压缩记录，本工具不处理，已退出')
    head = bytearray(data[pos:pos + REC_HDR])
    body = data[pos + REC_HDR:pos + REC_HDR + size]

    out = bytearray()
    q = 0
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            raise SystemExit('✗ 记录里有 XXXX 扩展子记录，本工具不处理，已退出')
        val = body[q + 6:q + 6 + n]
        new_val, converted = (convert(val) if s in TEXT_SUBS else (val, False))
        if converted:
            changes.append('%s: %s -> %s' % (s.decode(), val.split(b'\0')[0].decode('gbk'),
                                             new_val.split(b'\0')[0].decode('utf-8')))
        out += s + struct.pack('<H', len(new_val)) + new_val
        q += 6 + n

    struct.pack_into('<I', head, 4, len(out))
    return bytes(head) + bytes(out)


def rebuild_grup(data, pos, changes):
    """返回重建后的 GRUP 字节（含子 GRUP）"""
    hdr = bytearray(data[pos:pos + GRUP_HDR])
    total = struct.unpack_from('<I', data, pos + 4)[0]
    content = bytearray()
    q = pos + GRUP_HDR
    end = pos + total
    while q + GRUP_HDR <= end:
        sig = data[q:q + 4]
        if sig == b'GRUP':
            sub = rebuild_grup(data, q, changes)
            content += sub
            q += len(sub)
        else:
            size = struct.unpack_from('<I', data, q + 4)[0]
            rec = rebuild_record(data, q, changes)
            content += rec
            q += REC_HDR + size
    struct.pack_into('<I', hdr, 4, len(content) + GRUP_HDR)
    return bytes(hdr) + bytes(content)


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    tes4_size = struct.unpack_from('<I', data, 4)[0]
    out = bytearray(data[:GRUP_HDR + tes4_size])       # TES4 原样保留
    pos = GRUP_HDR + tes4_size
    changes = []
    while pos + GRUP_HDR <= len(data):
        sig = data[pos:pos + 4]
        if sig != b'GRUP':
            raise SystemExit('✗ 顶层出现非 GRUP 结构，已退出')
        out += rebuild_grup(data, pos, changes)
        total = struct.unpack_from('<I', data, pos + 4)[0]
        pos += total

    if not changes:
        print('无需修改（没有 GBK 文本）')
        return 0

    open(path, 'wb').write(bytes(out))
    print('已转换 %d 处 GBK -> UTF-8（文件 %d -> %d 字节）：' % (
        len(changes), len(data), len(out)))
    for c in changes:
        print('  ' + c)
    return 0


if __name__ == '__main__':
    sys.exit(main())
