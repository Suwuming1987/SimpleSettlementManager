#!/usr/bin/env python3
"""直接把指定记录的显示文本写成 UTF-8（用于 GBK 被 xEdit 破坏成 ? 之后重建文本）。

只动 TARGETS 里列出的字段，按出现顺序编号（ITXT/UNAM 各有多个）。
UTF-8 比原值长时重建记录/GRUP 长度；压缩记录与 XXXX 一律拒绝处理。

用法：
  python tools/set_text.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys

REC_HDR = 24
GRUP_HDR = 24

# (记录 EditorID, 子记录, 第几个（None=全部/唯一）) -> 文本
TARGETS = {
    # 卡带
    ('SM_Holotape', b'FULL', None): '据点管理终端',
    # 终端：名称/表头/欢迎语
    ('SM_MainMenu', b'FULL', None): '据点管理终端',
    ('SM_MainMenu', b'NAM0', None): '据点管理终端',
    ('SM_MainMenu', b'WNAM', None): '选择要执行的操作',
    # 菜单项（ITXT/UNAM 按出现顺序编号，每项各一条）
    ('SM_MainMenu', b'ITXT', 0): '查看当前据点',
    ('SM_MainMenu', b'ITXT', 1): '重新发放全息卡带',
    ('SM_MainMenu', b'ITXT', 2): '居民与岗位明细',
    ('SM_MainMenu', b'ITXT', 3): '一键填补空岗',
    ('SM_MainMenu', b'ITXT', 4): '解除本据点全部岗位',
    ('SM_MainMenu', b'ITXT', 5): '所有据点总览',
    ('SM_MainMenu', b'ITXT', 6): '打开管理面板',
    ('SM_MainMenu', b'UNAM', 0): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 1): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 2): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 3): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 4): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 5): '（见弹窗）',
    ('SM_MainMenu', b'UNAM', 6): '（PrismaUI 面板）',
}


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

    out = bytearray()
    q = 0
    index = {}
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            raise SystemExit('✗ 记录里有 XXXX 扩展子记录，本工具不处理')
        val = body[q + 6:q + 6 + n]
        i = index.get(s, 0)
        index[s] = i + 1
        key = (edid, s, i)
        key_any = (edid, s, None)
        text = TARGETS.get(key, TARGETS.get(key_any))
        if text is not None:
            had_nul = val.endswith(b'\0')
            new_val = text.encode('utf-8') + (b'\0' if had_nul else b'')
            changes.append('%s.%s[%d]: %r -> %r' % (edid, s.decode(), i,
                                                    val.split(b'\0')[0][:24], text))
            val = new_val
        out += s + struct.pack('<H', len(val)) + val
        q += 6 + n

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

    # 必须每条目标都写进去，否则说明记录结构变了，不能悄悄放过
    if len(changes) != len(TARGETS):
        print('✗ 只匹配到 %d / %d 个目标字段，未写文件。匹配到的：' % (len(changes), len(TARGETS)))
        for c in changes:
            print('   ' + c)
        return 1

    open(path, 'wb').write(bytes(out))
    print('已写入 %d 处（文件 %d -> %d 字节）：' % (len(changes), len(data), len(out)))
    for c in changes:
        print('  ' + c)
    return 0


if __name__ == '__main__':
    sys.exit(main())
