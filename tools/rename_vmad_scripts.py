#!/usr/bin/env python
# 把 ESP 的 VMAD 里的脚本名从旧命名空间改成新的。
#
# 为什么需要它：Papyrus 靠 VMAD 里存的名字绑定脚本。改了脚本命名空间（也就是
# Scripts/<名字>/ 这层目录名）而不改 VMAD，脚本就绑不上 —— 任务不会初始化、终端按钮没反应。
#
# 实测到的格式（Fallout 4，VMAD version 6 / objectFormat 2）：
#   int16 version / int16 objectFormat / uint16 scriptCount
#   uint16 对象脚本名长度 + 名字          ← **要改的就是它**（任务的脚本、终端的片段宿主脚本）
#   uint8 0 / uint16 scriptCount / 每个脚本: uint16 名长度 + 名 / uint8 flags / uint16 属性数 / 属性…
#   属性（type=1 的 Object）形如：uint16 名长度+名 / uint8 type / uint8 status / 4 字节前缀 + formID
# 属性名是 SM_* 这类编辑器 ID、**不参与改名**；整个文件里该命名空间只出现在上面那个对象脚本名里。
#
# 做法：定点插入（把前缀换成更长的名字），然后把 VMAD 子记录、记录、各级 GRUP 的长度字段加上增量。
#   长度字段永远排在它包含的改动之前，所以写回时可以放心地"先按原偏移写长度、再从后往前插字节"。
#
# 用法：
#   python tools/rename_vmad_scripts.py <esp> --check     # 干跑
#   python tools/rename_vmad_scripts.py <esp>             # 真改（留 .bak，改完自校验）
import struct
import sys

OLD_PREFIX = b"SettlementManager:"
NEW_PREFIX = b"SimpleSettlementManager:"
KNOWN_OLD = {
    b"SettlementManager:ControllerQuest",
    b"SettlementManager:TerminalMenu",
}


def parse(data):
    """解析结构。返回 (records, vamds)：
    records = [(sig, formID)]（用于改前改后比对）
    vamds   = [(data_off, data_len, size_field_off, wide)]"""
    records = []
    vamds = []

    def walk(start, end):
        q = start
        while q + 24 <= end:
            sig = bytes(data[q:q + 4])
            if sig == b"GRUP":
                size = struct.unpack_from("<I", data, q + 4)[0]
                if size < 24 or q + size > end:
                    return False
                if not walk(q + 24, q + size):
                    return False
                q += size
                continue
            size = struct.unpack_from("<I", data, q + 4)[0]
            if q + 24 + size > end:
                return False
            form = struct.unpack_from("<I", data, q + 12)[0]
            records.append((sig, form))
            r, rec_end = q + 24, q + 24 + size
            big = False
            while r + 6 <= rec_end:
                ssig = bytes(data[r:r + 4])
                if big:
                    ssize = struct.unpack_from("<I", data, r + 4)[0]
                    hdr = 8
                else:
                    ssize = struct.unpack_from("<H", data, r + 4)[0]
                    hdr = 6
                if ssig == b"XXXX":
                    big = True
                    r += 10
                    continue
                if r + hdr + ssize > rec_end:
                    return False
                if ssig == b"VMAD":
                    vamds.append((r + hdr, ssize, r + 4, big))
                r += hdr + ssize
                big = False
            q = rec_end
        return True

    if not walk(0, len(data)):
        return None, None
    return records, vamds


def find_targets(data, off, size):
    """在 VMAD 数据里找要改的脚本名，返回 [(len_field_off, prefix_off, old_name)]"""
    hits = []
    end = off + size
    i = off
    while True:
        i = data.find(OLD_PREFIX, i, end)
        if i < 0:
            break
        name_start = i - 2
        if name_start >= off:
            nlen = struct.unpack_from("<H", data, name_start)[0]
            name = bytes(data[name_start + 2:name_start + 2 + nlen])
            if name in KNOWN_OLD:
                hits.append((name_start, i, name))
        i += 1
    return hits


