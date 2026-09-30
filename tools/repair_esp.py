#!/usr/bin/env python3
"""定点修复 SimpleSettlementManager.esp 里"两条记录撞号"的问题。

背景（这次的实际情况）：
  CK 在错误的加载状态下保存时，会把记录分散在"文件位"里 —— 终端记录留在旧文件位（索引 01），
  卡带/任务落在新文件位（索引 02）。保存成新文件后 master 只剩 Fallout4.esm，
  于是"卡带"和"终端"的**对象序号都是 000F99**：各自文件里合法，合到一个文件里就撞号。
  tools/normalize_esp.py 只归并索引、不处理撞号，所以需要本工具重新分配序号并更新引用。

本工具做的事（带断言，状态不符就退出，不动文件）：
  * 把卡带记录 SM_Holotape 的序号改成 0x000F9B（ID: 01000F9B）
  * 把 VMAD 里名为 SM_Holotape 的对象属性指向新 ID
  * 卡带的 SNAM（指向终端）保持不变 —— 它本来就是对的

用法：
  python tools/repair_esp.py "…/SimpleSettlementManager.esp"
"""
import struct
import sys
import zlib


def read(path):
    data = bytearray(open(path, 'rb').read())
    size = struct.unpack_from('<I', data, 4)[0]
    n_masters = bytes(data[24:24 + size]).count(b'MAST')
    recs, pos = [], 24 + size
    while pos + 24 <= len(data):
        sig = bytes(data[pos:pos + 4])
        if sig == b'GRUP':
            pos += 24
            continue
        rsize = struct.unpack_from('<I', data, pos + 4)[0]
        flags = struct.unpack_from('<I', data, pos + 8)[0]
        fid = struct.unpack_from('<I', data, pos + 12)[0]
        if flags & 0x00040000:
            raise SystemExit('✗ 有压缩记录，本工具不处理，已退出')
        recs.append({'sig': sig.decode('latin-1'), 'off': pos, 'size': rsize, 'id': fid,
                     'body_off': pos + 24})
        pos += 24 + rsize
    return data, n_masters, recs


def subs(data, rec):
    out, q, end = [], rec['body_off'], rec['body_off'] + rec['size']
    while q + 6 <= end:
        s = bytes(data[q:q + 4])
        n = struct.unpack_from('<H', data, q + 4)[0]
        if s == b'XXXX':
            q += 10
            continue
        out.append((s, q, n))
        q += 6 + n
    return out


def edid(data, rec):
    for s, q, n in subs(data, rec):
        if s == b'EDID':
            return bytes(data[q + 6:q + 6 + n]).split(b'\0')[0].decode('latin-1')
    return ''


def main():
    path = sys.argv[1]
    data, n_masters, recs = read(path)
    assert n_masters == 1, '期望只有 1 个 master'

    note = next((r for r in recs if edid(data, r) == 'SM_Holotape'), None)
    term = next((r for r in recs if edid(data, r) == 'SM_MainMenu'), None)
    quest = next((r for r in recs if edid(data, r) == 'SM_ControllerQuest'), None)
    assert note and term and quest, '找不到三条记录，退出'

    print('修复前:')
    for r in (note, term, quest):
        print('  %-4s %08X  %s' % (r['sig'], r['id'], edid(data, r)))

    assert note['id'] == term['id'], '没有撞号，无需修复（退出）'
    old_obj = note['id'] & 0x00FFFFFF
    new_obj = old_obj + 2                       # 000F99 -> 000F9B（F9A 被任务占用）
    new_id = (n_masters << 24) | new_obj
    changes = []

    # 1) 卡带记录头改号
    struct.pack_into('<I', data, note['off'] + 12, new_id)
    changes.append('记录头 NOTE %08X -> %08X' % (note['id'], new_id))

    # 2) VMAD 里名为 SM_Holotape 的对象属性改指新 ID
    for s, q, n in subs(data, quest):
        if s != b'VMAD':
            continue
        off = q + 6
        _v, _f, n_scripts = struct.unpack_from('<hhH', data, off)
        p = off + 6
        for _ in range(n_scripts):
            nlen = struct.unpack_from('<H', data, p)[0]
            script = bytes(data[p + 2:p + 2 + nlen]).decode('latin-1')
            p += 2 + nlen + 1
            n_props = struct.unpack_from('<H', data, p)[0]
            p += 2
            for _ in range(n_props):
                plen = struct.unpack_from('<H', data, p)[0]
                pname = bytes(data[p + 2:p + 2 + plen]).decode('latin-1')
                p += 2 + plen
                ptype = data[p]
                p += 2
                if ptype == 1:
                    p += 4
                    raw = struct.unpack_from('<I', data, p)[0]
                    if pname == 'SM_Holotape' and (raw & 0x00FFFFFF) == old_obj:
                        struct.pack_into('<I', data, p, new_id)
                        changes.append('VMAD %s.%s: %08X -> %08X' % (script, pname, raw, new_id))
                    p += 4
                elif ptype == 2:
                    p += 4
                    slen = struct.unpack_from('<H', data, p)[0]
                    p += 2 + slen
                elif ptype in (3, 4, 5):
                    p += 8
                else:
                    raise SystemExit('✗ VMAD 里有未支持的属性类型，已退出（未做修改）')

    open(path, 'wb').write(bytes(data))
    print('\n已修正 %d 处:' % len(changes))
    for c in changes:
        print('  ' + c)

    # 3) 复检
    print('\n复检:')
    data2, _, recs2 = read(path)
    ids = {}
    ok = True
    for r in recs2:
        e = edid(data2, r)
        if r['id'] in ids:
            print('  ✗ 仍撞号: %08X (%s / %s)' % (r['id'], ids[r['id']], e))
            ok = False
        ids[r['id']] = e
        print('  %-4s %08X  %s' % (r['sig'], r['id'], e))
    for r in recs2:
        if r['sig'] != 'NOTE':          # SNAM 只对卡带（NOTE）是"终端引用"；
            continue                    # 终端记录里也有个同名子记录，含义不同，别误报
        for s, q, n in subs(data2, r):
            if s == b'SNAM':
                tid = struct.unpack_from('<I', data2, q + 6)[0] & 0x00FFFFFF
                tgt = next((x for x in recs2 if (x['id'] & 0x00FFFFFF) == tid), None)
                print('  SNAM -> %06X  %s' % (tid, edid(data2, tgt) if tgt else '✗ 找不到'))
    print('结果: %s' % ('✓ 全部唯一且引用可解析' if ok else '✗ 仍有问题'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
