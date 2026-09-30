#!/usr/bin/env python3
"""核对 SimpleSettlementManager.esp 的记录（不依赖 CK / FO4Edit）。

检查项：
  1. TES4 的 master 列表（只该有 Fallout4.esm）
  2. 全部记录（签名 / FormID / EditorID / 显示名）
  3. QUST：Start Game Enabled 等标志位 + VMAD 脚本与属性值
  4. TERM：VMAD 脚本与属性 + 菜单项的 ID 与文字
  5. NOTE（全息卡带）：类型位 + SNAM 指向的终端记录是否在本插件里
  6. 所有中文同时按 UTF-8 / GBK 解码 —— 判断编码对不对（游戏要 UTF-8）

两个格式细节（踩过，别再错）：
  * FO4 的 VMAD 对象属性：类型(1B) + 状态(1B) + 4B 前缀 + formID(4B)，共 10B；formID 高位带载入序数。
  * TERM 的菜单项 ID (`ITID`) 是 **uint16**，不是 uint32。

用法：
  python tools/inspect_esp.py "E:/Games/MO2/mods/SimpleSettlementManager/SimpleSettlementManager.esp"
"""
import struct
import sys
import zlib


def read(path):
    data = open(path, 'rb').read()
    size = struct.unpack_from('<I', data, 4)[0]
    header = data[24:24 + size]

    masters = []
    q = 0
    while q + 6 <= len(header):
        s = header[q:q + 4]
        n = struct.unpack_from('<H', header, q + 4)[0]
        if s == b'MAST':
            masters.append(header[q + 6:q + 6 + n].split(b'\0')[0].decode('latin-1'))
        q += 6 + n

    recs = []
    pos = 24 + size
    while pos + 24 <= len(data):
        sig = data[pos:pos + 4]
        if sig == b'GRUP':
            pos += 24
            continue
        rsize = struct.unpack_from('<I', data, pos + 4)[0]
        flags = struct.unpack_from('<I', data, pos + 8)[0]
        fid = struct.unpack_from('<I', data, pos + 12)[0]
        body = data[pos + 24:pos + 24 + rsize]
        if flags & 0x00040000:
            try:
                body = zlib.decompress(body[4:])
            except Exception:
                body = b''
        recs.append((sig.decode('latin-1'), fid, body))
        pos += 24 + rsize
    return masters, recs


def subrecords(body):
    out, q = [], 0
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        if s == b'XXXX':
            q += 10
            continue
        out.append((s, body[q + 6:q + 6 + n]))
        q += 6 + n
    return out


def decode_both(raw):
    out = []
    for enc in ('utf-8', 'gbk'):
        try:
            out.append('%s ✓ %s' % (enc, raw.decode(enc)))
        except Exception:
            out.append('%s ✗' % enc)
    return '   |   '.join(out)


def cstr(v):
    return v.split(b'\0')[0]


def show_str(label, raw):
    raw = cstr(raw)
    if not raw:
        return
    if any(b > 0x7f for b in raw):
        print('  %-10s %s' % (label, decode_both(raw)))
    else:
        print('  %-10s %s' % (label, raw.decode('latin-1')))


def parse_vmad(v):
    """返回 [(脚本名, [(属性名, 类型, 值文本, 是否已设)])]"""
    scripts = []
    try:
        _ver, _fmt, n_scripts = struct.unpack_from('<hhH', v, 0)
        q = 6
        for _ in range(n_scripts):
            nlen = struct.unpack_from('<H', v, q)[0]
            q += 2
            sname = v[q:q + nlen].decode('latin-1')
            q += nlen
            q += 1                                  # 脚本 flags
            n_props = struct.unpack_from('<H', v, q)[0]
            q += 2
            props = []
            for _ in range(n_props):
                plen = struct.unpack_from('<H', v, q)[0]
                q += 2
                pname = v[q:q + plen].decode('latin-1')
                q += plen
                ptype = v[q]
                status = v[q + 1]
                q += 2
                if ptype == 1:                      # Object
                    q += 4                          # FO4：4 字节前缀
                    raw_id = struct.unpack_from('<I', v, q)[0]
                    q += 4
                    props.append((pname, 'Object',
                                  '%06X (原始 %08X)' % (raw_id & 0x00FFFFFF, raw_id),
                                  raw_id & 0x00FFFFFF != 0))
                elif ptype == 2:                    # String
                    q += 4
                    slen = struct.unpack_from('<H', v, q)[0]
                    q += 2
                    props.append((pname, 'String', v[q:q + slen].decode('latin-1'), slen > 0))
                    q += slen
                elif ptype in (3, 4, 5):            # Int / Float / Bool
                    q += 4
                    raw = v[q:q + 4]
                    q += 4
                    fmt = {3: '<i', 4: '<f', 5: '<i'}[ptype]
                    val = struct.unpack_from(fmt, raw, 0)[0]
                    props.append((pname, {3: 'Int', 4: 'Float', 5: 'Bool'}[ptype],
                                  str(val), True))
                else:
                    props.append((pname, 'type%d' % ptype, '<未支持的属性类型，后续解析停止>', False))
                    return scripts + [(sname, props)]
            scripts.append((sname, props))
    except Exception as e:
        scripts.append(('<解析中断: %s>' % e, []))
    return scripts


