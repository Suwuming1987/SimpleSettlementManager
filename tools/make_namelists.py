"""把抽好的名字库注入 index.html（中英两套，按性别分组）。

名字库来源：What's Your Name（作者 LarannKiar 那套 mod 里的名字表）及其简体中文翻译版，
由 tools/extract_names.py 从两个 ESL 的 FLST/MESG 里抽出来存成 JSON，这里只做注入。

注入位置由页面里的标记决定：
    // ==== NAMES BEGIN（由 tools/make_namelists.py 生成，不要手改）====
    ...
    // ==== NAMES END ====

用法：
  python tools/make_namelists.py
"""
import io
import json
import os

HTML = r"E:\fo4mods\SimpleSettlementManager\src\PrismaUI\views\SimpleSettlementManager\index.html"
BEGIN = "  // ==== NAMES BEGIN（由 tools/make_namelists.py 生成，别手改）===="
END = "  // ==== NAMES END ===="

EN = 'tools/names_en.json'
ZH = 'tools/names_zh.json'


def load(path):
    if not os.path.exists(path):
        return None
    return json.load(io.open(path, encoding='utf-8'))


def js_array(names):
    # 每行 8 个，避免单行过长
    chunks = []
    for i in range(0, len(names), 8):
        chunks.append(",".join(json.dumps(n, ensure_ascii=False) for n in names[i:i + 8]))
    return "[" + (",\n      ".join(chunks)) + "]"


def block(names_en, names_zh):
    lines = []
    lines.append(BEGIN)
    lines.append("  // 随机名字按**性别**取（男名/女名两份，罕见名已合并进来，不再单独分池）。")
    lines.append("  // 界面语言是中文就用中文名（取自 WYN 的简体中文翻译），否则用英文原名。")
    lines.append("  var NAMES = {")
    for lang, data, src in (("en", names_en, "What's Your Name"), ("zh", names_zh, "What's Your Name 简体中文")):
        if not data:
            continue
        # 罕见名并入主库；只保留 男 / 女 两份（玩家要求别再分罕见名池）
        male = list(dict.fromkeys(list(data.get("male", [])) + list(data.get("maleRare", []))))
        female = list(dict.fromkeys(list(data.get("female", [])) + list(data.get("femaleRare", []))))
        # 严格分男女：同时出现在两边的，从女名里剔除（避免"随机出来的名字不是这个性别"）
        overlap = [n for n in female if n in set(male)]
        if overlap:
            female = [n for n in female if n not in set(male)]
            print("  %s: 剔除 %d 个男女重名（例：%s）" % (lang, len(overlap), "、".join(overlap[:5])))
        lines.append("    %s: {  // 来源：%s（罕见名已并入）" % (lang, src))
        lines.append("      male: %s," % js_array(male))
        lines.append("      female: %s," % js_array(female))
        lines.append("    },")
    lines.append("  };")
    lines.append(END)
    return "\n".join(lines)


def main():
    en, zh = load(EN), load(ZH)
    if not en and not zh:
        raise SystemExit("没有名字库 JSON：先跑 tools/extract_names.py")
    h = io.open(HTML, encoding='utf-8').read()
    b = block(en, zh)
    if BEGIN in h and END in h:
        head = h[:h.index(BEGIN)]
        tail = h[h.index(END) + len(END):]
        h = head + b + tail
    else:
        anchor = "  var CAPTURE = false;"
        assert anchor in h, "找不到插入锚点"
        h = h.replace(anchor, b + "\n\n" + anchor, 1)
    io.open(HTML, 'w', encoding='utf-8', newline='\n').write(h)
    for lang, data in (("en", en), ("zh", zh)):
        if data:
            print("%s: 男 %d / 女 %d（已含罕见名）" % (lang, len(data['male']) + len(data['maleRare']),
                                                       len(data['female']) + len(data['femaleRare'])))


main()