def main():
    path = sys.argv[1]
    check = "--check" in sys.argv
    data = bytearray(open(path, "rb").read())

    records, vamds = parse(data)
    if records is None:
        print("✗ 结构解析失败，不做任何修改")
        return 1
    print("解析成功：%d 个记录，%d 个 VMAD" % (len(records), len(vamds)))

    edits = []
    for off, size, size_off, wide in vamds:
        for len_off, prefix_off, old_name in find_targets(data, off, size):
            edits.append((len_off, prefix_off, old_name, size_off, wide))
    if not edits:
        print("没有需要改的脚本名（可能已经改过了）")
        return 0

    for len_off, prefix_off, old_name, size_off, wide in edits:
        print("  改 %-34r @%d（所在 VMAD 的长度字段 @%d，%s）"
              % (old_name.decode(), prefix_off, size_off, "4 字节" if wide else "2 字节"))
    if check:
        print("（--check 干跑，未写文件）")
        return 0

    # 受影响区域 → 增量：凡是"包含某个待改字符串"的 VMAD/记录/GRUP 都要 +6
    region_delta = {}                    # size 字段偏移 -> 增量

    def hits_in(a_start, a_end):
        return [e for e in edits if a_start <= e[1] < a_end]

    # VMAD 子记录自身（uint16 长度）
    for off, size, size_off, wide in vamds:
        n = len(hits_in(off, off + size))
        if n:
            region_delta[size_off] = region_delta.get(size_off, 0) + 6 * n

    # 记录与各级 GRUP（uint32 长度）
    for start, end, size_off, includes in _walk_regions(data):
        n = len(hits_in(start, end))
        if n:
            region_delta[size_off] = region_delta.get(size_off, 0) + 6 * n

    # 先写长度字段（它们的偏移都在插入点之前，不受插入影响）
    vamd_size_offs = {v[2] for v in vamds}
    for key, delta in region_delta.items():
        if key in vamd_size_offs:
            struct.pack_into("<H", data, key, struct.unpack_from("<H", data, key)[0] + delta)
        else:
            struct.pack_into("<I", data, key, struct.unpack_from("<I", data, key)[0] + delta)

    # 再从后往前替换前缀 + 改各字符串自身的长度
    for len_off, prefix_off, old_name, size_off, wide in sorted(edits, key=lambda e: -e[1]):
        new_name = NEW_PREFIX + old_name[len(OLD_PREFIX):]
        assert len(new_name) == len(old_name) + 6, "前缀长度差必须是 6"
        data[prefix_off:prefix_off + len(OLD_PREFIX)] = NEW_PREFIX
        struct.pack_into("<H", data, len_off, len(new_name))

    open(path + ".bak", "wb").write(bytes(open(path, "rb").read()))
    open(path, "wb").write(bytes(data))

    # ---- 自校验 ----
    out = open(path, "rb").read()
    records2, vamds2 = parse(bytearray(out))
    ok = True
    if records2 != records:
        print("✗ 记录序列改变了（结构被破坏）")
        ok = False
    # 旧前缀不该再单独出现：新名字本身**包含**旧名字（SimpleSettlementManager:… 里子串
    # 就是 SettlementManager:…），所以只能比"总出现次数 - 新名字里带的次数"。
    n_old = out.count(b"SettlementManager:")
    n_new = out.count(b"SimpleSettlementManager:")
    if n_old != n_new:
        print("✗ 还有 %d 处旧脚本名前缀没改（新前缀 %d 处）" % (n_old - n_new, n_new))
        ok = False
    for off, size, size_off, wide in vamds2:
        names, i, end = [], off, off + size
        while True:
            i = out.find(b"SimpleSettlementManager:", i, end)
            if i < 0:
                break
            nlen = struct.unpack_from("<H", out, i - 2)[0]
            names.append(out[i:i + nlen].decode("latin1"))
            i += 1
        print("  校验 VMAD @%d：%s" % (off, ", ".join(sorted(set(names))) or "（无脚本名）"))
        if not names:
            ok = False
    print("✓ 通过：结构一致、旧名已清、长度自洽（.bak 保留原始文件）" if ok
          else "✗ 校验未通过，请用 .bak 恢复")
    return 0 if ok else 3


def _walk_regions(data):
    """产出 (start, end, size_field_off, includes_header)"""
    out = []

    def walk(start, end):
        q = start
        while q + 24 <= end:
            sig = bytes(data[q:q + 4])
            if sig == b"GRUP":
                size = struct.unpack_from("<I", data, q + 4)[0]
                if size < 24 or q + size > end:
                    return
                out.append((q, q + size, q + 4, True))
                walk(q + 24, q + size)
                q += size
                continue
            size = struct.unpack_from("<I", data, q + 4)[0]
            out.append((q, q + 24 + size, q + 4, False))
            q = q + 24 + size

    walk(0, len(data))
    return out


if __name__ == "__main__":
    sys.exit(main())
