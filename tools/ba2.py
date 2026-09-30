"""列出 / 提取 BA2 里的文件（只处理 GNRL，脚本包都是这种）。

BA2 布局：
  "BTDX" + uint32 版本 + 4 字节类型 + uint32 文件数 + uint64 名字表偏移
  然后每个文件 36 字节：nameHash/ext/dirHash/flags + offset + packedSize + unpackedSize + 0xBAADF00D
  最后是名字表：uint32 长度 + 每条（uint16 名字长度 + 名字，无结尾符）

用法：
  python tools/ba2.py list <包.ba2>
  python tools/ba2.py extract <包.ba2> <包内路径关键字> <输出文件>
"""
import struct
import sys


def read_index(path):
    d = open(path, 'rb').read()
    if d[:4] != b'BTDX':
        raise SystemExit("不是 BA2 文件")
    ver, ftype, count, nameoff = struct.unpack_from('<I4sIQ', d, 4)
    if ftype != b'GNRL':
        print("注意：类型是 %s（这里只按 GNRL 解析）" % ftype.decode(errors='replace'))
    entries = []
    pos = 24
    for i in range(count):
        nh, ext, dh, flags = struct.unpack_from('<IIII', d, pos)
        off, packed, unpacked = struct.unpack_from('<QII', d, pos + 16)
        entries.append({'off': off, 'packed': packed, 'unpacked': unpacked, 'flags': flags})
        pos += 36
    namelen = struct.unpack_from('<I', d, nameoff)[0]
    p = nameoff + 4
    for i in range(count):
        n = struct.unpack_from('<H', d, p)[0]
        p += 2
        entries[i]['name'] = d[p:p + n].decode('utf-8', errors='replace')
        p += n
    return d, entries


def main():
    cmd = sys.argv[1]
    d, entries = read_index(sys.argv[2])
    if cmd == 'list':
        kw = sys.argv[3].lower() if len(sys.argv) > 3 else ''
        for e in entries:
            if kw in e['name'].lower():
                print("%-70s %8d 字节" % (e['name'], e['unpacked']))
        print("共 %d 个文件" % len(entries))
    elif cmd == 'extract':
        kw, out = sys.argv[3].lower(), sys.argv[4]
        hit = [e for e in entries if kw in e['name'].lower()]
        if len(hit) != 1:
            raise SystemExit("匹配到 %d 个：%s" % (len(hit), [h['name'] for h in hit]))
        e = hit[0]
        blob = d[e['off']:e['off'] + e['packed']]
        if e['packed'] != e['unpacked']:
            raise SystemExit("这个文件是压缩的（%d -> %d），本工具不处理" % (e['packed'], e['unpacked']))
        open(out, 'wb').write(blob)
        print("已提取 %s → %s（%d 字节）" % (e['name'], out, len(blob)))
    else:
        raise SystemExit(__doc__)


main()
