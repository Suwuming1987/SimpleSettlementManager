# -*- coding: utf-8 -*-
"""给 mod 的 ESP 打上 ESL（轻量插件）标记，并先检查记录 ID 是否都在 ESL 允许的范围里。

ESL 的硬要求：**新记录的 FormID 必须落在 0x800 ~ 0xFFF**（加载时是 FE<槽位>XXX）。
CK 每次保存 ESP 都会把 TES4 头的 flags 重写掉，所以这一步要放在 build.sh 里每次跑（幂等）。

用法：python tools/set_esl.py [esp 路径]（省略则用 dist/SimpleSettlementManager.esp）
"""
import io
import os
import struct
import sys

ESL_FLAG = 0x00000200
HDR = 24


def record_ids(d):
    """列出顶层记录（含子 GRUP 一层）的 FormID，用于范围检查。"""
    ids = []
    pos = HDR + struct.unpack_from('<I', d, 4)[0]        # TES4 头之后

    def walk(start, end):
        q = start
        while q + HDR <= end:
            sig = d[q:q + 4]
            size = struct.unpack_from('<I', d, q + 4)[0]
            if sig == b'GRUP':
                if size < HDR:
                    return
                walk(q + HDR, q + size)
                q += size
                continue
            if not sig.isalpha() or size < 0:
                return
            ids.append(struct.unpack_from('<I', d, q + 12)[0] & 0x00FFFFFF)
            q += HDR + size

    while pos + HDR <= len(d):
        if d[pos:pos + 4] != b'GRUP':
            break
        gsize = struct.unpack_from('<I', d, pos + 4)[0]
        if gsize < HDR:
            break
        walk(pos + HDR, pos + gsize)
        pos += gsize
    return ids


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join('dist', 'SimpleSettlementManager.esp')
    d = bytearray(open(path, 'rb').read())
    if d[:4] != b'TES4':
        raise SystemExit('不是 ESP 文件：' + path)
    flags = struct.unpack_from('<I', d, 8)[0]
    ids = record_ids(d)
    bad = [i for i in ids if i < 0x800 or i > 0xFFF]
    print('记录数 %d；ESL 范围外的 ID：%s' % (len(ids), bad if bad else '无'))
    if bad:
        raise SystemExit('✗ 有记录 ID 不在 0x800~0xFFF，不能打 ESL 标记')
    if flags & ESL_FLAG:
        print('✓ 已经是 ESL 标记（flags=0x%08X）' % flags)
        return
    struct.pack_into('<I', d, 8, flags | ESL_FLAG)
    open(path, 'wb').write(bytes(d))
    print('✓ 已写入 ESL 标记（flags 0x%08X → 0x%08X）：%s' % (flags, flags | ESL_FLAG, path))


if __name__ == '__main__':
    main()
