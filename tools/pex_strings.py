"""从 pex 里粗提字符串（Papyrus pex 的字符串表是 uint16 长度前缀的 ASCII/UTF-8）。"""
import sys

for f in sys.argv[1:]:
    d = open(f, 'rb').read()
    out, i = [], 0
    while i < len(d) - 2:
        n = d[i] | (d[i + 1] << 8)
        if 3 <= n <= 300:
            chunk = d[i + 2:i + 2 + n]
            if all(32 <= b < 127 for b in chunk):
                out.append(chunk.decode())
                i += 2 + n
                continue
        i += 1
    print("==", f, len(out))
    for s in out:
        if len(s) > 3 and not s.startswith('::') and chr(92) not in s:
            print(repr(s))
