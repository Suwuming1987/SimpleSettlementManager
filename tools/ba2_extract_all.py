"""把 BA2 里所有文件解出来（自动处理 zlib 压缩），输出到 tools/_ba2_out/。"""
import io
import os
import struct
import sys
import zlib

path = sys.argv[1]
outdir = sys.argv[2] if len(sys.argv) > 2 else 'tools/_ba2_out'
os.makedirs(outdir, exist_ok=True)

d = open(path, 'rb').read()
ver, ftype, count, nameoff = struct.unpack_from('<I4sIQ', d, 4)
recs = []
pos = 24
for i in range(count):
    nh, ext, dh, flags = struct.unpack_from('<IIII', d, pos)
    off, a, b = struct.unpack_from('<QII', d, pos + 16)
    recs.append({'off': off, 'a': a, 'b': b, 'ext': d[pos + 4:pos + 8].split(b'\0')[0].decode()})
    pos += 36

# 名字表：从 nameoff 起是连续的 (uint16 长度 + 名字)，顺序与记录一致
names = []
p = nameoff
for i in range(count):
    n = struct.unpack_from('<H', d, p)[0]
    p += 2
    names.append(d[p:p + n].decode('utf-8', errors='replace'))
    p += n

for i, r in enumerate(recs):
    blob = d[r['off']:r['off'] + r['a']]
    if r['a'] != r['b']:                     # 压缩
        try:
            blob = zlib.decompress(blob)
        except Exception as e:
            print("  ! 解压失败 %s: %s" % (names[i], e))
    name = names[i] if i < len(names) else "file%02d.%s" % (i, r['ext'])
    safe = name.replace('/', '_')
    open(os.path.join(outdir, safe), 'wb').write(blob)
    print("%-60s %7d 字节 %s" % (name, len(blob), "（压缩过）" if r['a'] != r['b'] else ""))
print("输出目录：", outdir)
