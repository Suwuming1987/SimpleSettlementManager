#!/usr/bin/env python3
"""修正 ESP 里"自身记录索引 > master 数"的问题。

背景：CraftKit 在加载状态不对时会写出 FORM ID 高字节 ≠ master 数量的记录
（例如只有 1 个 master 却写成 02000F99）。规范写法是"自身记录的索引 = master 数"
（1 个 master → 01000F99）—— 实测你机器上 257 个插件里只有我们这个文件有这种写法。

本工具做定点字节修补，**长度不变**：
  * 记录头里的自身 FORM ID：索引 > N 时改成 N
  * 子记录里的自引用：NOTE 的 SNAM、VMAD 里 Object 属性的 formID
  * 指向 master 的引用（索引 < N）一律不动

安全性：先在旁边留一份 .bak；遇到压缩记录会直接报错退出（不做危险的解压重写）。

用法：
  python tools/normalize_esp.py "…/SimpleSettlementManager.esp"
"""
import shutil
import struct
import sys
import zlib


def patch_vmad(buf, off, end, n_masters, changes):
    """在 buf[off:end] 的 VMAD 里修正 Object 属性的 formID。返回是否成功。

    布局（**按本 mod 的 ESP 实测出来的**，ver=6 / fmt=2 / 脚本数=1）：
      int16 version / int16 objectFormat / uint16 scriptCount
      [version >= 4] uint16 对象脚本名长度 + 名字 + **1 个 NUL**（长度不含 NUL）
      逐脚本：uint16 属性数，然后是属性表
      每个属性：uint16 名长度 + 名 / uint8 类型 / uint8 状态 / 值
        类型 1 = Object：4 字节前缀 + 4 字节 formID（前缀 0xFFFFxxxx 表示别名，别去动）
        类型 2 = String：4 字节长度 + 内容   类型 3/4/5 = 4+4 字节
    两条硬性纪律：
      * 漏掉"对象脚本名 + NUL"会整体错位 —— 错位后可能把 `ÿÿ`（0xFFFF 别名标记）当成越界
        formID 去"修正"，把别名改坏；
      * 走完必须**正好落在 end**，否则一律返回失败、不做任何写入（宁可不动，也不能带猜地写）。
    """
    v = buf
    ver, _fmt, n_scripts = struct.unpack_from('<hhH', v, off)
    q = off + 6
    if ver >= 4:
        slen = struct.unpack_from('<H', v, q)[0]
        q += 2 + slen + 1                    # 名字 + NUL
    for _ in range(n_scripts):
        n_props = struct.unpack_from('<H', v, q)[0]
        q += 2
        for _ in range(n_props):
            plen = struct.unpack_from('<H', v, q)[0]
            q += 2 + plen
            ptype = v[q]
            q += 2
            if ptype == 1:                       # Object
                q += 4                           # FO4 的 4 字节前缀
                raw = struct.unpack_from('<I', v, q)[0]
                if (raw >> 24) > n_masters:
                    new = (n_masters << 24) | (raw & 0x00FFFFFF)
                    struct.pack_into('<I', v, q, new)
                    changes.append('VMAD 属性 formID %08X -> %08X' % (raw, new))
                q += 4
            elif ptype == 2:                     # String
                q += 4
                slen = struct.unpack_from('<H', v, q)[0]
                q += 2 + slen
            elif ptype in (3, 4, 5):             # Int / Float / Bool
                q += 8
            else:
                return False                     # 遇到不支持的类型，放弃（不冒险）
    return q == end                              # 必须正好走完整个 VMAD


def main():
    path = sys.argv[1]
    data = bytearray(open(path, 'rb').read())

    size = struct.unpack_from('<I', data, 4)[0]
    n_masters = bytes(data[24:24 + size]).count(b'MAST')
    print('master 数 = %d' % n_masters)

    shutil.copy2(path, path + '.bak')
    print('备份: %s.bak' % path)

    changes = []
    pos = 24 + size
    while pos + 24 <= len(data):
        sig = bytes(data[pos:pos + 4])
        if sig == b'GRUP':
            pos += 24
            continue
        rsize = struct.unpack_from('<I', data, pos + 4)[0]
        flags = struct.unpack_from('<I', data, pos + 8)[0]
        fid = struct.unpack_from('<I', data, pos + 12)[0]
        compressed = bool(flags & 0x00040000)

        if (fid >> 24) > n_masters:
            new = (n_masters << 24) | (fid & 0x00FFFFFF)
            struct.pack_into('<I', data, pos + 12, new)
            changes.append('记录头 %s %08X -> %08X' % (sig.decode('latin-1'), fid, new))

        if compressed:
            print('✗ %s %08X 是压缩记录，本工具不处理，已退出（未做任何修改）' % (sig.decode('latin-1'), fid))
            return 1

        # 遍历子记录
        q = pos + 24
        end = pos + 24 + rsize
        pending_vmad = None
        while q + 6 <= end:
            s = bytes(data[q:q + 4])
            n = struct.unpack_from('<H', data, q + 4)[0]
            if s == b'XXXX':
                q += 10
                continue
            if s == b'SNAM' and n == 4:
                raw = struct.unpack_from('<I', data, q + 6)[0]
                if (raw >> 24) > n_masters:
                    new = (n_masters << 24) | (raw & 0x00FFFFFF)
                    struct.pack_into('<I', data, q + 6, new)
                    changes.append('SNAM %08X -> %08X' % (raw, new))
            elif s == b'VMAD':
                if not patch_vmad(data, q + 6, q + 6 + n, n_masters, changes):
                    print('✗ %s %08X 的 VMAD 解析失败（属性类型未支持，或走完没正好落在末尾），已退出（未做任何修改）'
                          % (sig.decode('latin-1'), fid))
                    return 1
            q += 6 + n
        pos += 24 + rsize

    if not changes:
        print('无需修改（索引已经规范）')
        return 0

    # 安全阀：归并索引可能让两条记录撞号（CK 把记录分散在"文件位"里时，
    # 不同文件位可以有相同的对象序号）。真撞号必须重新分配序号并更新引用，
    # 那不是本工具的职责 —— 直接拒绝，交给 tools/repair_esp.py。
    seen = {}
    pos = 24 + size
    planned = {}
    while pos + 24 <= len(data):
        sig = bytes(data[pos:pos + 4])
        if sig == b'GRUP':
            pos += 24
            continue
        rsize = struct.unpack_from('<I', data, pos + 4)[0]
        fid = struct.unpack_from('<I', data, pos + 12)[0]
        edid = ''
        q = pos + 24
        end = pos + 24 + rsize
        while q + 6 <= end:
            s = bytes(data[q:q + 4])
            n = struct.unpack_from('<H', data, q + 4)[0]
            if s == b'XXXX':
                q += 10
                continue
            if s == b'EDID':
                edid = bytes(data[q + 6:q + 6 + n]).split(b'\0')[0].decode('latin-1')
            q += 6 + n
        if fid in planned:
            print('✗ 归并后 %08X 会撞号（%s / %s）—— 拒绝修改，请用 tools/repair_esp.py' % (
                fid, planned[fid], edid))
            return 1
        planned[fid] = edid
        pos += 24 + rsize

    open(path, 'wb').write(bytes(data))
    print('已修正 %d 处：' % len(changes))
    for c in changes:
        print('  ' + c)
    return 0


if __name__ == '__main__':
    sys.exit(main())