def main():
    path = sys.argv[1]
    masters, recs = read(path)
    # 记录表同时按"原始 ID"和"去掉载入序数的 ID"索引（SNAM 存的是带序数的原始值）
    by_id = {fid: (sig, body) for sig, fid, body in recs}
    by_masked = {fid & 0x00FFFFFF: (sig, body) for sig, fid, body in recs}

    print('文件: %s' % path)
    print('master: %s' % (masters if masters else '(无)'))
    if masters != ['Fallout4.esm']:
        print('  ⚠ 期望只有 Fallout4.esm；多出来的 master 说明记录依赖了别的插件')
    print('记录数: %d\n' % len(recs))

    print('=== 记录一览 ===')
    for sig, fid, body in recs:
        ss = subrecords(body)
        edid = next((cstr(v).decode('latin-1') for s, v in ss if s == b'EDID'), '')
        full = next((v for s, v in ss if s in (b'FULL', b'NAM0')), b'')
        line = '  %-4s %08X  %-24s' % (sig, fid, edid)
        print(line + ('  ' + decode_both(cstr(full)) if full and any(b > 0x7f for b in cstr(full)) else
                      ('  ' + cstr(full).decode('latin-1') if full else '')))

    for sig, fid, body in recs:
        ss = subrecords(body)
        edid = next((cstr(v).decode('latin-1') for s, v in ss if s == b'EDID'), '')
        vmad = next((v for s, v in ss if s == b'VMAD'), None)

        if sig == 'QUST':
            print('\n=== QUST %08X  %s ===' % (fid, edid))
            dnam = next((v for s, v in ss if s == b'DNAM'), None)
            if dnam and len(dnam) >= 2:
                flags = struct.unpack_from('<H', dnam, 0)[0]
                print('  标志 0x%04X: Start Game Enabled=%s, Run Once=%s' % (
                    flags, bool(flags & 0x01), bool(flags & 0x10)))
            else:
                print('  ⚠ 找不到 QUST 的 DNAM 标志位')
            if vmad:
                for sname, props in parse_vmad(vmad):
                    print('  脚本 %s' % sname)
                    for pname, ptype, pval, set_ok in props:
                        print('    %-22s %-8s = %-22s %s' % (pname, ptype, pval, '✓' if set_ok else '✗ 未填'))
            else:
                print('  ✗ 没有 VMAD（脚本没挂上）')

        elif sig == 'TERM':
            print('\n=== TERM %08X  %s ===' % (fid, edid))
            if vmad:
                for sname, props in parse_vmad(vmad):
                    print('  脚本 %s' % sname)
                    for pname, ptype, pval, set_ok in props:
                        print('    %-22s %-8s = %-22s %s' % (pname, ptype, pval, '✓' if set_ok else '✗ 未填'))
            else:
                print('  ✗ 没有 VMAD（脚本没挂上）')
            print('  菜单项:')
            item, items = {}, []
            for s, v in ss:
                if s == b'ITXT':
                    if item:
                        items.append(item)
                    item = {'text': cstr(v)}
                elif s == b'ITID':
                    item['id'] = struct.unpack_from('<H', v, 0)[0]
                elif s == b'ANAM':
                    item['type'] = v[0] if v else -1
            if item:
                items.append(item)
            for it in items:
                print('    ID=%-3s 文字=%s' % (it.get('id', '?'),
                                              decode_both(it.get('text', b'')) if any(
                                                  b > 0x7f for b in it.get('text', b''))
                                              else it.get('text', b'').decode('latin-1')))

        elif sig == 'NOTE':
            print('\n=== NOTE %08X  %s ===' % (fid, edid))
            for s, v in ss:
                if s == b'DNAM' and v:
                    print('  类型 DNAM = %02X %s' % (v[0], '(03 = Terminal ✓)' if v[0] == 3 else ''))
                elif s == b'SNAM':
                    tid = struct.unpack_from('<I', v, 0)[0] & 0x00FFFFFF
                    target = by_masked.get(tid)
                    if target:
                        t_edid = next((cstr(x).decode('latin-1') for x2, x in subrecords(target[1])
                                       if x2 == b'EDID'), '')
                        print('  SNAM -> %06X  %s %s  ✓ 指向正确' % (tid, target[0], t_edid))
                    else:
                        print('  SNAM -> %06X  ✗ 指向的记录不在本插件里' % tid)
                elif s == b'MODL':
                    show_str('模型', v)
                elif s == b'FULL':
                    show_str('名称', v)


if __name__ == '__main__':
    main()
