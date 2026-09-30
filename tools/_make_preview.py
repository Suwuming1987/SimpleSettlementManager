"""生成一个可以在普通浏览器里打开的预览页：复制 index.html，注入桩件 + 假数据。

PrismaUI 的桥（window.prisma）和 localStorage 在浏览器里没有，注入后就能直接看布局。
产出：tools/_preview.html（不进 mod 目录、不影响游戏）。
"""
import io

SRC = r'E:\fo4mods\SimpleSettlementManager\src\PrismaUI\views\SimpleSettlementManager\index.html'
OUT = r'E:\fo4mods\SimpleSettlementManager\tools\_preview.html'

import sys
PAGE = sys.argv[1] if len(sys.argv) > 1 else "people"   # 要预览的页面：overview / settle / people / jobs / settings

PAYLOAD = "\n".join([
    "P|pong",
    "H|庇护山丘",
    "K|68",
    "S|1|庇护山丘|7|3|12|20|5|10|7|0|0|0|80|1|9|2",
    "S|2|红火箭加油站|2|1|0|0|0|0|2|2|0|0|70|1|1|1",
    "S|3|十松庄|4|0|6|3|0|4|4|0|0|0|75|0|30|5",
    "S|4|塔芬顿船屋|3|3|0|0|0|0|0|3|3|3|50|0|-1|-1",
    "E|1|2", "E|3|2",
    # W|名字|状态|岗位|开关|床位|性别|职业类别（0无业 1农民 2拾荒 3守卫 4商人 5运输 6工人 7队友）
    "W|司特|0| |111|0|0|0|3-4-5-6-7-2-1|0", "W|朱恩|0| |111|1|1|0|1-2-3-4-5-6-7|0", "W|定子|0| |111|0|0|0",
    "W|凯特|2| |001|1|1|7|7-6-5-4-3-2-1|0", "W|派普|1|铃薯|111|1|0|1|2-2-2-2-2-2-2|1",
    "W|居民甲|1|玉米|111|1|0|1|5-5-5-5-5-5-5|0", "W|守卫乙|1|机枪塔|111|1|0|3|4-4-4-4-4-4-4|1",
    "W|商贩丙|1|贸易摊位|111|1|1|4|6-6-6-6-6-6-6|0", "W|搬运丁|3|→ 红火箭加油站|111|1|1|5|1-1-1-1-1-1-1|0",
    "G|铃薯|1|派普", "G|玉米|1|居民甲", "G|铃薯|1|", "G|铃薯|1|",
    "G|机枪塔|3|守卫乙", "G|贸易摊位|4|商贩丙", "G|守卫岗哨|3|", "G|拾荒台|2|",
    "B|7|5|2",
    "J|铃薯", "J|铃薯", "J|铃薯", "J|铃薯", "J|铃薯",
    "J|玉米", "J|玉米", "J|贸易摊位", "J|守卫岗哨", "J|拾荒台",
])

CACHED = "\n".join([
    "CD|2",                       # 红火箭加油站（非当前据点）的"暂存明细"
    "W|居民甲|1|铃薯|111|1|0|1|4-4-4-4-4-4-4|1",
    "W|居民乙|0| |111|0|1|0|5-5-5-5-5-5-5",
    "B|4|2|2",
    "J|铃薯", "J|铃薯", "J|玉米",
])

STUB = """
<script>
  // ---- 预览桩件：只有浏览器里才需要 ----
  window.prisma = { emit: function (n) {
    window.__emitted = (window.__emitted || []).concat([n]);
    // 预览里模拟游戏侧：界面请求某个据点的"暂存明细"时，就把那份数据推回去（真实环境由 Papyrus 回推）
    if (String(n).indexOf("smDetail") === 0) { setTimeout(function () { smOnData(%s); }, 30); }
  } };
  try { localStorage.clear(); } catch (e) {}
  window.addEventListener("load", function () {
    setTimeout(function () {
      smOnData(%s);
      // 再补一份"别的据点的暂存明细"，用来验证据点页展开时的暂存分支
      smOnData(%s);
      state.pickedSettler = 0;
      go("%s");
      document.getElementById("where").textContent = "当前：" + state.here;
    }, 60);
  });
</script>
""" % (repr(CACHED), repr(PAYLOAD), repr(CACHED), PAGE)

h = io.open(SRC, encoding='utf-8').read()
h = h.replace("<script>", STUB + "<script>", 1)
io.open(OUT, 'w', encoding='utf-8', newline='\n').write(h)
print("预览页已生成：", OUT)
