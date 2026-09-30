"""从 What's Your Name 的 ESL 里抽名字库（按性别分开），生成界面用的 JS 数组。

WYN 的结构：
  * 4 个 FLST（formListMale / formListFemale / formListMaleRare / formListFemaleRare），
    每个引用一批 MESG；MESG 的 FULL 字段就是那个名字（例：FULL "Zed"）。
  * 名字按性别分开存，这就是"要注意性别差异"的地方。

用法：
  python tools/extract_names.py "E:/Games/MO2/mods/What's Your Name/WhatsYourName.esl" tools/_names.json
"""
import io
import json
import re
import struct
import sys
import zlib

SKIP_SIGS = {b'TES4'}


def walk(data, start, end, out, depth=0):
    """遍历记录（含 GRUP 递归）。"""
    pos = start
    while pos + 24 <= end:
        sig = data[pos:pos + 4]
        if sig == b'GRUP':
            size = struct.unpack_from('<I', data, pos + 4)[0]
            out.append(('GRUP', None, None, pos))
            walk(data, pos + 24, pos + size, out, depth + 1)
            pos += size
            continue
        if sig in SKIP_SIGS:
            pos += 24 + struct.unpack_from('<I', data, pos + 4)[0]
            continue
        size, flags, formid = struct.unpack_from('<III', data, pos + 4)
        body = data[pos + 24:pos + 24 + size]
        if flags & 0x00040000:                     # 压缩记录
            body = zlib.decompress(body[4:])
        out.append((sig, formid, body, pos))
        pos += 24 + size


def subrecs(body):
    q = 0
    while q + 6 <= len(body):
        s = body[q:q + 4]
        n = struct.unpack_from('<H', body, q + 4)[0]
        yield s, body[q + 6:q + 6 + n]
        q += 6 + n


def main():
    path, outpath = sys.argv[1], sys.argv[2]
    data = open(path, 'rb').read()
    hdr_size = struct.unpack_from('<I', data, 4)[0]
    recs = []
    walk(data, 24 + hdr_size, len(data), recs)

    mesg = {}          # formID -> 显示名
    flst = {}          # editorID -> [formID...]
    for sig, formid, body, _ in recs:
        if sig != b'MESG' or body is None:
            continue
        name = None
        for s, v in subrecs(body):
            if s == b'FULL':
                name = v.split(b'\0')[0].decode('utf-8', errors='replace')
        if name:
            mesg[formid & 0x00FFFFFF] = name
    for sig, formid, body, _ in recs:
        if sig != b'FLST' or body is None:
            continue
        edid, lnam = None, []
        for s, v in subrecs(body):
            if s == b'EDID':
                edid = v.split(b'\0')[0].decode('latin-1')
            elif s == b'LNAM':
                lnam.append(struct.unpack_from('<I', v, 0)[0] & 0x00FFFFFF)
        flst[edid] = lnam

    out = {}
    for edid, ids in flst.items():
        names = [mesg[i] for i in ids if i in mesg]
        print("%-24s %3d 个（其中 %3d 个能对上 MESG）" % (edid, len(ids), len(names)))
        out[edid] = names

    # 归成 男/女/稀有 三组
    def pick(*keys):
        acc = []
        for k in keys:
            acc += out.get(k, [])
        seen, res = set(), []
        for n in acc:
            if n not in seen and not re.search(r'[<>]', n):   # 滤掉 token 占位文本
                seen.add(n)
                res.append(n)
        return res

    groups = {
        'male': pick('praNameListMale'),
        'female': pick('praNameListFemale'),
        'maleRare': pick('praNameListMaleRare'),
        'femaleRare': pick('praNameListFemaleRare'),
    }
    for k, v in groups.items():
        print("  %-11s %d 个" % (k, len(v)))
    io.open(outpath, 'w', encoding='utf-8', newline='\n').write(
        json.dumps(groups, ensure_ascii=False, indent=1))
    print("已写出", outpath)


main()
